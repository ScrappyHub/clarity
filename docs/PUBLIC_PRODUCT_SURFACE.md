# Clarity Public Product Surface

This file defines the intended public-facing repository surface for Clarity.

## Canonical public surface

The public repo should emphasize these top-level areas:

- README.md
- LAW.md
- contracts/
- docs/
- schemas/
- scripts/

## Public script surface

The intended public script surface is centered on:

- scripts/_bootstrap_clarity_standalone_v1.ps1
- scripts/make_packet.ps1
- scripts/verify_packet.ps1
- scripts/pledge_local.ps1
- scripts/duplicate_to_nfl.ps1
- scripts/library_put.ps1
- scripts/library_get.ps1
- scripts/display_session_open.ps1
- scripts/display_session_close.ps1
- scripts/display_adapter_windows_sandbox.ps1
- scripts/display_replay_view.ps1
- scripts/validator_preflight.ps1
- scripts/validator_scan_targeted.ps1
- scripts/validator_isolate_copy.ps1
- scripts/validator_handoff_gate.ps1
- scripts/validator_run.ps1
- scripts/validator_verify_run.ps1
- scripts/test_validator_host_slice.ps1
- scripts/test_preflight_assurance_cap.ps1
- scripts/test_protected_display.ps1
- scripts/display_adapter_hyperv.ps1
- scripts/vm_profile_validate.ps1
- scripts/test_vm_profile_snapshot.ps1
- vm_profiles/
- scripts/_RUN_clarity_tier0_step2_v1.ps1
- scripts/_RUN_clarity_tier0_step3_v1.ps1
- scripts/_RUN_clarity_tier1_step2_v1.ps1
- scripts/_RUN_clarity_tier1_step3_v1.ps1
- scripts/_RUN_clarity_tier1_step4_v1.ps1

## Non-public / non-product debris

The following classes should not remain tracked in the public surface:

- scratch repair scripts
- one-off patchers
- restore helpers used only during rescue
- backup artifacts
- corrupt snapshots
- broken snapshots
- local reports
- local archive debris
- leaked or rotated key artifacts
- duplicate design-drop folders that are already represented canonically elsewhere

## Canonical design direction

Clarity remains a standalone validator system for pre-OS or protected trust handoff.

Its canonical direction is:

1. preflight and identity
2. handoff / boot verification
3. targeted integrity scan
4. isolation / quarantine
5. evidence artifact and controlled handoff

The host-side implementation is an adapter and evidence prototype for the
future firmware/measured-boot authority layer. It must report its assurance
level explicitly and must not treat Windows Sandbox or Hyper-V as hardware
authentication sources.

Protected display, replay, Windows Sandbox, and later Hyper-V remain part of the validator shell path and not a separate product.
