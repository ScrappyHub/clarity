# Host Validator Threat Model

## Scope

This model covers preflight, targeted scanning, findings, isolation, run composition, artifact verification, and handoff decisions in the Windows host prototype.

## Security properties

- An incomplete scan is never equivalent to a clean scan.
- A suspicious finding cannot produce an allowed handoff.
- Isolation only accepts findings whose paths are inside the scan-declared roots.
- Evidence artifacts are hash-bound to the run manifest.
- Cross-phase IDs and decisions must agree before verification succeeds.
- Host-side evidence is capped at the documented assurance level and cannot claim firmware or hardware attestation.
- A present or ready TPM is only an observed capability until a signed quote and policy validation are implemented.

## Threats and controls

| Threat | Control | Failure behavior |
|---|---|---|
| Access-denied files are silently skipped | Scan records errors and `scan_complete=false` | Handoff denied |
| Finding path injection | Isolation checks every finding against declared scan roots | Isolation fails |
| Finding source changes between scan and copy | Isolation hashes and verifies source/copy lineage | Isolation fails |
| Scan or isolation artifact altered | Run manifest hashes and verifier | Verification fails |
| Run decision forged | Verifier recomputes phase semantics and decision consistency | Verification fails |
| Suspicious content quarantined but still treated clean | Handoff consumes suspicious and isolation counts | Handoff denied |
| Host fabricates platform evidence | Assurance level remains A1/A2 development confidence | No A3/A4 claim permitted |

## Out of scope

This host slice does not establish a trusted computing base below the host OS. Firmware, Secure Boot, TPM/TEE quotes, hypervisor integrity, hardware identity, and supply-chain provenance remain required for A3/A4 deployment.
