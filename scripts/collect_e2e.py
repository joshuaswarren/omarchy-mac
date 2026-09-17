#!/usr/bin/env python3
"""Collect Omarchy Mac E2E installation evidence into one reviewable archive.

Companion to the volunteer E2E installation checklist
(docs/omarchy-mac-e2e-volunteer-checklist.md). The checklist names what a
volunteer must observe; this script gathers everything a machine can
observe on its own, bounds every command, redacts identity strings, and
packs the result into a deterministic archive the volunteer can attach to
their test report. Human-judgment checkboxes are walked in `--interview`
mode and stored as data next to the machine evidence, so a submission
carries both.

Self-contained: stdlib only, no repository build, no network by default.
Like the mlx-omarchy collectors it borrows its plumbing from, a missing
tool or log is recorded as data, never a crash. Section results are
written as they complete, so an interrupted run keeps what finished.

Sections (schema_version 1):
  identity       test assignment answers (checklist section 1), reused
                 across runs from e2e-identity.json in the working dir
  baseline       the fresh-Asahi baseline commands (section 3): mounts,
                 lsblk, df, free, plus a freshness marker
  install-logs   omarchy-mac-setup/install/pacman log tails and the
                 setup service state (sections 4-5)
  boot           journal boot list, current-boot warnings, failed
                 system and user units (sections 5-7)
  install-state  omarchy version and path, pinned package versions,
                 migration and first-run state (section 6)
  security       cleanup and exposure checks (section 7)
  mlx            the mlx-omarchy quick capability report (vendored
                 collect_quick): host, Mesa/Vulkan, ANE devicetree,
                 installed mlx-omarchy distributions and default device
  macos          optional: pasted macOS-side output via --from-macos
  interview      optional: --interview walks every human-judgment
                 checkbox (sections 5-9) and stores PASS/FAIL/SKIP/NA
                 with notes

Privacy: every captured value passes through the shared Redactor (names,
paths, IPs, MACs, serials, credential-shaped strings). The default run
only previews. `--out FILE` writes the deterministic archive plus a
paste-ready `FILE.submission.md` with the checklist report template
pre-filled from machine evidence. Uploading is explicit: pass
`--submit URL` (the mlx-omarchy community-data worker protocol; use a
kind-aware endpoint such as MLX_OMARCHY_SUBMIT_URL pointing at an e2e
collection worker when one exists).

Typical volunteer flow:
  python3 scripts/collect_e2e.py --out e2e-run1.tar.gz
  python3 scripts/collect_e2e.py --interview --out e2e-run1.tar.gz
"""
import argparse
import getpass
import hashlib
import json
import os
import platform
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import collect_quick
from collect_common import (
    SCHEMA_VERSION,
    Redactor,
    archive_bytes,
    build_manifest,
    build_payload,
    dump_json,
    json_bytes,
    read_text,
    run_tool,
)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SECTION_TIMEOUTS = {
    "identity": 10,
    "baseline": 60,
    "mlx": 240,
    "install-logs": 60,
    "boot": 90,
    "install-state": 60,
    "security": 60,
    "macos": 10,
    "interview": 300,
}
SECTION_ORDER = ("identity", "baseline", "mlx", "install-logs", "boot",
                 "install-state", "security", "macos", "interview")

SETUP_LOGS = (
    "/var/log/omarchy-mac-setup.log",
    "/var/log/omarchy-install.log",
    "/var/log/pacman.log",
)

PINNED_PACKAGES = ("omarchy", "omarchy-settings", "hyprland", "hyprtoolkit",
                   "hyprland-guiutils", "aquamarine")


def read_path(redactor, path, max_chars=60_000):
    """Tail a file if present; absence is data, not an error."""
    try:
        with open(path, "r", errors="replace") as fh:
            data = fh.read()
    except OSError as exc:
        return {"present": False, "error": redactor.apply(f"{type(exc).__name__}: {exc}")}
    return {"present": True, "bytes_total": None,
            "tail": redactor.apply(data)[-max_chars:]}


def tool(argv, redactor, label, timeout=30):
    return run_tool(argv, redactor, label=label, timeout=timeout)


def sox_field(path):
    """Read one small devicetree property, NULs stripped."""
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read().replace("\x00", " ").strip()
    except OSError:
        return None


def section_identity(redactor, answers_path):
    out = {"available": True, "prompts": [], "identity_file": None}
    prior = {}
    if os.path.exists(answers_path):
        try:
            with open(answers_path, "r") as fh:
                prior = json.load(fh)
            out["identity_file"] = redactor.apply(answers_path)
        except (OSError, ValueError):
            prior = {}
    prompts = [
        ("tester", "Tester name/handle"),
        ("test_id", "Test ID / tracking issue"),
        ("date_timezone", "Date and timezone"),
        ("mac_model", "Mac model and year"),
        ("model_identifier", "Apple model identifier (e.g. MacBookAir10,1)"),
        ("soc", "SoC (M1/M1 Pro/M1 Max/M2/M2 Pro/M2 Max)"),
        ("ram_ssd", "RAM / SSD"),
        ("macos_version", "macOS version and build"),
        ("asahi_image", "Asahi Alarm image (Minimal BTRFS / Minimal ext4)"),
        ("install_path", "Install path (encrypted / unencrypted)"),
        ("keyboard_layout", "Keyboard layout"),
        ("omarchy_repo_ref", "Omarchy repository and ref"),
        ("target_commit", "Target source commit, if assigned"),
        ("network_type", "Network type (Wi-Fi / Ethernet)"),
        ("peripherals", "Important peripherals or external display"),
    ]
    interactive = sys.stdin.isatty()
    out["interactive"] = interactive
    for key, question in prompts:
        if prior.get(key):
            out[key] = prior[key]
        elif interactive:
            try:
                answer = input(f"{question}: ").strip()
            except EOFError:
                answer = ""
            out[key] = answer or None
        else:
            out[key] = None
        if not out.get(key):
            out["prompts"].append(question)
    devtree = "/sys/firmware/devicetree/base"
    out["devicetree"] = {"model": sox_field(devtree + "/model"),
                         "compatible": sox_field(devtree + "/compatible")}
    return out


def lsblk_json(redactor):
    rec = tool(["lsblk", "--json", "-o", "NAME,FSTYPE,SIZE,MOUNTPOINTS"],
               redactor, label="lsblk json", timeout=20)
    if rec["exit_code"] != 0:
        return {"available": False, "error": rec["error"] or rec["stderr"][:300]}
    try:
        return {"available": True, "blockdevices": json.loads(rec["stdout"])}
    except ValueError as exc:
        return {"available": False, "error": f"unparsable: {exc}"}


def storage_facts(redactor):
    """Derive the facts the checklist asks the volunteer to eyeball."""
    facts = {"available": True, "root_encrypted": None, "boot_separate": None,
             "luks_devices": []}
    data = lsblk_json(redactor)
    if not data.get("available"):
        return {"available": False, "error": data.get("error")}
    for dev in (data["blockdevices"].get("blockdevices") or []):
        stack = [dev]
        while stack:
            node = stack.pop()
            fstype = (node.get("fstype") or "").lower()
            if fstype == "crypto_luks":
                facts["luks_devices"].append(node.get("name"))
            stack.extend(node.get("children") or [])
    rec = tool(["findmnt", "-rn", "-o", "SOURCE,FSTYPE,OPTIONS", "--mountpoint", "/"],
               redactor, label="findmnt /", timeout=10)
    facts["root_mount"] = rec["stdout"].strip() or None
    rec = tool(["findmnt", "-rn", "-o", "SOURCE,FSTYPE,OPTIONS", "--mountpoint", "/boot"],
               redactor, label="findmnt /boot", timeout=10)
    boot_mount = rec["stdout"].strip()
    facts["boot_mount"] = boot_mount or None
    if boot_mount and facts["root_mount"]:
        facts["boot_separate"] = boot_mount.split()[0] != facts["root_mount"].split()[0]
    if facts["luks_devices"]:
        facts["root_encrypted"] = True
    rec = tool(["findmnt", "-rn", "-o", "SOURCE", "--mountpoint", "/"],
               redactor, label="findmnt / source", timeout=10)
    if rec["stdout"].startswith("/dev/mapper/"):
        facts["root_encrypted"] = True
    facts["fresh_marker"] = {
        "setup_conf_present": os.path.exists("/etc/omarchy-mac-setup.conf"),
        "note": "setup_conf_present=true means a guided install already ran "
                "here; the checklist requires a genuinely fresh system",
    }
    return facts


def section_baseline(redactor):
    out = {"available": True}
    for label, argv in (
        ("uname", ["uname", "-a"]),
        ("os_release", ["cat", "/etc/os-release"]),
        ("findmnt_root", ["findmnt", "-rn", "-o", "TARGET,SOURCE,FSTYPE,OPTIONS",
                          "--mountpoint", "/"]),
        ("findmnt_boot", ["findmnt", "-rn", "-o", "TARGET,SOURCE,FSTYPE,OPTIONS",
                          "--mountpoint", "/boot"]),
        ("lsblk_f", ["lsblk", "-f"]),
        ("df", ["df", "-h", "/", "/boot"]),
        ("free", ["free", "-h"]),
        ("swapon", ["swapon", "--show"]),
    ):
        out[label] = tool(argv, redactor, label=label)
    out["storage_facts"] = storage_facts(redactor)
    return out


def section_install_logs(redactor):
    out = {"available": True, "logs": {}}
    for path in SETUP_LOGS:
        out["logs"][path] = read_path(redactor, path, max_chars=200_000)
    out["setup_status"] = tool(
        ["/usr/local/bin/omarchy-mac-setup", "--status"], redactor,
        label="omarchy-mac-setup --status", timeout=30)
    out["setup_service_enabled"] = tool(
        ["systemctl", "is-enabled", "omarchy-mac-setup.service"], redactor,
        label="is-enabled omarchy-mac-setup", timeout=15)
    out["setup_service_status"] = tool(
        ["systemctl", "status", "omarchy-mac-setup.service", "--no-pager"],
        redactor, label="status omarchy-mac-setup", timeout=15)
    out["install_stage_timing_note"] = (
        "per-stage wall times and pre-reboot screen tails are not machine-"
        "readable today; photograph or transcribe them per checklist section 4")
    return out


def section_boot(redactor):
    out = {"available": True}
    out["boot_list"] = tool(["journalctl", "--list-boots", "--no-pager"],
                            redactor, label="journalctl --list-boots", timeout=30)
    out["current_boot_warnings"] = tool(
        ["journalctl", "-b", "-p", "warning", "--no-pager"], redactor,
        label="journalctl -b -p warning", timeout=60)
    out["failed_units"] = tool(["systemctl", "--failed", "--no-pager"], redactor,
                               label="systemctl --failed", timeout=30)
    out["failed_user_units"] = tool(
        ["systemctl", "--user", "--failed", "--no-pager"], redactor,
        label="systemctl --user --failed", timeout=30)
    out["boot_tree"] = tool(["find", "/boot", "-maxdepth", "2", "-printf",
                             "%y %p\n"], redactor, label="find /boot",
                            timeout=30)
    out["units_not_found"] = tool(
        ["systemctl", "list-units", "--all", "--no-pager"], redactor,
        label="list-units (LoadState scan)", timeout=30)
    return out


def section_install_state(redactor):
    out = {"available": True}
    out["omarchy_version"] = tool(["omarchy", "version"], redactor,
                                  label="omarchy version", timeout=15)
    out["omarchy_path"] = {"env_OMARCHY_PATH": redactor.apply(
        os.environ.get("OMARCHY_PATH") or "") or None,
        "usr_share_symlink": None}
    try:
        out["omarchy_path"]["usr_share_symlink"] = redactor.apply(
            os.path.realpath("/usr/share/omarchy"))
    except OSError:
        pass
    out["pinned_packages"] = tool(["pacman", "-Q", *PINNED_PACKAGES], redactor,
                                  label="pacman -Q pinned", timeout=30)
    out["pacman_Dk"] = tool(["pacman", "-Dk"], redactor,
                            label="pacman -Dk", timeout=60)
    # Checklist note: --pending exits 0 when migrations ARE pending and
    # 1 when none are. Record, never interpret as pass/fail.
    migrate = tool(["omarchy-migrate", "--pending"], redactor,
                   label="omarchy-migrate --pending", timeout=60)
    migrate["checklist_semantics"] = ("exit 0 = migrations pending; "
                                      "exit 1 = none pending")
    out["migrations_pending"] = migrate
    for check in ("finalize-user", "first-run-user"):
        out[f"omarchy_done_{check}"] = tool(
            ["omarchy-done", "check", check], redactor,
            label=f"omarchy-done check {check}", timeout=30)
    return out


def section_security(redactor):
    out = {"available": True}
    out["setup_conf_present"] = os.path.exists("/etc/omarchy-mac-setup.conf")
    out["setup_sudoers_present"] = os.path.exists("/etc/sudoers.d/01-omarchy-mac-setup")
    # Expected True (nonzero exit) after cleanup: passwordless sudo gone.
    sudo_n = tool(["sudo", "-n", "true"], redactor,
                  label="sudo -n true (passwordless probe)", timeout=15)
    sudo_n["expected_after_cleanup"] = "non-zero exit"
    out["passwordless_sudo_probe"] = sudo_n
    out["sshd_enabled"] = tool(["systemctl", "is-enabled", "sshd"], redactor,
                               label="is-enabled sshd", timeout=15)
    out["sshd_socket_enabled"] = tool(["systemctl", "is-enabled", "sshd.socket"],
                                      redactor, label="is-enabled sshd.socket",
                                      timeout=15)
    out["firewall"] = tool(["nft", "list ruleset"], redactor,
                           label="nft list ruleset", timeout=30)
    out["user_journal_warnings"] = tool(
        ["journalctl", "--user", "-b", "-p", "warning", "--no-pager"], redactor,
        label="journalctl --user -b -p warning", timeout=60)
    return out


def section_macos(redactor, from_file):
    if not from_file:
        return {"available": False,
                "error": "macOS-side output is collected before install; "
                         "rerun with --from-macos FILE (system_profiler "
                         "SPHardwareDataType, sw_vers, diskutil list)"}
    data = read_path(redactor, from_file, max_chars=200_000)
    data["source"] = redactor.apply(from_file)
    data["section"] = "pasted macOS baseline (checklist section 2/3)"
    return data


# --- interview -------------------------------------------------------------

# Human-judgment items from the checklist, verbatim in intent. The script
# cannot see a screen or press a key; these are answered by the volunteer.
INTERVIEW_ITEMS = [
    ("reboot-a", "Boot-layout reboot: Apple boot -> m1n1 -> U-Boot -> Linux "
     "menu completed normally"),
    ("reboot-a", "Setup resumed automatically on tty1 (no blank screen/cursor)"),
    ("reboot-a", "/boot moved to a separate unencrypted partition"),
    ("reboot-a", "Installer advanced to encryption instead of repeating "
     "boot-layout"),
    ("reboot-b", "Disk-passphrase prompt visible and accepted input"),
    ("reboot-b", "Console keymap typed the intended passphrase correctly"),
    ("reboot-b", "cryptsetup reencrypt progress was visible"),
    ("reboot-b", "Encryption finished without unexplained reboot/hang/loop"),
    ("reboot-b", "New passphrase unlocked root on next boot"),
    ("reboot-b", "Setup resumed automatically after encryption"),
    ("reboot-c", "Clone, package install, system setup, user setup completed"),
    ("reboot-c", "Network loss or mirror errors were clearly reported"),
    ("reboot-c", "Required package failures were not reported as optional skips"),
    ("reboot-c", "Final reboot reached SDDM or desktop"),
    ("reboot-c", "First graphical boot did not conflict with the tty1 setup service"),
    ("reboot-c", "Guided installer did not start again after completion"),
    ("desktop", "Login succeeded with the created user"),
    ("desktop", "Desktop rendered correctly (notch-aware layout on MacBooks)"),
    ("desktop", "First-run setup completed once, no loop"),
    ("desktop", "Menu, launcher, terminal, browser, file manager, settings open"),
    ("desktop", "Wi-Fi and DNS work"),
    ("desktop", "Built-in keyboard, trackpad, brightness keys, backlight work"),
    ("desktop", "Audio plays at modest volume with speaker protection active"),
    ("desktop", "Headphones and microphone work (if available)"),
    ("desktop", "Lock and unlock work"),
    ("desktop", "Suspend/resume works once; Wi-Fi and input recover"),
    ("desktop", "Theme change leaves the desktop usable"),
    ("persist", "Second login: first-run prompts/notifications do not repeat"),
    ("persist", "Normal reboot: unlock, login, desktop, Wi-Fi, audio protection OK"),
    ("persist", "Cold boot after 15s power-off succeeded"),
    ("persist", "sudo requires the user's password"),
    ("persist", "Temporary setup files/services/passwordless privileges retired"),
    ("persist", "Root access matches the --keep-root-password choice"),
    ("persist", "SSH not silently exposed through the firewall"),
]

VALID_ANSWERS = ("PASS", "FAIL", "SKIP", "NA")


def section_interview(redactor, answers_path):
    out = {"available": True, "interactive": False, "answers": {}, "notes": {}}
    if os.path.exists(answers_path):
        try:
            with open(answers_path, "r") as fh:
                out["answers"] = json.load(fh).get("answers", {})
        except (OSError, ValueError):
            pass
    if not sys.stdin.isatty():
        out["note"] = ("not a TTY; holding existing answers only. Rerun with "
                       "--interview on the console to record PASS/FAIL/SKIP/NA "
                       "per item")
        return out
    out["interactive"] = True
    print(f"\n=== E2E interview: {len(INTERVIEW_ITEMS)} items. "
          f"Answer PASS / FAIL / SKIP / NA, then an optional note. "
          f"Blank keeps the previous answer. ===\n")
    for group, item in INTERVIEW_ITEMS:
        key = f"{group}::{item}"
        prior = out["answers"].get(key, "")
        while True:
            try:
                raw = input(f"[{group}] {item}\n  PASS/FAIL/SKIP/NA"
                            f"{f' (now: {prior})' if prior else ''}: ").strip()
            except EOFError:
                raw = ""
            answer = raw.split(";", 1)[0].strip().upper() or prior
            if answer in VALID_ANSWERS or answer == "":
                break
            print(f"  unrecognized {raw!r}; use PASS, FAIL, SKIP or NA "
                  f"(optionally 'FAIL; note text')")
        note = raw.split(";", 1)[1].strip() if ";" in raw else ""
        if answer:
            out["answers"][key] = answer
        if note:
            out["notes"][key] = redactor.apply(note)
    return out


# --- report ----------------------------------------------------------------

REPORT_TEMPLATE_ITEMS = [
    ("Fresh Asahi baseline", "auto+human"),
    ("Boot-layout stage", "reboot-a"),
    ("Encryption stage", "reboot-b"),
    ("Omarchy install stage", "reboot-c"),
    ("First login", "desktop"),
    ("Second login", "persist"),
    ("Normal reboot", "persist"),
    ("Cold boot", "persist"),
    ("Hardware smoke test", "desktop"),
    ("Security cleanup", "security"),
]


def render_report_md(identity, files):
    """The checklist report template, pre-filled from machine evidence."""
    state = _member(files, "install-state.json")
    base = _member(files, "baseline.json")
    sec = _member(files, "security.json")
    interview = _member(files, "interview.json")
    answers = interview.get("answers", {})
    notes = interview.get("notes", {})

    def stage_verdict(group):
        have = [answers.get(f"{g}::{i}") for g, i in INTERVIEW_ITEMS
                if g == group]
        have = [a for a in have if a]
        if not have:
            return "UNRECORDED"
        if "FAIL" in have:
            return "FAIL"
        if "SKIP" in have:
            return "SKIP"
        if all(a == "PASS" for a in have):
            return "PASS"
        return "PARTIAL"

    lines = ["", "## E2E report (auto-filled where marked [auto])", ""]
    lines.append("```text")
    lines.append(f"Test ID: {identity.get('test_id') or ''}")
    lines.append(f"Tester: {identity.get('tester') or ''}")
    lines.append(f"Date/timezone: {identity.get('date_timezone') or ''}")
    lines.append(f"Mac model / Apple identifier / SoC / RAM: "
                 f"{identity.get('mac_model') or ''} / "
                 f"{identity.get('model_identifier') or ''} / "
                 f"{identity.get('soc') or ''} / {identity.get('ram_ssd') or ''}")
    lines.append(f"macOS version: {identity.get('macos_version') or ''}")
    lines.append(f"Asahi image and filesystem: {identity.get('asahi_image') or ''}")
    lines.append(f"Encryption and keymap: "
                 f"{identity.get('install_path') or ''} / "
                 f"{identity.get('keyboard_layout') or ''}")
    lines.append(f"Omarchy repo / ref / installed version: "
                 f"{identity.get('omarchy_repo_ref') or ''} / "
                 f"{(state.get('omarchy_version') or {}).get('stdout', '').strip() or ''}")
    lines.append(f"Test command: {identity.get('target_commit') or ''}")
    root_enc = (base.get("storage_facts") or {}).get("root_encrypted")
    lines.append(f"root_encrypted [auto]: {root_enc if root_enc is not None else 'unknown'}")
    lines.append(f"boot_separate [auto]: "
                 f"{(base.get('storage_facts') or {}).get('boot_separate', 'unknown')}")
    for label, group in REPORT_TEMPLATE_ITEMS:
        if group == "auto+human":
            continue
        if group == "security":
            present_conf = sec.get("setup_conf_present")
            present_sudo = sec.get("setup_sudoers_present")
            lines.append(f"{label}: cleanup_conf={present_conf} "
                         f"cleanup_sudoers={present_sudo} "
                         f"(interview: {stage_verdict('persist')})")
            continue
        lines.append(f"{label}: {stage_verdict(group)}")
    lines.append("Overall: (PASS / FAIL / BLOCKED — volunteer decides)")
    lines.append("First failing checkpoint:")
    lines.append("Expected:")
    lines.append("Actual:")
    lines.append("Reproduction steps:")
    lines.append("Warnings / skipped packages:")
    lines.append("Logs, photos, or video: (see archive)")
    lines.append("Related issue/PR:")
    lines.append("Notes and clearly labelled hypotheses:")
    lines.append("```")
    for key, note in sorted(notes.items()):
        lines.append(f"note [{key}]: {note}")
    return "\n".join(lines)


def _member(files, name):
    try:
        return json.loads(files[name].decode("utf-8"))
    except (KeyError, ValueError):
        return {}


# --- harness ---------------------------------------------------------------

def section_child(name, ws, args):
    redactor = Redactor()
    try:
        if name == "identity":
            data = section_identity(redactor, args.identity_file)
        elif name == "baseline":
            data = section_baseline(redactor)
        elif name == "mlx":
            data = collect_quick.collect()
            data["section"] = "mlx-omarchy quick capability report (vendored)"
        elif name == "install-logs":
            data = section_install_logs(redactor)
        elif name == "boot":
            data = section_boot(redactor)
        elif name == "install-state":
            data = section_install_state(redactor)
        elif name == "security":
            data = section_security(redactor)
        elif name == "macos":
            data = section_macos(redactor, args.from_macos)
        elif name == "interview":
            data = section_interview(redactor, args.answers_file)
        else:
            data = {"available": False, "error": f"unknown section {name}"}
    except Exception as exc:
        data = {"available": False,
                "error": redactor.apply(f"{type(exc).__name__}: {exc}")}
    data = redactor.apply_value(data)
    if isinstance(data, dict):
        data["_redaction"] = redactor.counts
    with open(os.path.join(ws, f"{name}.json"), "wb") as fh:
        fh.write(json_bytes(data))


def run_sections(ws, args, redactor):
    for name in SECTION_ORDER:
        if name in args.skip:
            continue
        timeout = args.timeout or SECTION_TIMEOUTS[name]
        rec = run_tool(
            [sys.executable, os.path.abspath(__file__), "--_section", name,
             "--_workspace", ws, "--_identity", args.identity_file,
             "--_answers", args.answers_file,
             "--_from_macos", args.from_macos or ""],
            redactor, label=f"section:{name}", timeout=timeout)
        if not os.path.exists(os.path.join(ws, f"{name}.json")):
            with open(os.path.join(ws, f"{name}.json"), "wb") as fh:
                fh.write(json_bytes({
                    "available": False,
                    "error": rec["error"] or f"exit {rec['exit_code']}",
                    "stderr": rec["stderr"][-2000:],
                }))


def assemble_files(ws, identity, redactor):
    files = {}
    unavailable = []
    redaction = {}
    for name in SECTION_ORDER:
        if name == "macos" and not identity.get("from_macos"):
            continue  # optional section; absent unless requested
        path = os.path.join(ws, f"{name}.json")
        data = read_text(path)
        if data is None:
            data = json_bytes({"available": False,
                               "error": "section produced no result"})
            unavailable.append(name)
        else:
            try:
                parsed = json.loads(data)
                if parsed.get("available") is False:
                    unavailable.append(name)
                for kind, count in parsed.get("_redaction", {}).items():
                    redaction[kind] = redaction.get(kind, 0) + count
            except ValueError:
                pass
        files[f"{name}.json"] = data if isinstance(data, bytes) \
            else data.encode("utf-8")
    # The checklist itself travels with the evidence.
    checklist = os.path.join(REPO, "docs", "omarchy-mac-e2e-volunteer-checklist.md")
    checklist_data = read_text(checklist)
    if checklist_data is not None:
        files["omarchy-mac-e2e-volunteer-checklist.md"] = \
            checklist_data if isinstance(checklist_data, bytes) \
            else checklist_data.encode("utf-8")
    return files, unavailable, redaction


def build_submission(manifest, files, identity):
    base = _member(files, "baseline.json")
    quick = _member(files, "mlx.json")
    host = quick.get("host") or {}
    dt = host.get("devicetree") or {}
    gpu = (quick.get("mesa") or {}).get("gpu") or {}
    mlx = quick.get("mlx") or {}
    logs = _member(files, "install-logs.json")
    state = _member(files, "install-state.json")
    sec = _member(files, "security.json")
    facts = base.get("storage_facts") or {}
    omarchy_v = (state.get("omarchy_version") or {}).get("stdout", "").strip()
    lines = ["## Omarchy Mac E2E evidence archive", ""]
    lines.append(f"Tester: {identity.get('tester') or 'UNRECORDED'}; "
                 f"Test ID: {identity.get('test_id') or 'UNRECORDED'}; "
                 f"SoC: {identity.get('soc') or 'UNRECORDED'}; "
                 f"model identifier: {identity.get('model_identifier') or 'UNRECORDED'}")
    lines.append(f"Install path: {identity.get('install_path') or 'UNRECORDED'}; "
                 f"Asahi image: {identity.get('asahi_image') or 'UNRECORDED'}")
    lines.append(f"root_encrypted: {facts.get('root_encrypted')}; "
                 f"boot_separate: {facts.get('boot_separate')}; "
                 f"fresh_marker(setup conf present): {facts.get('fresh_marker', {}).get('setup_conf_present')}")
    lines.append(f"Installed omarchy: {omarchy_v or 'not recorded'}")
    lines.append(f"Device: {dt.get('model') or 'unknown'} "
                 f"({dt.get('compatible') or 'unknown compatible'}); "
                 f"Vulkan: {gpu.get('deviceName') or 'unavailable'} / "
                 f"{gpu.get('driverName') or 'unavailable'}")
    dists = mlx.get("distributions") or {}
    lines.append(f"mlx-omarchy: {dists.get('mlx-omarchy') or 'not installed'}, "
                 f"default device {mlx.get('default_device') or 'unavailable'}")
    pinned = (state.get("pinned_packages") or {}).get("stdout", "").strip()
    lines.append(f"Pinned packages: {pinned or 'not recorded'}")
    lines.append(f"setup conf present: {sec.get('setup_conf_present')}; "
                 f"setup sudoers present: {sec.get('setup_sudoers_present')}")
    tails = [p for p, rec in (logs.get("logs") or {}).items() if rec.get("present")]
    lines.append(f"Install logs present: {', '.join(tails) or 'none'}")
    lines.append(f"Sections unavailable: "
                 f"{', '.join(manifest.get('sections_unavailable', [])) or 'none'}")
    lines.append(f"Redaction applied before writing: "
                 f"{json.dumps(manifest.get('redaction_summary', {}), sort_keys=True)}")
    lines += ["", "Attach this archive to the test ID / tracking issue with the "
              "completed checklist report (submission.md carries the "
              "pre-filled template).", ""]
    lines.append(render_report_md(identity, files))
    return "\n".join(lines)


def finalize(files, unavailable, redaction, archive_name, identity):
    listed = {name: data for name, data in files.items()
              if name not in ("manifest.json", "submission.md")}
    quick = _member(files, "mlx.json")
    manifest = build_manifest(archive_name, listed, extra={
        "tool_kind": "omarchy-mac-e2e",
        "system": platform.system(),
        "machine": platform.machine(),
        "sections_unavailable": unavailable,
        "redaction_summary": dict(sorted(redaction.items())),
        "schema_note": "one file per section; bounded command records carry "
                       "argv, exit code, capped redacted output; the schema "
                       "does not change with the sharing path",
    })
    files["submission.md"] = build_submission(
        manifest, files, identity).encode("utf-8")
    manifest = build_manifest(archive_name, files, extra=manifest)
    files["manifest.json"] = json_bytes(manifest)
    payload = build_payload("omarchy-mac-e2e", quick, manifest,
                            redactor=Redactor())
    facts = (files.get("baseline.json", b"{}") and
             json.loads(files.get("baseline.json", b"{}").decode("utf-8") or "{}")
             ).get("storage_facts") or {}
    payload.update({
        "test_id": (identity.get("test_id") or None),
        "install_path": (identity.get("install_path") or None),
        "asahi_image": (identity.get("asahi_image") or None),
        "encryption": facts.get("root_encrypted"),
        "boot_separate": facts.get("boot_separate"),
        "overall": None,
    })
    return manifest, archive_bytes(files), payload


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", metavar="FILE",
                    help="write the archive after the preview (default: "
                         "preview only)")
    ap.add_argument("--submit", metavar="URL", default=None,
                    help="upload the redacted archive to an e2e collection "
                         "endpoint speaking the community-data protocol")
    ap.add_argument("--interview", action="store_true",
                    help="walk the human-judgment checklist items "
                         "(PASS/FAIL/SKIP/NA) on the console")
    ap.add_argument("--identity-file", default="e2e-identity.json",
                    help="test-assignment answers are reused from this file "
                         "(default: ./e2e-identity.json)")
    ap.add_argument("--answers-file", default="e2e-answers.json",
                    help="interview answers are reused from this file "
                         "(default: ./e2e-answers.json)")
    ap.add_argument("--from-macos", metavar="FILE",
                    help="pasted macOS-side output (system_profiler, sw_vers, "
                         "diskutil list) to include")
    ap.add_argument("--workspace", metavar="DIR",
                    help="keep the section files in DIR instead of a temp dir")
    ap.add_argument("--skip", default="",
                    help="comma-separated sections to skip")
    ap.add_argument("--timeout", type=int, default=None,
                    help="override the per-section timeout in seconds")
    ap.add_argument("--_section", help=argparse.SUPPRESS)
    ap.add_argument("--_workspace", help=argparse.SUPPRESS)
    ap.add_argument("--_identity", help=argparse.SUPPRESS)
    ap.add_argument("--_answers", help=argparse.SUPPRESS)
    ap.add_argument("--_from_macos", help=argparse.SUPPRESS)
    args = ap.parse_args()

    if args._section:
        section_child(args._section, args._workspace, args)
        return

    skip = {s.strip() for s in args.skip.split(",") if s.strip()}
    args.skip = skip
    args.from_macos = os.path.abspath(args.from_macos) if args.from_macos else None
    args.identity_file = os.path.abspath(args.identity_file)
    args.answers_file = os.path.abspath(args.answers_file)

    identity_hint = {}
    if os.path.exists(args.identity_file):
        try:
            with open(args.identity_file, "r") as fh:
                identity_hint = json.load(fh)
        except (OSError, ValueError):
            pass
    identity_hint["from_macos"] = args.from_macos

    keep = False
    if args.workspace:
        os.makedirs(args.workspace, exist_ok=True)
        ws = args.workspace
        keep = True
    else:
        ws = tempfile.mkdtemp(prefix="omarchy-mac-e2e-")

    pre_redactor = Redactor()
    run_sections(ws, args, pre_redactor)
    files, unavailable, redaction = assemble_files(ws, identity_hint, pre_redactor)
    for kind, count in pre_redactor.counts.items():
        redaction[kind] = redaction.get(kind, 0) + count
    archive_name = os.path.basename(args.out) if args.out \
        else "omarchy-mac-e2e.tar.gz"
    manifest, data, payload = finalize(files, unavailable, redaction,
                                       archive_name, identity_hint)
    print(json.dumps(manifest, indent=2, sort_keys=True))
    print(f"[preview] archive: {archive_name} bytes={len(data)} "
          f"sha256={hashlib.sha256(data).hexdigest()}")
    if not args.out:
        print("[preview] nothing written, nothing uploaded; "
              "rerun with --out FILE to write these exact bytes")
        if not keep:
            shutil.rmtree(ws, ignore_errors=True)
        return
    with open(args.out, "wb") as fh:
        fh.write(data)
    base = args.out.removesuffix(".tar.gz") if args.out.endswith(".tar.gz") \
        else os.path.splitext(args.out)[0]
    submission = base + ".submission.md"
    with open(submission, "wb") as fh:
        fh.write(files["submission.md"])
    print(f"[receipt] wrote {args.out} ({len(data)} bytes, "
          f"sha256={hashlib.sha256(data).hexdigest()})")
    print(f"[receipt] wrote {submission} (paste-ready cover text)")
    if args.submit and args.out:
        import collect_submit
        try:
            receipt = collect_submit.submit(args.submit, data, payload,
                                            token=collect_submit.token_from_env())
            print(f"[receipt] public URL: {receipt['url']} "
                  f"(deduplicated={receipt['deduplicated']})")
        except collect_submit.SubmitError as exc:
            print(f"[submit] FAILED: {exc}", file=sys.stderr)
            print(f"[submit] local output preserved: {args.out}", file=sys.stderr)
            if not keep:
                shutil.rmtree(ws, ignore_errors=True)
            raise SystemExit(4)
    else:
        print("[receipt] done; nothing was uploaded")
    if not keep:
        shutil.rmtree(ws, ignore_errors=True)


if __name__ == "__main__":
    main()
