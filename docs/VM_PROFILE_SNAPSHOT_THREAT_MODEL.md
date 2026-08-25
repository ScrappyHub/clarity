# VM Profile and Snapshot Threat Model

## Scope

This model covers Clarity VM profiles, Hyper-V and Windows Sandbox request artifacts, snapshot manifests, and compatibility decisions. It does not claim that a profile manifest provisions a VM or that a snapshot manifest proves checkpoint contents.

## Required properties

- Every VM request names one versioned profile.
- The profile hash is bound to the request and validation report.
- Guest image identity, resource limits, isolation settings, and snapshot policy are explicit.
- A snapshot must bind to the exact profile hash and configuration hash.
- Only allowed snapshot states may be restored.
- `manifest_only` evidence is deferred, never compatible.
- An unavailable hypervisor or guest capability is explicit, never silently treated as available.

## Threats and controls

| Threat | Control | Failure behavior |
|---|---|---|
| VM launched with the wrong resource/isolation profile | Versioned profile hash and request binding | Request denied |
| Snapshot from another profile restored | Snapshot profile-hash comparison | Snapshot denied |
| Snapshot configuration changed after creation | Configuration-hash comparison | Snapshot denied |
| Running or unknown checkpoint restored | Allowed-state policy | Snapshot denied |
| Snapshot manifest substituted for checkpoint proof | `verification_scope` is explicit | `manifest_only` remains deferred |
| Host lacks Hyper-V/Sandbox | Capability detection is recorded | Request deferred/unavailable |
| Guest image is a placeholder or not measured | Image and measurement policy are explicit | No A3/A4 claim; request deferred |
| Profile path or validation report altered | Content hashes and report binding | Request denied or replay fails |

## Assurance boundary

This host-side capability can establish profile compatibility and provenance of locally produced request artifacts. It cannot establish that the hypervisor, firmware, guest image, virtual disk, or hardware is trustworthy. A production implementation must add signed profile policy, measured boot, guest image signatures, checkpoint content verification, and an attested hypervisor/TPM boundary.
