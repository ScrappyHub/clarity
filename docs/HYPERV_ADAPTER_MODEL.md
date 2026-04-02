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

This adapter currently materializes deterministic request artifacts and receipts.
It does not yet provision a full VM automatically.

## Artifact path

Runtime artifacts are written under:

- display/adapters/hyperv/requests/<session_id>/

The adapter writes:

- request.json
- launch.cmd

## Canonical direction

The Hyper-V lane is intended to support:

- stronger isolation than the Windows Sandbox lane
- explicit session-bound launch requests
- later integration with curated guest images / review shells
- deterministic replay and receipt continuity

## Status

This is the Tier-1 adapter scaffold, not the final firmware-grade or hypervisor-grade product endpoint.
