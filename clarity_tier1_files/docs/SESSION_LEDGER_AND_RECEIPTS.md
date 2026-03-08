# Clarity Session Ledger and Receipts v1

## Purpose
This file defines the append-only session ledger and receipt discipline for Clarity Tier-1.

## Core law
Every protected inspection or launch action must emit a session object and one or more append-only receipts.

Clarity records:
- what was targeted
- how it was verified
- what policy decided
- whether launch was blocked or allowed
- where it ran
- what happened when it ended

## Filesystem shape
Recommended runtime paths:

- `C:\ProgramData\Clarity\sessions\ledger\sessions.ndjson`
- `C:\ProgramData\Clarity\sessions\receipts\session_receipts.ndjson`
- `C:\ProgramData\Clarity\sessions\objects\<session_id>\session.json`
- `C:\ProgramData\Clarity\sessions\objects\<session_id>\launch_manifest.json`
- `C:\ProgramData\Clarity\sessions\objects\<session_id>\environment.json`
- `C:\ProgramData\Clarity\sessions\objects\<session_id>\stdout.log`
- `C:\ProgramData\Clarity\sessions\objects\<session_id>\stderr.log`

## Ledger rules
`sessions.ndjson` is append-only.

Each line is canonical JSON for `clarity.session.v1`.

Each line should carry or derive:
- `prev_links[]`
- `session_id`
- `session_state`
- `verification_state`
- `policy_decision`

## Receipt rules
`session_receipts.ndjson` is append-only.

Each receipt must include:
- `prev_receipt_hash`
- `receipt_hash`
- `session_id`
- `event_type`
- `ok`

## Receipt hash rule
`receipt_hash = SHA-256(canonical_bytes(receipt_without_receipt_hash))`

## Minimum receipt sequence
A normal allowed sandbox inspection should emit:
1. `session_created`
2. `launch_requested`
3. `session_started`
4. `session_ended`

A blocked launch should emit:
1. `session_created`
2. `launch_requested`
3. `launch_blocked`

## Non-goals
The session ledger is not a UI database.
It is the authoritative replayable evidence log.
