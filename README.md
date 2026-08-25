# Clarity

Clarity is a standalone pre-OS validator and protected review instrument.

It is designed to verify a target boot/handoff path before normal execution, isolate suspicious artifacts into a controlled vault, emit deterministic evidence, and then exit. Clarity is not a resident tracker or long-running surveillance agent. It is a validator system.

## What Clarity is

Clarity exists to provide a small, deterministic validator workflow that can operate in two canonical delivery modes:

1. firmware-integrated / preinstalled validator mode
2. external boot-media validator mode

Both modes are intended to produce materially identical evidence artifacts so results can be audited and compared.

## Canonical intent

Clarity is for safeguarded validation before trust handoff.

Its purpose is to:

- establish validator identity and trust tier
- verify the next handoff target before boot/launch
- scan targeted high-signal areas instead of acting like a general consumer antivirus
- isolate suspicious material into a controlled vault
- produce sealed, human-readable evidence artifacts
- hand off only according to explicit trust policy
- exit when done

Clarity is a validator-as-validator, not a telemetry platform.

## Current implemented direction

The repo is currently proving the validator substrate in deterministic PowerShell workflows:

- standalone bootstrap/runtime
- Option A packet build and verify
- local pledge append
- optional NFL duplication
- library put/get with append-only ledger
- protected display session open/close
- Windows Sandbox adapter request generation
- Hyper-V adapter request generation
- VM profile and snapshot compatibility validation
- replay view generation
- validator preflight
- validator handoff gate
- composed validator run with artifact verification

## Current trust model

Clarity currently uses a simple trust tier model:

- FULL
- DEGRADED
- FAIL

The handoff gate currently maps these to:

- FULL -> normal
- DEGRADED -> restricted (only when explicitly allowed)
- FAIL -> deny

## Why Clarity is needed

Clarity exists because normal boot and execution paths are often trusted too early.

A validator should be able to:

- inspect before handoff
- fail closed when trust is broken
- preserve evidence
- isolate suspicious material safely
- avoid becoming a permanent background collector

This makes Clarity useful for security-sensitive environments where deterministic review, quarantine discipline, and sealed evidence matter.

## Canonical v1 validator shape

The intended validator flow remains:

1. preflight and identity
2. boot / handoff verification
3. targeted integrity scan
4. isolation / quarantine vault
5. evidence artifact + controlled handoff

## Repository status

Clarity is under active buildout.

The current repo proves the deterministic validator substrate and protected display workflow, but it is not yet the final firmware-grade validator product surface.

The next implementation track is centered on making the validator shell real:

- validator preflight and handoff gate
- session schema and event registry
- session ledger and receipts
- protected display model
- Windows Sandbox and Hyper-V adapter request paths
- chained receipt and replay verification
- profile-bound adapter requests and snapshot policy checks
- eventual firmware / pre-OS alignment with the original validator design

The current host-side vertical slice is exercised by
`scripts/test_validator_host_slice.ps1`. It covers clean and suspicious
target paths, content-addressed isolation, fail-closed handoff, artifact
hash verification, and tamper rejection. Its assurance level is explicitly
`A1_HOST_OBSERVED`; it is not a substitute for firmware or measured-boot
attestation.

## Design constraints

Clarity follows these principles:

- deterministic UTF-8 no BOM + LF file emission
- parse-gated PowerShell workflows
- append-only receipts and ledgers where applicable
- no silent mutation during verification
- validator stays separate from later OS/runtime concerns
- optional integrations must not become correctness dependencies

## Long-term form factor

The intended long-term form factor is a legitimate validator system that can live:

- in firmware / BIOS-adjacent launch flow
- in a protected boot chain
- on external validator media
- behind protected display / sandbox / hypervisor-backed review paths

## Status note

Today’s repo is the build substrate for that validator system. The direction remains aligned with the original Clarity design.

## License

TBD
