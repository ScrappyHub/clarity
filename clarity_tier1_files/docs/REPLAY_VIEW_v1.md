# Clarity Replay View v1

## Purpose
Replay reconstructs what happened without mutating anything.

## Inputs
- session object
- session receipts
- target packet
- target content ref
- environment metadata
- optional logs

## Required replay blocks
- identity summary
- verification summary
- policy summary
- receipt timeline
- environment summary
- final outcome

## Deterministic replay claims
Clarity may always support evidence replay.

Clarity may claim deterministic replay only when:
- inputs are pinned
- environment is pinned
- adapter version is pinned
- all referenced artifacts are present

## Output law
Replay is derived.
Replay is never the authoritative source of truth.
The authoritative source is the session ledger plus receipts.
