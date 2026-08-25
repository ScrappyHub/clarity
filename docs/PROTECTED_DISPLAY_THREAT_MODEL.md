# Protected Display Threat Model

## Scope

This model covers Clarity display sessions, append-only receipts, Windows Sandbox request artifacts, Hyper-V request artifacts, and replay output. The adapters are host-side development surfaces. They do not authenticate the host, firmware, or hardware.

## Assets and invariants

- Session identity and content reference must remain bound together.
- Every receipt must be self-hash-valid and linked to the previous receipt.
- A session must open before adapter activity and close exactly once.
- Replay must refuse incomplete, reordered, cross-session, cross-adapter, or tampered receipt history.
- Adapter requests must be bound to the session and content reference.
- Adapter request materialization is evidence of a request, not evidence that a VM or hypervisor actually launched safely.

## Threats and controls

| Threat | Control | Failure behavior |
|---|---|---|
| Receipt content altered | Receipt hash verification | Replay fails closed |
| Receipt removed or reordered | Previous-hash chain | Replay fails closed |
| Receipt copied from another session | Session and adapter binding | Replay fails closed |
| Session closed twice | Explicit state transition check | Close operation fails |
| Adapter request points at another session | Adapter/session identity check | Adapter operation fails |
| Adapter request content changed | Request hash recorded in receipt detail | Evidence is non-authoritative; later verifier must reject mismatch |
| Hyper-V/Sandbox unavailable | Capability recorded separately from request | Request may be materialized, but no launch trust is claimed |
| Host OS fabricates all evidence | Host implementation capped at A1/A2 development confidence | No A3/A4 hardware claim is permitted |

## Out of scope for this host slice

- Secure Boot enforcement
- TPM quote verification
- firmware measurement authority
- hypervisor-rooted protected display
- independent hardware identity
- safety or mission certification

Those require firmware, platform keys, measured boot, and independent validation outside these PowerShell adapters.
