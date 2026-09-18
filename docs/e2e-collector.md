# E2E evidence collector (`scripts/collect_e2e.py`)

Companion to `docs/omarchy-mac-e2e-volunteer-checklist.md`. The checklist
names what a volunteer must observe; the collector gathers everything a
machine can observe, redacts identity strings, and packs the result into a
reviewable archive a volunteer attaches to their test report.

## Why

The checklist's report template asks for machine details, stage-by-stage
results, logs, and security-cleanup evidence. Today volunteers gather all
of that by hand and the reports arrive inconsistent (the M1 iMac E2E run
showed what that costs). The mlx-omarchy project already solved this class
of problem with consent-gated, redacted, deterministic evidence collectors;
this brings the same machinery to the Mac installer checklist.

## What it collects

| Section | Checklist coverage | Method |
|---|---|---|
| `identity` | §1 test assignment | interactive prompts, reused from `./e2e-identity.json` |
| `baseline` | §3 fresh-Asahi baseline | the exact documented commands, plus derived facts: LUKS present, `/boot` separate, freshness marker |
| `mlx` | — (bonus) | the mlx-omarchy quick capability report: host/devicetree, Mesa/Vulkan, ANE devicetree, installed distributions |
| `install-logs` | §4–5 | tails of the three documented logs, `omarchy-mac-setup --status`, service state |
| `boot` | §5–7 | `journalctl --list-boots`, current-boot warnings, failed system and user units, `/boot` tree |
| `install-state` | §6 | omarchy version/path, pinned packages, `pacman -Dk`, `omarchy-migrate --pending` (exit semantics recorded, never interpreted), `omarchy-done` checks, swap |
| `security` | §7 | setup conf/sudoers presence, passwordless-sudo probe, sshd exposure, nft ruleset, user journal warnings |
| `macos` | §2–3 | optional: pasted macOS-side output via `--from-macos FILE` |
| `interview` | §5–9 human items | `--interview` walks all 34 judgment checkboxes (PASS/FAIL/SKIP/NA + notes), persisted to `./e2e-answers.json` |

Every external command is bounded (timeout, capped output); a missing tool
or absent log is recorded as data, never a crash; partial runs keep what
finished. Every captured value passes the shared redactor (usernames,
hostnames, home paths, IPs, MACs, serials, credential-shaped strings), and
the per-kind redaction counts ship in the manifest.

## Volunteer flow

```bash
# no clone needed:
bin/omarchy-mac-e2e-collect --interview --out e2e-<testid>.tar.gz

# or from a checkout:
python3 scripts/collect_e2e.py --interview --out e2e-<testid>.tar.gz
```

That prints a preview manifest, then writes:

- `e2e-<testid>.tar.gz` — deterministic archive (all section JSON, the
  checklist itself, the pre-filled report template)
- `e2e-<testid>.submission.md` — paste-ready cover: machine identity,
  derived storage facts, redaction summary, and the checklist report
  template auto-filled where the machine could answer

Attach both to the test ID / tracking issue. Nothing is uploaded unless
`--submit URL` is passed (community-data worker protocol, kind
`omarchy-mac-e2e`; the live worker accepts this kind as of 2026-09-18 —
sample record:
https://mlx-omarchy-community-data.joshua-s-warren.workers.dev/v1/results/ef89a1c651ce3cb599be62dc7baa49f8bacb5e76e9e3a56d41b0fddd60627ff3).

## Provenance

`collect_common.py`, `collect_submit.py`, `collect_quick.py`,
`collect_macos.py` are vendored unchanged from
joshuaswarren/mlx-omarchy (`scripts/`), except one lazy `bench_matrix`
import in the vendored `collect_macos.py` so this set stays
self-contained. Those collectors are field-proven: checksummed wheels,
consent-gated uploads, deterministic archives, PII redaction with
per-kind counts — tested by mlx-omarchy's own suite of 1441 test lines.

## Verification

- `bun test` (worker side, mlx-omarchy): 67/67 unit, including the new
  e2e-kind schema fixture and a smoke scenario; live worker deployed and
  `check_schema_identity.py` green.
- Collector exercised end to end on a non-Apple x86_64 host: every
  section records (unavailability is data), redaction counts present,
  archive + submission built; live submit round-tripped through the
  worker and is served at the sample URL above.

## Notes for reviewers

- The dashboard (community-data worker) now shows a Kind column so e2e
  reports are distinguishable from mlx-omarchy quick/deep rows.
- `--submit` is opt-in per run; the default writes local files only.
- The e2e payload adds six nullable summary fields
  (`test_id`, `install_path`, `asahi_image`, `encryption`,
  `boot_separate`, `overall`) to the community-data schema; old
  collectors are unaffected and the fields are optional.
