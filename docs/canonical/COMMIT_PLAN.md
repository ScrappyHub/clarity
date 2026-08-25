# Clarity — Commit Plan: validator-shell milestone

Date: 2026-08-20
Purpose: version the uncommitted validator-shell layer (currently unversioned — the single most urgent item from the audit), grouped into reviewable commits, with the tree already clean of debris.

---

## Preconditions

1. **Stale lock.** `.git/index.lock` (0 bytes) is present and blocks all git writes. Remove it first:
   `Remove-Item "C:\dev\clarity\.git\index.lock" -Force`
   (Only safe because no other git process is running. If a real git command is mid-flight, let it finish instead.)
2. **Debris needs no action.** Every `.bak/.corrupt/.broken/.pre_restore` snapshot, `archive/`, `reports/`, `key`, `*.pub`, and the `scripts/patch_*` / `_PATCH_` / `_restore_` families are already covered by `.gitignore`. They are **not tracked** and will **not** enter any commit. The `ce,')/` stray directory is also untracked and ignored. No `git rm` is required for cleanup.

---

## Branch

```
feat/validator-shell-milestone   (off main)
```

---

## Commit grouping (5 commits)

### Commit 1 — feat: validator shell core (preflight → scan → isolate → handoff → run/verify)

The deterministic, fail-closed host validator chain and its evidence schemas + tests.

Files:
```
scripts/validator_preflight.ps1            (M)
scripts/validator_handoff_gate.ps1         (M)
scripts/validator_scan_targeted.ps1        (new)
scripts/validator_isolate_copy.ps1         (new)
scripts/validator_run.ps1                  (new)
scripts/validator_verify_run.ps1           (new)
scripts/_RUN_clarity_tier1_step6_v1.ps1    (new)
scripts/test_validator_host_slice.ps1      (new)
scripts/test_preflight_assurance_cap.ps1   (new)
schemas/clarity.validator_preflight.v1.schema.json          (new)
schemas/clarity.validator_scan.v1.schema.json               (new)
schemas/clarity.validator_finding.v1.schema.json            (new)
schemas/clarity.isolation_report.v1.schema.json             (new)
schemas/clarity.validator_handoff_decision.v1.schema.json   (new)
schemas/clarity.validator_run.v1.schema.json                (new)
```

### Commit 2 — feat: VM profile / snapshot compatibility engine

Profile + snapshot validation with hash binding and manifest-only-stays-deferred policy.

Files:
```
scripts/vm_profile_validate.ps1            (new)
scripts/test_vm_profile_snapshot.ps1       (new)
vm_profiles/protected_review_hyperv.v1.json    (new)
vm_profiles/protected_review_sandbox.v1.json   (new)
schemas/clarity.vm_profile.v1.schema.json      (new)
schemas/clarity.vm_snapshot.v1.schema.json     (new)
schemas/clarity.vm_compatibility.v1.schema.json (new)
```

### Commit 3 — feat: protected-display adapter updates + display schemas

Hyper-V / Sandbox / replay / session refinements and the display request schemas + event contracts.

Files:
```
scripts/display_adapter_hyperv.ps1          (M)
scripts/display_adapter_windows_sandbox.ps1 (M)
scripts/display_replay_view.ps1             (M)
scripts/display_session_open.ps1            (M)
scripts/display_session_close.ps1           (M)
scripts/lib/clarity_display_common.ps1      (M)
scripts/_RUN_clarity_tier1_step2_v1.ps1     (M)
scripts/_RUN_clarity_tier1_step3_v1.ps1     (M)
scripts/_RUN_clarity_tier1_step5_v1.ps1     (M)
scripts/test_protected_display.ps1          (new)
schemas/clarity.display_receipt.v1.schema.json          (M)
schemas/clarity.display_session.v1.schema.json          (M)
schemas/clarity.display_adapter_request.v1.schema.json  (new)
schemas/clarity.display_hyperv_request.v1.schema.json   (new)
contracts/display_event_types.v1.json       (M)
contracts/event_types.v1.json               (M)
```

### Commit 4 — docs: canonical spec/WBS/DoD/audit, threat models, ecosystem governance

The new canonical docs (incl. this audit's SPEC/WBS/DoD/CURRENT_STATE), threat models, and the Atlas ecosystem/governance files.

Files:
```
docs/canonical/                             (new dir: SPEC.md, WBS.md, DEFINITION_OF_DONE.md, CURRENT_STATE.md, ECOSYSTEM_INTEGRATION.md)
docs/ASSURANCE_AND_TRUST_MODEL.md           (new)
docs/HOST_VALIDATOR_THREAT_MODEL.md         (new)
docs/PROTECTED_DISPLAY_THREAT_MODEL.md      (new)
docs/VM_PROFILE_SNAPSHOT_THREAT_MODEL.md    (new)
docs/HYPERV_ADAPTER_MODEL.md                (M)
docs/PROTECTED_DISPLAY_MODEL.md             (M)
docs/PUBLIC_PRODUCT_SURFACE.md              (M)
AGENTS.md                                   (new)
CLAUDE.md                                   (new)
project.contract.json                       (new)
README.md                                   (M)
```

---

### Commit 5 — chore: remove legacy monolithic v1 scripts

`git rm` the pre-shell monolithic runners, superseded by the composed validator chain and absent from the public product surface. The script guards this with `git ls-files --error-unmatch` so it skips cleanly if they're already gone.

Files:
```
scripts/clarity.ps1        (git rm)
scripts/run_clarity.ps1    (git rm)
```

---

## Deliberately excluded (your call — not staged by the script)

- `scripts/_RUN_clarity_patch_pipeline_step5_v1.ps1` — untracked "patch pipeline" runner; looks like one-off build tooling, not product. Not in `PUBLIC_PRODUCT_SURFACE.md`. Decide: keep (add to a tooling commit) or delete.

---

## Post-commit sanity checks (recommended before pushing)

Run the green-token tests to confirm the committed tree still proves out:
```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_validator_host_slice.ps1     -RepoRoot C:\dev\clarity   # HOST_SLICE_TEST_OK
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_preflight_assurance_cap.ps1   -RepoRoot C:\dev\clarity   # PREFLIGHT_ASSURANCE_CAP_TEST_OK
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test_vm_profile_snapshot.ps1       -RepoRoot C:\dev\clarity   # VM_PROFILE_SNAPSHOT_TEST_OK
```

Then push:
```
git push -u origin feat/validator-shell-milestone
```

Nothing is pushed to `origin` until you run that line.
