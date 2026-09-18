# E2E evidence collector for the volunteer install checklist

Companion to Naeem's `omarchy-mac-e2e-volunteer-checklist.md` (already in
`docs/`). The checklist names what a volunteer must observe; this adds a
collector that gathers everything a machine can observe, redacts identity
strings, and packs the result into a reviewable archive — so E2E reports
arrive complete and consistent instead of hand-assembled.

## What volunteers get

One command, no clone:

```bash
curl -fsSL https://raw.githubusercontent.com/omacom/omarchy-mac/quattro/bin/omarchy-mac-e2e-collect -o e2e-collect
bash e2e-collect --interview --out e2e-<testid>.tar.gz
```

- `--interview` walks all 34 human-judgment checkboxes from the checklist
  (reboot checkpoints A/B/C, desktop, persistence/security, overall
  result) recording PASS/FAIL/SKIP/NA with notes; answers persist in
  `./e2e-answers.json` across checkpoint re-runs.
- Machine evidence is gathered automatically: fresh-Asahi baseline
  commands, derived storage facts (LUKS present, `/boot` separate,
  freshness marker), installer log tails, `omarchy-mac-setup --status`,
  journal boot list, failed system/user units, install state (version,
  pinned packages, `omarchy-migrate --pending` with its inverted exit
  semantics recorded rather than interpreted, `omarchy-done` checks),
  security-cleanup probes, plus the mlx-omarchy quick capability report
  (device, Vulkan/Mesa, ANE devicetree, installed distributions).
- Output: a deterministic, redacted archive (usernames, hostnames, home
  paths, IPs, MACs, serials, credential-shaped strings — per-kind counts
  in the manifest) and `e2e-<testid>.submission.md`, a paste-ready cover
  with the checklist report template pre-filled where the machine could
  answer.

Nothing uploads by default. `--submit` opts into the community-data
worker protocol (kind `omarchy-mac-e2e`), which the live worker already
accepts — sample record:
https://mlx-omarchy-community-data.joshua-s-warren.workers.dev/v1/results/ef89a1c651ce3cb599be62dc7baa49f8bacb5e76e9e3a56d41b0fddd60627ff3

## How it is built

`scripts/collect_e2e.py` plus four files vendored unchanged from
joshuaswarren/mlx-omarchy (`collect_common`, `collect_submit`,
`collect_quick`, `collect_macos`; one lazy `bench_matrix` import so the
set is self-contained). Those collectors are field-proven: checksummed
artifacts, consent-gated uploads, deterministic archives, PII redaction.
Every external command is bounded; missing tools and absent logs are
recorded as data, never crashes; partial runs keep completed sections.

The worker-side change (kind `omarchy-mac-e2e` + six nullable summary
fields, table constraint widened, regression smoke scenario, dashboard
Kind column) is merged in joshuaswarren/mlx-omarchy@main and deployed.

## Verification

- Worker unit tests 67/67 (new e2e schema fixture + kind checks); live
  worker deployed, `check_schema_identity.py` green.
- Collector exercised end to end on a non-Apple x86_64 host: all sections
  record (unavailability is data), redaction counts present, archive +
  submission built, live submit round-tripped through the worker.
- The bootstrap (`bin/omarchy-mac-e2e-collect`) tested against this
  branch's raw URLs; it defaults to `omacom/omarchy-mac@quattro`, so it
  starts working for volunteers the moment this merges.

Full design and section-to-checklist mapping:
docs/e2e-collector.md
