# Clarity — Current State Audit

Audit date: 2026-08-20
Repository: `C:\dev\clarity` (public: `ScrappyHub/clarity`)
Auditor scope: full working tree on device `anakin`, reconciled against the canonical handoff document and the in-repo docs.
Assurance ceiling of everything below: **A1_HOST_OBSERVED** (host-observed capability + deterministic local evidence). No firmware, measured-boot, or hardware-attestation claim is made or supported.

---

## 1. Headline finding

The working tree is **materially ahead of both git `HEAD` and the prose handoff document.**

Git `HEAD` (`21ac2bb`) stops at "add Hyper-V adapter scaffold and step5 runner." Everything that makes Clarity behave like a validator rather than an evidence library — the targeted scanner, the isolation vault, the composed validator run, the run verifier, the VM-profile compatibility engine, and their negative tests — exists on disk but is **uncommitted** (`??` untracked or ` M` modified). The handoff document, meanwhile, still estimates the scanner and isolation vault at "10–20%." Both understate reality.

Corrected one-line status: **Clarity is a working, deterministic, fail-closed host-side validator shell with a complete preflight → scan → isolate → handoff → verify evidence chain, plus a VM-profile/snapshot compatibility engine. It is not yet a real boot-target verifier, not signed at the run level, and not firmware-resident.**

A secondary finding: this large body of validator work is unversioned. See §7 (Governance & risk).

---

## 2. What Clarity can actually do today (verified against source)

### 2.1 Tier-0 — deterministic evidence substrate (GREEN, committed)

Standalone bootstrap, Option A packet build/verify, local pledge append, optional NFL duplication, and a content-addressed library with an append-only ledger. Proven historically by `CLARITY_TIER0_STEP2_OK` and `CLARITY_TIER0_STEP3_OK`. Scripts present and stable: `_bootstrap_clarity_standalone_v1.ps1`, `make_packet.ps1`, `verify_packet.ps1`, `pledge_local.ps1`, `duplicate_to_nfl.ps1`, `library_put.ps1`, `library_get.ps1`. Option A invariant (manifest carries no `packet_id`; `packet_id.txt` does; `sha256sums.txt` last) is enforced and locked in `LAW.md`.

### 2.2 Tier-1 — protected-display / review substrate (GREEN, mostly committed)

Session open/close, append-only display receipts, replay view + timeline, a Windows Sandbox adapter, and a Hyper-V adapter at request/scaffold level. Proven historically by `CLARITY_TIER1_STEP2_OK` … `CLARITY_TIER1_STEP5_OK`. The adapters generate request artifacts and `.wsb`/launch stubs; they do **not** yet provision, boot, or tear down a live guest.

### 2.3 Validator shell — the new, largely uncommitted core

| Capability | Script | Output schema | State |
|---|---|---|---|
| Preflight + identity + capability probe | `validator_preflight.ps1` | `clarity.validator_preflight.v1` | GREEN, uncommitted (modified) |
| Targeted integrity scan | `validator_scan_targeted.ps1` | `clarity.validator_scan.v1` | GREEN (narrow), uncommitted |
| Isolation vault (copy-to-vault) | `validator_isolate_copy.ps1` | `clarity.isolation_report.v1` (+ object meta + hash-chained ledger) | GREEN (partial), uncommitted |
| Handoff decision gate | `validator_handoff_gate.ps1` | `clarity.validator_handoff_decision.v1` | GREEN, uncommitted (modified) |
| Composed validator run | `validator_run.ps1` | `clarity.validator_run.v1` | GREEN, uncommitted |
| Run artifact verifier | `validator_verify_run.ps1` | (re-verifies run manifest) | GREEN, uncommitted |
| VM-profile / snapshot compatibility | `vm_profile_validate.ps1` | `clarity.vm_compatibility.v1` | GREEN, uncommitted |

**Preflight** probes TPM presence/readiness, Secure Boot state, hypervisor presence, Windows Sandbox availability, OS/BIOS identity, and hashes every required validator script into the report. It **caps trust at `DEGRADED`** with reason `HOST_ONLY_ASSURANCE_CAP` — `FULL` is deliberately reserved for a future authenticated evidence path. Verified honest behavior: a real report on disk from device `ANAKIN` (Win 11, no TPM) returned `trust_tier=FAIL` with `RUNTIME_NOT_READY` + `TPM_ABSENT_OR_UNREADABLE`, and the assurance-cap test (`test_preflight_assurance_cap.ps1`) proves the host path can never reach `FULL`.

**Scan** is deterministic and fail-closed on its own errors (`scan_complete=false` when any access error occurs), and always emits a stable findings artifact (even at zero findings) so downstream steps have a fixed input. **Detection is currently narrow**: it flags only zero-length `.exe`/`.dll`/`.sys` files (`ZERO_LENGTH_EXECUTABLE`). It does not yet hash files against a baseline, check signatures, or consume `clarity_rules.json` (see §4). Token: `CLARITY_TIER1_STEP6_SCAN_OK`.

**Isolation vault** is the strongest of the new pieces. It copies (never moves) suspicious sources into a CAS vault (`vault/objects/sha256/<ab>/<hash>/content.bin` + `meta.json`) under the runtime root, and appends a **hash-chained** ledger line (`GENESIS` → `prev_log_hash` → `log_hash`). Enforced safety gates: findings must resolve inside the scan-declared roots (`FINDING_OUTSIDE_SCANNED_TARGETS`), findings file must live inside the scan report directory, reparse points are rejected, and the source is re-hashed before and after copy with the stored copy verified (`ISOLATION_SOURCE_CHANGED_DURING_COPY`, existing-object hash-match). It preserves the original and blocks nothing destructively.

**Handoff gate** is fail-closed: `FULL→normal`, `DEGRADED→restricted` only with explicit `-AllowDegraded` (else `deny`), `FAIL→deny`; and it independently denies on `SCAN_INCOMPLETE`, `SUSPICIOUS_FINDINGS_PRESENT`, or `UNEXPECTED_ISOLATION_COUNT`. A real report on disk shows `DEGRADED → restricted (DEGRADED_ALLOWED)`.

**Composed run + verifier** chain all four phases into one `clarity.validator_run.v1` manifest that binds each phase artifact by SHA-256; `validator_verify_run.ps1` recomputes every hash and re-checks cross-phase run-IDs and decision consistency, so any tampered artifact fails verification. The host-slice test (`test_validator_host_slice.ps1`, token `HOST_SLICE_TEST_OK`) exercises both a clean path (0 suspicious, 0 isolated, fail-closed `deny` without attestation) and a suspicious path (1 finding, 1 isolated, hash lineage checked), and asserts tamper is caught (`ARTIFACT_HASH_MISMATCH`).

**VM-profile compatibility** validates a `clarity.vm_profile.v1` against its adapter, resource floors, isolation configuration (networking/clipboard/host-fs must be disabled/none or it defers), host capability presence, and snapshot policy. It binds a profile hash and configuration hash, verifies snapshot manifests against them, and keeps `manifest_only` snapshot evidence **deferred, never compatible**. Decisions: `compatible` / `deferred` / `deny`. Two profiles ship (`protected_review_hyperv.v1.json`, `protected_review_sandbox.v1.json`). Negative test `test_vm_profile_snapshot.ps1` (token `VM_PROFILE_SNAPSHOT_TEST_OK`) proves profile-hash mismatch, disallowed running-state, and required-snapshot enforcement all deny.

### 2.4 Documentation substrate (GREEN, partly uncommitted)

Honest, well-structured models exist: `ASSURANCE_AND_TRUST_MODEL.md` (the A0–A4 ladder), `HOST_VALIDATOR_THREAT_MODEL.md`, `VM_PROFILE_SNAPSHOT_THREAT_MODEL.md`, `PROTECTED_DISPLAY_MODEL.md` + threat model, `HYPERV_ADAPTER_MODEL.md`, `REPLAY_VIEW_MODEL.md`, `PUBLIC_PRODUCT_SURFACE.md`, and `canonical/ECOSYSTEM_INTEGRATION.md`.

---

## 3. Corrected completion estimates

The handoff document's percentages predate the uncommitted work. Grounded re-estimate against the **hosted validator-shell** milestone:

| Area | Handoff doc | Audited reality | Note |
|---|---|---|---|
| Core concept / spec | 90% | 90% | Unchanged; strong |
| Evidence substrate (Tier-0) | 90% | 90% | Unchanged; GREEN |
| Protected display / session | 85% | 85% | Unchanged; GREEN |
| Validator preflight | 70% | 85% | Capability probe + assurance cap + tests done |
| Sandbox abstraction | 75% | 75% | Request-level; no live guest |
| Hyper-V abstraction | 55% | 60% | + profile/snapshot compatibility engine |
| Targeted scan | 10–20% | **45%** | Deterministic pipeline + tests done; detection still narrow |
| Isolation vault | 10–20% | **65%** | Copy/CAS/chained-ledger/safety-gates done; no restore or exec-block |
| Composed run + verify | (not listed) | **80%** | Full chain + tamper-checking verifier + host-slice test |
| VM profile/snapshot compat | (not listed) | **70%** | Engine + negative tests done; no live VM |
| Actual boot-target verification | 10–15% | 10% | Gate consumes trust tier + scan, not a real boot target |
| Bootable validator | <10% | <10% | Not started |
| Firmware-grade validator | <10% | <10% | Not started |

Overall hosted-shell milestone: the handoff doc's "~70–75%" is now conservatively **~80%**. The remaining shell gap is scanner depth, isolation restore/exec-block, and run-level signing.

---

## 4. Divergences and defects worth flagging

1. **`clarity_rules.json` is defined but unused by the scanner.** The rules file (v1_4) specifies fast-scan target points, critical prefixes, skip-dir names, startup/temp suspicious-extension lists, a double-extension regex, and quarantine modes/limits. `validator_scan_targeted.ps1` implements none of it — it hard-codes System32/SysWOW64/Program Files roots and only checks zero-length executables. This is the single largest capability gap between stated policy and behavior.

2. **Validator runs are hash-bound but not signed.** Tier-0 packets use Ed25519 (Option A) with allowed-signers trust. The `clarity.validator_run.v1` manifest binds phase artifacts by SHA-256 but is not itself signed, so `validator_verify_run.ps1` proves *internal integrity*, not *origin authenticity*. Sealing/signing the run is a named gap.

3. **No isolation restore or execution-block.** The vault preserves and records but cannot yet restore (`isolation_restore.ps1` absent) or apply the policy-driven execution restriction described in the architecture. Restore receipts and the critical-file safety gate are unimplemented.

4. **Handoff gate is not a boot-target verifier.** Action 2 ("verify the object about to receive execution") is not implemented against a real EFI/boot-manager/kernel target. The gate reasons over trust tier + scan/isolation counts only. The `HANDOFF_TARGET_*` reason-code family is designed but unused.

5. **Canonical docs referenced by `AGENTS.md` are missing.** `AGENTS.md`/`CLAUDE.md` instruct readers to consult `docs/canonical/IDENTITY.md`, `SPEC.md`, and `CURRENT_STATE.md` "when present" — none existed before this audit. (This document, plus the new `SPEC.md`, `WBS.md`, and `DEFINITION_OF_DONE.md`, begin closing that gap.)

6. **Ecosystem role is `unclassified`.** `project.contract.json` and `ECOSYSTEM_INTEGRATION.md` leave layer, owned responsibilities, upstream/downstream, and contract families unclassified. This is a governance to-do, not a code defect.

7. **Repository hygiene debris in the working tree.** Numerous `.bak_*`, `.corrupt_*`, `.broken_*` snapshots of `clarity.ps1`, `run_clarity.ps1`, `check_artifact.ps1`, and `clarity_rules.json` remain locally, plus a stray `ce,')/` directory and an `archive/`. `PUBLIC_PRODUCT_SURFACE.md` already declares these non-product; they should be pruned from the tracked tree.

---

## 5. Security invariants — observed status

| Invariant | Status | Evidence |
|---|---|---|
| I1 Verification must not mutate the object | HOLDS | Isolation copies, re-hashes source pre/post copy |
| I2 FAIL never yields NORMAL handoff | HOLDS | Gate maps FAIL→deny unconditionally |
| I3 DEGRADED never silently becomes FULL | HOLDS | Preflight caps at DEGRADED; assurance-cap test |
| I4 Isolation preserves recoverability | PARTIAL | Copy + ledger preserve; restore path not built |
| I5 Never silently deletes evidence | HOLDS | Copy-not-move; append-only ledger |
| I6 Every security decision has a reason code | HOLDS | Reason/deny/defer codes throughout |
| I7 Unique protected-display session identity | HOLDS | GUID session IDs |
| I8 Replay refers to exact originating session | HOLDS | Replay bound to session ID |
| I9 Optional integrations never become correctness deps | HOLDS | NFL optional; LAW.md standalone-first |
| I10 No private signing keys in the repo | HOLDS (post-rotation) | Key rotated; history rewritten |
| I11 Clarity exits after handoff | HOLDS (by design) | Non-resident scripts |
| I12 Never claim stronger trust than measured | HOLDS | A1 cap + explicit `attestation_status=unavailable` |

---

## 6. What must not be claimed yet

Clarity does **not** run in BIOS/firmware; does **not** verify a real boot target; does **not** prevent bootkits/rootkits; does **not** create or boot live isolation VMs; does **not** sign its validator-run evidence; and is **not** certified for any regulated/defense environment. The scanner is a deterministic harness with one heuristic, not a malware detector. These are consistent with the project's own §45 "must not claim yet" list and must remain so until the corresponding tiers are proven.

---

## 7. Governance & immediate risk

The primary near-term risk is **not** technical — it is that roughly a dozen substantive, tested validator scripts and schemas are **uncommitted**. A lost working tree would erase the entire validator-shell layer. Recommended immediate action: commit the validator-shell work (preflight/scan/isolate/handoff/run/verify + VM profile + tests + schemas + docs) on a branch, prune the `.bak/.corrupt/.broken` debris, and tag the hosted-shell milestone. A stale `.git/index.lock` was observed and should be cleared before committing.

---

## 8. Next implementation boundary

Consistent with the spec's frozen sequence, the next green-able work is: (a) make the scanner consume `clarity_rules.json` and add per-file hashing + a real classification taxonomy; (b) add isolation restore + execution-block + critical-file safety gate; (c) sign the validator-run manifest. Real boot-target verification (Action 2 / Tier-2) follows. Firmware/UEFI remains last and must reproduce, not redefine, the reference semantics proven here.
