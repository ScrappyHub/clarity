# Clarity — Definition of Done

DoD version: 2.0 (audited)
Date: 2026-08-20
A tier is "done" only when **every** criterion is met by a fresh, deterministic checkout — not by a happy path alone. Each security-relevant criterion pairs with an intentional **negative** proof. Status reflects the audited working tree (`CURRENT_STATE.md`).

---

## Cross-cutting DoD (applies to every tier)

A change is not done unless:

1. Product files are UTF-8-no-BOM + LF and pass `Parser::ParseFile`.
2. It runs in a fresh `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File`.
3. Every security-significant decision emits a **stable reason code** (no prose parsing).
4. Every failure fails **explicitly**, produces evidence where possible, and never silently continues.
5. A matching **negative test** exists (the failure path is proven, not assumed).
6. No private signing key is added to the repository (Invariant I10).
7. The component **reports its assurance level** and never implies a higher one.
8. The work is **committed and versioned** (the current uncommitted state does not satisfy this).

---

## Tier-0 — Deterministic evidence substrate — **DONE**

A clean standalone checkout can deterministically: bootstrap; create runtime paths; generate/load approved identity; build a packet; verify it **without mutation**; append a pledge; write evidence; optionally duplicate to NFL; put/get content-addressed objects; and emit deterministic pass/fail markers.
Proof: `CLARITY_TIER0_STEP2_OK`, `CLARITY_TIER0_STEP3_OK`. **Status: met.**

---

## Tier-1 — Hosted validator shell — **~90%, NEARLY DONE** (updated 2026-08-27)

Required and their status:

| Criterion | Status |
|---|---|
| Protected-display sessions + append-only receipts + replay | DONE |
| Windows Sandbox adapter (request level) | DONE |
| Hyper-V adapter abstraction (request level) | DONE |
| VM profile / snapshot compatibility engine + negative tests | DONE |
| Validator preflight + trust-tier + assurance cap | DONE |
| Handoff gate (fail-closed) | DONE |
| Composed validator run + artifact-hash verifier + tamper test | DONE |
| Scanner consumes `clarity_rules.json` + baseline + full taxonomy | **DONE (Step 6, 2026-08-27)** |
| Isolation vault: copy/CAS/chained-ledger/safety-gates | DONE |
| Isolation restore + execution-block + critical-file safety gate | **DONE (Step 7, 2026-08-27)** |
| Sealed (signed) validator-run bundle | **DONE (Step 9.1, 2026-08-27)** |
| Negative tests: changed-hash, missing-critical, corrupt-vault-object, unauthorized-restore, wrong-signature | **DONE** |
| Final human-readable validator summary screen | NOT DONE (Step 10) |
| Per-file signature/signer validation in scanner | NOT DONE |

Tier-1's three former blockers (scanner depth, isolation restore/exec-block, run signing) are now closed and proven (`SCANNER_BASELINE_TEST_OK`, `CLARITY_TIER1_STEP7_OK`, `CLARITY_TIER1_STEP7B_OK`, `CLARITY_TIER1_STEP9_OK`). The remaining Tier-1 gap is the **protected result screen (Step 10)** and per-file signature validation. Real boot-target verification (Step 8) belongs to Tier-2.

---

## Tier-2 — Real host validator — **NOT STARTED (~10%)**

Done when Clarity, on a real host: identifies the actual boot target; validates actual boot-critical artifacts; supports a real baseline; performs real digital-signature validation; inspects Secure Boot; incorporates TPM/measured-boot evidence where supported; runs a real targeted host scan; performs real isolation; supports a controlled restricted handoff; produces a reproducible evidence run; and passes malicious/mutated test vectors.
**Until then, Clarity is a hosted validator implementation, not a proven pre-OS security validator.** No `A3`/`A4` claim is permitted.

---

## Tier-3 — Bootable external validator (Mode B) — **NOT STARTED (<10%)**

Done when there is: bootable media; an independent validator runtime; read-only host inspection; no dependence on the installed OS; a signed validator image; a deterministic scanner; isolation; evidence export; and a handoff-or-halt decision that emits the same schemas/reason codes as the hosted shell.

---

## Tier-4 — Firmware-grade Clarity — **NOT STARTED (<10%)** — long-term target

Done only with proof of: **secure launch** (executes from a trusted pre-OS chain); **immutable identity** (build identity cannot silently change); **secure update** (only authorized validator images load); **hardware-backed trust** (Secure Boot / TPM / measured boot / protected keys where the platform permits); **boot-target validation** (the next stage is actually verified); **fail-closed** (a critical violation prevents ordinary boot); **isolation** (preserve + restrict, never silent deletion); **evidence** (every decision is cryptographically verifiable); **external recovery** (a USB validator produces compatible evidence); **independence** (no reliance on a potentially compromised host OS); and **non-residency** (after handoff, Clarity exits).
Regulated/defense certification is a separate, additional program (threat analysis, supply-chain review, secure-development controls, external certification) and MUST NOT be claimed before it exists.

---

## Assurance-level exit criteria

| Level | Reached when |
|---|---|
| `A1_HOST_OBSERVED` | Host reports capabilities + complete deterministic local evidence chain. **Reached today.** |
| `A2_ISOLATED_REVIEW` | Review path isolated through a live hypervisor/protected surface **and** the session is replayable **and** the run bundle is signed (signed-bundle criterion met 2026-08-27, Step 9.1; live-hypervisor + replay-of-live-session still pending). |
| `A3_MEASURED_PLATFORM` | Firmware, loader, policy, and runtime measurements verified against an approved baseline. |
| `A4_ATTESTED_PLATFORM` | A3 + TPM/TEE-backed attestation and validated key provenance. |

Missing evidence is never equivalent to a clean result; conflicting evidence yields `DEGRADED` or `FAIL`; `FAIL` never permits normal handoff; `DEGRADED` requires an explicit decision and yields a restricted result; every decision references the exact artifacts used to reach it.
