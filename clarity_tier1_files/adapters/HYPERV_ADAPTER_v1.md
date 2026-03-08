# Clarity Hyper-V Adapter v1

## Goal
Provide the second guarded launch adapter using a disposable Hyper-V guest profile.

## Why second
Windows Sandbox is the faster first adapter.
Hyper-V comes after session contracts, receipts, and replay are already stable.

## Inputs
- session.json
- launch_manifest.json
- target evidence directory
- launch policy
- environment profile id

## Adapter responsibilities
- resolve guest profile
- mount evidence read-only by default
- boot isolated guest
- optionally disable networking
- capture guest identity
- emit start/end receipts

## Required metadata
- hyperv_vm_name or generated disposable id
- generation type
- vhd or template id
- network mode
- mapped drives
- guest startup hash or config ref

## Safety law
The adapter must be disposable and evidence-preserving.
The target must not be opened directly on the host as the primary path.
