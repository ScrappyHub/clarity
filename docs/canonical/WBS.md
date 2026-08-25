# Clarity — Work Breakdown Structure

WBS version: 2.0 (audited)
Date: 2026-08-20
Legend: **GREEN** = implemented and tested · **PARTIAL** = implemented, gaps named · **SCAFFOLD** = request/stub only · **PLANNED** = specified, not built.
Status reflects the **working tree** on device `anakin`, which is ahead of git `HEAD` (see `CURRENT_STATE.md` §1, §7).

---

## WBS 0 — Constitutional definition — GREEN

0.1 Validator identity · 0.2 validator/non-agent boundary · 0.3 embedded + USB modes · 0.4 five-action lifecycle · 0.5 FULL/DEGRADED/FAIL · 0.6 NORMAL/RESTRICTED/DENY · 0.7 deterministic-evidence requirement · 0.8 non-residency. **All complete.** Assurance ladder A0–A4 added since original (GREEN).

## WBS 1 — Deterministic evidence substrate (Tier-0) — GREEN

1.1 standalone bootstrap · 1.2 runtime layout · 1.3 canonical hashing · 1.4 packet generation · 1.5 Option A verification · 1.6 Ed25519 signatures (dev) · 1.7 allowed-signers trust · 1.8 pledge ledger · 1.9 optional NFL duplicate · 1.10 content-addressed library · 1.11 append-only library ledger · 1.12 grant-controlled `library_get`. **All GREEN.** Proven: `CLARITY_TIER0_STEP2_OK`, `CLARITY_TIER0_STEP3_OK`.
**DoD:** met.

## WBS 2 — Protected-display session substrate — GREEN

2.1 session schema · 2.2 open · 2.3 close · 2.4 receipts · 2.5 protected-display model · 2.6 replay view · 2.7 replay timeline. **All GREEN.**
**DoD:** met.

## WBS 3 — Windows Sandbox adapter — PARTIAL

3.1 adapter request GREEN · 3.2 `.wsb` generation GREEN · 3.3 adapter receipt GREEN · 3.4 display-lifecycle integration GREEN · 3.5 replay integration GREEN · 3.6 isolated content injection PLANNED · 3.7 launch-lifecycle proof PLANNED · 3.8 termination proof PLANNED · 3.9 host-mutation negative proof PLANNED. Proven to request level: `CLARITY_TIER1_STEP2_OK`, `CLARITY_TIER1_STEP3_OK`.

## WBS 4 — Validator preflight — GREEN (host tier)

4.1 build inventory · 4.2 build hashing · 4.3 TPM discovery · 4.4 runtime readiness · 4.5 platform metadata · 4.6 trust-tier computation · 4.7 handoff gate · 4.8 FAIL-must-deny invariant · 4.9 DEGRADED-explicit-authorization. **All GREEN.** Assurance-cap test proves the host path cannot reach FULL (`PREFLIGHT_ASSURANCE_CAP_TEST_OK`).
**Next maturity (PLANNED):** Secure Boot policy correlation, UEFI state, measured boot, PCR evidence, boot-target identity, baseline policy — these move preflight from A1 toward A3.

## WBS 5 — Hyper-V adapter — SCAFFOLD + profile engine PARTIAL

5.1 session integration GREEN · 5.2 request JSON GREEN · 5.3 launch stub GREEN · 5.4 adapter receipt GREEN · 5.5 session close GREEN · 5.6 replay integration GREEN · 5.7 VM provisioning PLANNED · 5.8 deterministic VM template PLANNED · 5.9 isolated networking policy PLANNED (declared in profiles) · 5.10 disposable guest disk PLANNED · 5.11 guest-boot proof PLANNED · 5.12 content injection PLANNED · 5.13 teardown proof PLANNED · 5.14 host-contamination negative proof PLANNED. Proven to scaffold: `CLARITY_TIER1_STEP5_OK`.

### WBS 5A — VM profile / snapshot compatibility — GREEN (new)

5A.1 `clarity.vm_profile.v1` schema GREEN · 5A.2 two profiles (hyperv, sandbox) GREEN · 5A.3 `vm_profile_validate.ps1` GREEN · 5A.4 profile-hash + configuration-hash binding GREEN · 5A.5 `clarity.vm_snapshot.v1` + manifest verification GREEN · 5A.6 `manifest_only`-stays-deferred rule GREEN · 5A.7 `clarity.vm_compatibility.v1` decisions (compatible/deferred/deny) GREEN · 5A.8 negative tests (hash mismatch, running-state, required-snapshot) GREEN (`VM_PROFILE_SNAPSHOT_TEST_OK`). Live-VM correlation remains WBS 5.7–5.14.

## WBS 6 — Targeted integrity scanner — PARTIAL (≈45%)

6.1 scan schema `clarity.validator_scan.v1` GREEN · 6.2 target registry PARTIAL (hard-coded roots; `clarity_rules.json` not yet consumed) · 6.3 baseline registry PLANNED · 6.4 file hashing PLANNED · 6.5 signature validation PLANNED · 6.6 ruleset evaluation PLANNED (rules file exists, unused) · 6.7 classification taxonomy PLANNED (only `ZERO_LENGTH_EXECUTABLE` today) · 6.8 scan receipt GREEN · 6.9 scan summary GREEN · 6.10 negative tests PARTIAL (clean/suspicious/tamper via host-slice; missing-critical-file and changed-hash tests PLANNED). Proven: `CLARITY_TIER1_STEP6_SCAN_OK`, `HOST_SLICE_TEST_OK`.
**Priority next task:** wire `clarity_rules.json` + per-file hashing + baseline + full `verified/unknown/suspicious/compromised` taxonomy.

## WBS 7 — Isolation vault — PARTIAL (≈65%)

7.1 isolation object schema (`meta.v1`) GREEN (formalize to `schemas/`) · 7.2 isolation session/ledger schema GREEN (formalize) · 7.3 CAS-backed vault GREEN · 7.4 copy-to-vault GREEN · 7.5 vault copy verification GREEN · 7.6 metadata capture GREEN · 7.7 isolation receipt + hash-chained ledger GREEN · 7.8 execution-block abstraction PLANNED · 7.9 critical-file safety gate PLANNED · 7.10 restoration pipeline (`isolation_restore.ps1`) PLANNED · 7.11 restoration receipts PLANNED · 7.12 negative proofs PARTIAL (source-not-deleted, hash-equality, path-injection, reparse, source-changed-during-copy all covered; corrupt-vault-copy-rejected and unauthorized-restore-denied PLANNED). Proven via host-slice: `HOST_SLICE_TEST_OK`.
**Required token when complete:** `CLARITY_TIER1_STEP7_OK`.

## WBS 8 — Real handoff / boot-target verification — PLANNED (≈10%)

8.1 identify boot target · 8.2 hash boot target · 8.3 signature verification · 8.4 expected-signer policy · 8.5 baseline identity · 8.6 Secure Boot correlation · 8.7 measured-boot correlation · 8.8 boot-decision artifact · 8.9 fail-closed implementation. **Not started.** The current handoff gate reasons over trust tier + scan/isolation counts, not a real boot target; the `HANDOFF_TARGET_*` reason-code family is reserved and unused.

## WBS 9 — Composed validator run + sealing — PARTIAL (≈80%)

9.0 composed run `validator_run.ps1` GREEN · 9.0v run verifier `validator_verify_run.ps1` GREEN (hash + cross-phase consistency + tamper detection) · 9.1 **run-level Ed25519 signing / sealed bundle** PLANNED (run manifest is hash-bound but unsigned) · 9.2 sealed `validator_runs/<run_id>/` bundle with `sha256sums.txt` + `signature.sig` PLANNED. Once Action 2 (WBS 8) exists, the run inserts a `handoff_target` phase.

## WBS 10 — Protected validator result screen — PLANNED

Turn the CLI/replay surface into a human-facing shell (STARTING → VALIDATING PLATFORM → VERIFYING BOOT TARGET → SCANNING → ISOLATING → RESULT). Every displayed number MUST derive from the sealed evidence run; the display is not decorative. **Not started.**

## WBS 11 — Bootable external validator (Mode B) — PLANNED (<10%)

11.1 minimal boot environment (WinPE/Linux/UEFI app) · 11.2 offline runtime · 11.3 read-only internal-volume discovery · 11.4 validator launch · 11.5 vault target · 11.6 evidence export · 11.7 USB self-integrity · 11.8 deterministic image build · 11.9 secure signing. **Not started.** `make_offline_usb.ps1` is an early stub only.

## WBS 12 — Firmware / UEFI implementation (Mode A) — PLANNED (<10%)

Small trusted UEFI launcher → verify validator image → launch protected second-stage validator → scan/isolate/review → sealed decision → handoff/deny. Reimplemented in a firmware-capable language (Rust/C/C++/UEFI app) that **reproduces, never redefines**, the reference semantics. **Not started.** Do not begin before WBS 6–9 are green.

## WBS 13 — Governance & hygiene — PARTIAL (new, near-term)

13.1 commit the uncommitted validator-shell layer on a branch **(urgent)** · 13.2 prune `.bak/.corrupt/.broken` debris + stray `ce,')/` dir · 13.3 clear stale `.git/index.lock` · 13.4 author missing canonical docs `IDENTITY.md`/`SPEC.md`/`CURRENT_STATE.md`/`WBS.md`/`DEFINITION_OF_DONE.md` (this delivery covers SPEC/CURRENT_STATE/WBS/DoD) · 13.5 classify ecosystem role via `docs/proposals` · 13.6 formalize inline schemas (`isolation_object_meta.v1`, `isolation_ledger.v1`) into `schemas/`.

---

## Frozen implementation sequence (next)

```
STEP 6+  Scanner depth: consume clarity_rules.json, per-file hashing, baseline, full taxonomy
STEP 7   Isolation restore + execution-block + critical-file safety gate  -> CLARITY_TIER1_STEP7_OK
STEP 9.1 Sign/seal the validator-run bundle
STEP 8   Real boot/handoff-target verifier (Action 2)
STEP 10  Protected result screen
STEP 11  Real Hyper-V disposable review VM (WBS 5.7-5.14)
STEP 12  Bootable validator (Mode B)
STEP 13  UEFI launcher prototype (Mode A)
```

Governance note (WBS 13.1) is the single most urgent item: the validator-shell layer is currently unversioned.
