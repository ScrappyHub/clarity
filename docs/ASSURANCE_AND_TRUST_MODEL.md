# Clarity Assurance and Trust Model

## Purpose

Clarity is a pre-OS validation and controlled-review system. Its job is to establish bounded confidence in a platform and its next execution handoff, then refuse handoff when required evidence is absent, inconsistent, or unverifiable.

Clarity must not claim that virtualization alone authenticates hardware. A VM or protected display can isolate execution and preserve evidence, but the authority for hardware identity comes from firmware, measured boot, TPM/TEE evidence, platform policy, and—where available—independent provenance.

## Trust boundary

The intended trust order is:

1. Hardware roots and platform measurements.
2. UEFI/Secure Boot and the measured Clarity loader.
3. Clarity runtime and its signed policy/configuration.
4. Hypervisor and isolated review guest.
5. Protected display and operator interaction.
6. Normal operating system and application environment.

The lower layers must not accept claims from a higher layer without an authenticated measurement or receipt. The Windows Sandbox and Hyper-V adapters in this repository are development surfaces; they are not authoritative trust sources.

## Assurance levels

- `A0_UNAVAILABLE`: required evidence cannot be collected. Handoff is denied.
- `A1_HOST_OBSERVED`: the host reports capabilities and produces a complete local evidence chain. Useful for diagnostics only.
- `A2_ISOLATED_REVIEW`: the review path is isolated through a hypervisor or equivalent protected surface, and the session is replayable.
- `A3_MEASURED_PLATFORM`: firmware, loader, policy, and runtime measurements are verified against an approved baseline.
- `A4_ATTESTED_PLATFORM`: A3 plus TPM/TEE-backed attestation and validated key provenance.

The current PowerShell implementation can target A1 and part of A2. It must report that limitation rather than silently implying A3 or A4.

## Decision rules

- Missing evidence is not equivalent to a clean result.
- Conflicting evidence produces `DEGRADED` or `FAIL`, according to policy.
- `FAIL` never permits normal handoff.
- `DEGRADED` requires an explicit policy decision and must produce a restricted decision.
- Every decision references the exact preflight, scan, isolation, adapter, and replay artifacts used to reach it.

## Future implementation seams

Firmware, hypervisor, protected-display, and VM implementations should emit the same versioned evidence contracts used by the host prototype. Replacing an adapter must not change the meaning of session receipts, findings, isolation records, or handoff decisions.
