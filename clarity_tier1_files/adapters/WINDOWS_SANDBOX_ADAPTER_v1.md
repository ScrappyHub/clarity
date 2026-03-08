# Clarity Windows Sandbox Adapter v1

## Goal
Provide the first guarded launch adapter using Windows Sandbox.

## Inputs
- `session.json`
- `launch_manifest.json`
- target content bytes or mounted evidence directory
- launch mode

## Launch modes
- `sandbox_no_network`
- `sandbox_limited_network`

## Adapter responsibilities
- create a disposable launch manifest
- map only the required evidence/input directory
- default to read-only mapping
- disable networking unless explicitly allowed by policy
- emit start receipt
- emit end receipt

## Minimum launch manifest fields
- session_id
- target_content_ref
- target_packet_id
- launch_mode
- mapped_host_path
- mapped_guest_path
- network_enabled
- writable_mapping
- created_at_utc

## Required evidence
- exact sandbox config used
- stdout/stderr if applicable
- environment identity
- exit code
- session end receipt

## Safety law
The adapter is a launch tool, not an interpretation engine.
