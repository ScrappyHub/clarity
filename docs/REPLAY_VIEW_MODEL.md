# Clarity Replay View Model (Tier1 Step3)

Purpose
- Replay a protected display session deterministically from session.json and append-only receipts.
- Replay view is read-only and does not mutate session or receipt history.

Rules
- Replay reads from C:\ProgramData\Clarity\display\sessions and display\receipts.
- Replay emits a deterministic JSON report.
- Replay output is evidence, not authority.

Outputs
- reports\display_replay\<session_id>.replay.json
- reports\display_replay\<session_id>.timeline.txt
