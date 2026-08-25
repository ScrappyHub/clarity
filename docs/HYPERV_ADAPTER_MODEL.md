# Hyper-V Adapter Model

This document defines the Clarity Hyper-V protected display adapter lane.

## Purpose

The Hyper-V adapter is the second protected-display adapter after Windows Sandbox.

It exists to let Clarity request a stronger isolated review path while preserving the same validator-session model:

- open a protected display session
- materialize an adapter request
- emit adapter receipts
- keep replay and session lineage deterministic
- close the session
- review the replay outputs

## Current scope

This adapter materializes deterministic request artifacts and receipts after
validating a versioned VM profile and optional snapshot manifest. It does not
yet provision a full VM or restore a checkpoint automatically.

The request is not launch authorization. Its compatibility state is explicit:

- `compatible` = profile and supplied snapshot satisfy the local checks;
- `deferred` = the request is structurally valid, but host capability,
  guest measurement, or snapshot content evidence is unavailable;
- `deny` = profile/snapshot policy is violated.

The adapter must never convert `deferred` into a successful launch claim.

## Artifact path

Runtime artifacts are written under:

- display/adapters/hyperv/requests/<session_id>/

The adapter writes:

- request.json
- launch.cmd

The request binds:

- profile ID, version, and SHA-256 profile hash;
- configuration hash;
- compatibility report path and hash;
- snapshot ID, hash, and status where supplied;
- the session and content reference.

## Canonical direction

The Hyper-V lane is intended to support:

- stronger isolation than the Windows Sandbox lane
- explicit session-bound launch requests
- later integration with curated guest images / review shells
- profile-bound checkpoint restore with content verification
- deterministic replay and receipt continuity

## Status

This is a host-side profile/request adapter, not the final firmware-grade or
hypervisor-grade product endpoint. Hyper-V availability, guest image
measurement, checkpoint content, and hardware trust remain separately
unverified until an attested authority layer exists.
