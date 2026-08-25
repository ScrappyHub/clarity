# Clarity — System Specification

Spec version: 2.0 (audited baseline)
Date: 2026-08-20
Status: canonical. Supersedes prose handoff estimates where they conflict with observed behavior (see `CURRENT_STATE.md`).
Repository: `C:\dev\clarity` · Runtime root: `C:\ProgramData\Clarity` · Public: `ScrappyHub/clarity`

This document specifies what Clarity **is**, the contracts it **must** honor, and the behavior each implemented and planned component **must** exhibit. It is written so that a firmware or native reimplementation can reproduce the reference semantics without reading the PowerShell.

---

## 1. Identity and scope

Clarity is a **validator-as-validator**: a deterministic trust-boundary instrument that runs *before* a device, OS, executable, boot target, or artifact is trusted, decides what may be trusted, isolates what may not, produces cryptographically checkable evidence, renders a decision, and then **exits**. Non-residency is a required property, not an accident.

Clarity is **not** an antivirus daemon, EDR, SIEM, telemetry platform, endpoint agent, OS security service, general hypervisor, or malware-removal engine. It may *consume* Secure Boot, TPM, measured boot, and platform attestation as evidence; it does not replace them.

Canonical decisions: `NORMAL`, `RESTRICTED`, `DENY`.
Canonical trust tiers: `FULL`, `DEGRADED`, `FAIL`.
Canonical assurance ladder: `A0_UNAVAILABLE` · `A1_HOST_OBSERVED` · `A2_ISOLATED_REVIEW` · `A3_MEASURED_PLATFORM` · `A4_ATTESTED_PLATFORM`.

The current implementation operates at **A1** (with partial A2 via the review adapters) and must report that ceiling explicitly. It must never imply A3/A4.

### 1.1 Delivery modes (target)

- **Mode A — embedded/installed validator**: firmware storage, EFI system partition, protected boot partition, OEM recovery, or a dedicated immutable validator partition. Executes before normal OS handoff.
- **Mode B — external validator media**: USB/external boot media that inspects an internal disk from a trusted external reference.

Both modes MUST emit materially identical evidence: same reason codes, evidence schemas, hashing rules, report format, trust tiers, and handoff rules.

---

## 2. Canonical lifecycle (five actions)

```
ACTION 1  Preflight + validator/device identity
ACTION 2  Boot / handoff-target verification
ACTION 3  Targeted integrity scan
ACTION 4  Isolation / quarantine vault
ACTION 5  Evidence sealing + controlled handoff
```

Composed reference flow (implemented today as `validator_run.ps1`):

```
preflight -> scan -> isolate -> handoff-decision -> (verify)
```

Action 2 (real boot-target verification) is **specified but not yet implemented**; the composed run currently jumps from preflight to scan. The composed flow MUST remain fail-closed at every phase boundary.

---

## 3. Determinism and engineering contract

1. Product files are emitted **UTF-8 without BOM, LF line endings**.
2. PowerShell product files are **parse-gated** (`Parser::ParseFile` must succeed) and executed in a fresh `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File`.
3. Hashing is **SHA-256**; canonical text hashing normalizes before hashing (`Sha256HexTextNormalized`).
4. Content addressing uses `cas:sha256:<64-hex>` and the layout `objects/sha256/<first-2>/<full-hash>/`.
5. Receipts and ledgers are **append-only**; ledgers are **hash-chained** (`GENESIS` → `prev_log_hash` → `log_hash`).
6. Given the same inputs (file, validator build, ruleset, baseline, platform state), a phase MUST produce the same classification.
7. **Verification must never mutate the object being verified** (Invariant I1).
8. Builders/patchers/scratch are not product evidence; the emitted product file is.

---

## 4. Component specifications

### 4.1 Action 1 — Preflight and identity  (`validator_preflight.ps1`, IMPLEMENTED)

Establishes validator identity (validator name, mode, per-script build hashes), device identity (computer name, OS caption/version, BIOS version), and capability state (TPM present/ready, Secure Boot state, hypervisor present, Windows Sandbox available, `attestation_status`), plus runtime readiness (keys, allowed-signers, outbox, pledges, library ledger, display receipts).

Trust-tier computation (reference behavior, MUST hold):

- If any required script is missing OR runtime is not ready → `FAIL`.
- Otherwise → `DEGRADED`. **The host path may never return `FULL`.** `FULL` is reserved for a future authenticated/measured evidence path.
- `reason_codes` MUST include `HOST_ONLY_ASSURANCE_CAP`; `assurance_level` MUST be `A1_HOST_OBSERVED`.

Output: `clarity.validator_preflight.v1`.

### 4.2 Action 2 — Boot / handoff-target verification  (SPECIFIED, NOT IMPLEMENTED)

Verifies the object about to receive execution (EFI executable, boot manager, bootloader, kernel image, recovery env, VM image, signed executable) without mutating it. Evidence MUST consider: SHA-256 identity, expected manifest, digital signature and signer identity, Secure Boot policy, a known-good baseline, and (where available) measured-boot/TPM correlation.

Required verdict vocabulary:

```
HANDOFF_TARGET_VALID
HANDOFF_TARGET_UNKNOWN
HANDOFF_TARGET_MODIFIED
HANDOFF_TARGET_UNSIGNED
HANDOFF_TARGET_REVOKED
HANDOFF_TARGET_POLICY_DENIED
```

Until implemented, the handoff gate (§4.5) MUST NOT be described as boot-target verification.

### 4.3 Action 3 — Targeted integrity scan  (`validator_scan_targeted.ps1`, IMPLEMENTED — narrow)

Scans high-signal targets rather than every byte. Reference behavior that MUST hold:

- On any enumeration/access error the scan is **not clean**: `scan_complete=false`, and downstream handoff MUST deny (`SCAN_INCOMPLETE`).
- A zero-finding scan is still valid and MUST still emit the stable findings artifact (empty file) so isolation/replay have a fixed input.
- Each finding carries at least `target_path`, `reason_code`, `severity`.

**Current detection is narrow**: only zero-length `.exe`/`.dll`/`.sys` (`ZERO_LENGTH_EXECUTABLE`) against hard-coded system roots. Token: `CLARITY_TIER1_STEP6_SCAN_OK`. Output: `clarity.validator_scan.v1`.

Required maturation (see WBS 6): consume `clarity_rules.json` (target points, critical prefixes, skip-dirs, suspicious-extension and double-extension rules, limits); add per-file hashing, signature/signer validation, and a baseline registry; and produce the full classification taxonomy:

```
verified | unknown | suspicious | compromised          (per-file status)
allow | review | isolate | deny                        (recommended action)
```

### 4.4 Action 4 — Isolation vault  (`validator_isolate_copy.ps1`, IMPLEMENTED — copy path)

Principle: **preserve first, disable execution second, destroy nothing automatically.**

Reference behavior that MUST hold:

- **Copy, never move.** The original is never deleted or modified.
- Store into a CAS vault under the runtime root: `vault/objects/sha256/<ab>/<hash>/content.bin` + `meta.json`.
- Re-hash the source **before and after** copy and verify the stored copy equals the source; abort on any drift (`ISOLATION_SOURCE_CHANGED_DURING_COPY`).
- Every finding path MUST resolve inside the scan-declared roots (`FINDING_OUTSIDE_SCANNED_TARGETS`); the findings file MUST live inside the scan report directory; reparse-point sources are rejected.
- Append one **hash-chained** ledger line per isolated object (`clarity.isolation_ledger.v1`).
- Emit `clarity.isolation_report.v1` with `isolated_count`.

**Not yet implemented** (WBS 7): `isolation_restore.ps1` (authorized restore + restore receipts), the execution-block abstraction, and the critical-boot-file safety gate (boot-critical objects: never auto-delete, never auto-overwrite, never move without a verified recovery path — deny boot / offer recovery / offer protected review / preserve evidence instead).

### 4.5 Action 5 — Handoff decision  (`validator_handoff_gate.ps1`, IMPLEMENTED)

Fail-closed gate. Reference mapping that MUST hold:

- `FULL → normal` (allowed).
- `DEGRADED → restricted` only when explicit allowance is passed (`-AllowDegraded`); otherwise `deny` (`DEGRADED_REQUIRES_EXPLICIT_ALLOW`).
- `FAIL → deny`.
- If a scan/isolation pair is supplied: `scan_complete=false → deny (SCAN_INCOMPLETE)`; `suspicious_count>0 → deny (SUSPICIOUS_FINDINGS_PRESENT)`; `isolated_count` inconsistent → `deny (UNEXPECTED_ISOLATION_COUNT)`.
- Scan and isolation paths MUST be supplied together or not at all.

Output: `clarity.validator_handoff_decision.v1`, referencing the exact preflight/scan/isolation artifacts used.

### 4.6 Composed run + verifier  (`validator_run.ps1` / `validator_verify_run.ps1`, IMPLEMENTED)

`validator_run.ps1` runs preflight → scan → isolate → handoff and writes `clarity.validator_run.v1`, binding each phase artifact (and the findings and ledger files) by SHA-256, plus a top-level `decision` block.

`validator_verify_run.ps1` MUST: recompute every bound hash (`ARTIFACT_HASH_MISMATCH` on drift); re-read each phase artifact and confirm cross-phase agreement of trust tier, run-IDs, suspicious/isolated counts, and handoff decision/allowed; and confirm the run-level decision matches its phases. This proves **internal integrity**. It does **not** prove origin authenticity — the run manifest is not yet signed (see WBS 9.1).

### 4.7 Protected review adapters  (IMPLEMENTED — request level)

- **Protected display**: session open/close, append-only display receipts, replay view + timeline. Every session has a unique identity (I7); replay refers to the exact session (I8).
- **Windows Sandbox adapter**: generates adapter request + `.wsb` config + receipts. Token `CLARITY_TIER1_STEP2/3_OK`.
- **Hyper-V adapter**: generates `request.json` + `launch.cmd` under `display/adapters/hyperv/requests/<session_id>/`. Token `CLARITY_TIER1_STEP5_OK`.

These adapters are **development surfaces, not authoritative trust sources**, and do not yet provision, boot, inject content into, or tear down a live guest.

### 4.8 VM profile / snapshot compatibility  (`vm_profile_validate.ps1`, IMPLEMENTED)

Validates a `clarity.vm_profile.v1` and, optionally, a `clarity.vm_snapshot.v1` manifest. Reference behavior that MUST hold:

- Bind a `profile_hash` and `configuration_hash` (normalized SHA-256) into the report.
- Deny on: adapter mismatch, placeholder profile-id, invalid vCPU/memory floors, Secure-Boot-required-but-disabled, snapshot forbidden-by-policy, snapshot profile-id/profile-hash/configuration-hash mismatch, disallowed snapshot state, or required-but-missing snapshot.
- Defer (never silently pass) on: unresolved guest image digest, networking/clipboard/host-fs not locked down, unavailable hypervisor/sandbox, unobserved Secure Boot, required guest measurement, and `manifest_only` snapshot evidence (`SNAPSHOT_CONTENT_NOT_VERIFIED`).
- Decision: `compatible` / `deferred` / `deny`. Assurance stays `A1_HOST_OBSERVED`.

Output: `clarity.vm_compatibility.v1`. This engine establishes *profile compatibility and provenance of locally produced request artifacts only* — never that the hypervisor, firmware, guest image, disk, or hardware is trustworthy.

---

## 5. Evidence schemas (canonical registry)

Implemented (`schemas/`): `clarity.validator_preflight.v1`, `clarity.validator_scan.v1`, `clarity.validator_finding.v1`, `clarity.isolation_report.v1`, `clarity.validator_handoff_decision.v1`, `clarity.validator_run.v1`, `clarity.display_session.v1`, `clarity.display_receipt.v1`, `clarity.display_adapter_request.v1`, `clarity.display_hyperv_request.v1`, `clarity.vm_profile.v1`, `clarity.vm_snapshot.v1`, `clarity.vm_compatibility.v1`. Additional emitted-but-inline schemas to formalize: `clarity.isolation_object_meta.v1`, `clarity.isolation_ledger.v1`.

Target sealed run bundle (`validator_runs/<run_id>/`): `report.json`, `preflight.json`, `handoff_target.json`, `scan_results.ndjson`, `isolation_manifest.json`, `handoff_decision.json`, `sha256sums.txt`, `signature.sig`. Every value shown to a human MUST derive from these artifacts.

---

## 6. Reason-code architecture

Reason codes are **stable, machine-checkable identifiers** and MUST NOT depend on prose parsing. Families:

- **Validator/assurance**: `HOST_ONLY_ASSURANCE_CAP`, `VALIDATOR_BUILD_OK/MISMATCH`, `VALIDATOR_POLICY_OK/INVALID`.
- **Runtime/platform**: `RUNTIME_NOT_READY`, `MISSING_REQUIRED_SCRIPTS`, `TPM_ABSENT_OR_UNREADABLE`, `TPM_READY`, `SECURE_BOOT_ENABLED/DISABLED`, `FIRMWARE_MEASUREMENT_UNAVAILABLE`.
- **Handoff-target** (reserved, Action 2): `HANDOFF_TARGET_VALID/UNKNOWN/MODIFIED/UNSIGNED/REVOKED/POLICY_DENIED`.
- **Scan/file**: `ZERO_LENGTH_EXECUTABLE` (current); planned `FILE_VERIFIED/HASH_MISMATCH/UNSIGNED/SIGNER_UNTRUSTED/BASELINE_UNKNOWN/POLICY_DENIED`.
- **Isolation**: `FINDING_OUTSIDE_SCANNED_TARGETS`, `REPARSE_POINT_SOURCE_REJECTED`, `ISOLATION_SOURCE_CHANGED_DURING_COPY`, `SCAN_FINDING_COUNT_MISMATCH`; planned `ISOLATION_REQUIRED/COPY_OK/BLOCK_OK/RESTORE_REQUIRED`.
- **Handoff decision**: `FULL_TRUST`, `DEGRADED_ALLOWED`, `DEGRADED_REQUIRES_EXPLICIT_ALLOW`, `TRUST_FAIL`, `SCAN_INCOMPLETE`, `SUSPICIOUS_FINDINGS_PRESENT`, `UNEXPECTED_ISOLATION_COUNT`.
- **VM compatibility**: `PROFILE_ADAPTER_MISMATCH`, `SNAPSHOT_PROFILE_HASH_MISMATCH`, `SNAPSHOT_STATE_NOT_ALLOWED`, `SNAPSHOT_REQUIRED`, `SNAPSHOT_CONTENT_NOT_VERIFIED`, `GUEST_MEASUREMENT_UNAVAILABLE`, `HYPERV_UNAVAILABLE`, `WINDOWS_SANDBOX_UNAVAILABLE`, and related deny/defer codes.

---

## 7. Security invariants (constitutional)

I1 verification must not mutate the object · I2 `FAIL` never yields `NORMAL` · I3 `DEGRADED` never silently becomes `FULL` · I4 isolation preserves recoverability · I5 never silently delete evidence · I6 every security decision has a reason code · I7 unique protected-display session identity · I8 replay refers to the exact session · I9 optional integrations never become correctness dependencies · I10 no private signing keys in the repo · I11 Clarity exits after handoff · I12 never claim stronger trust than measured. Observed status in `CURRENT_STATE.md` §5 (I4 partial pending restore; all others hold).

---

## 8. Threat model (summary)

Clarity assumes possible compromise of the installed OS, system binaries, startup configuration, user-space security tooling, executables, bootloader, drivers, local filesystem, and external media. Higher-assurance versions must additionally consider firmware compromise, malicious option ROMs, bootkits/rootkits, TPM spoofing, DMA attacks, malicious hypervisors, and peripheral-firmware attacks. Clarity's strength is making trust assumptions **explicit** rather than pretending they are absent. Every failure MUST fail explicitly, emit a stable reason code, produce evidence where possible, and never silently continue. Full detail: `HOST_VALIDATOR_THREAT_MODEL.md`, `VM_PROFILE_SNAPSHOT_THREAT_MODEL.md`, `PROTECTED_DISPLAY_THREAT_MODEL.md`.

---

## 9. Cryptographic identity

Development signing uses Ed25519 via OpenSSH tooling with an allowed-signers trust file. The originally committed dev key is **permanently compromised**, was rotated (`clarity_dev_ed25519_rotated_20260308`), and public history was rewritten to remove it. Rule (I10): **no Clarity private signing key ever lives in the repository.** Production identity must move to TPM-protected/hardware-backed/Secure-Boot signing infrastructure. Validator-run manifests are not yet signed; sealing them is required for A2+ (WBS 9.1).

---

## 10. Ecosystem posture

Clarity is **standalone-first** (`LAW.md`). It may integrate but never depends: NFL is an optional witness-copy destination; NeverLost a future signer/principal source; Watchtower a possible downstream consumer of validation receipts; TRIAD a possible evidence preserver; Covenant a possible signed-policy supplier. Integrations use explicit versioned schemas/receipts and must not become local correctness requirements (I9). The ecosystem service role is currently `unclassified` and must be classified via a `docs/proposals` change (see `ECOSYSTEM_INTEGRATION.md`).

---

## 11. Target end-state architecture

The strongest end-state is **not** a large scanner inside firmware. It is a small trusted UEFI launcher that verifies the Clarity validator image, launches a protected second-stage validator environment that performs scan/isolate/review, seals the decision, and hands off — keeping the firmware TCB small. The PowerShell reference implementation is the **executable behavioral specification** that firmware/native code must reproduce without changing the meaning of any receipt, finding, isolation record, or handoff decision.

After a successful handoff, in every mode: **Clarity exits.**
