# Clarity Protected Display Model (Tier1 Step2)

Purpose
- Provide a small, boring, deterministic protected display session model for Clarity.
- Display sessions are content-addressed by session_id, receipted, and replayable.
- Windows Sandbox is the first adapter. Hyper-V comes later.

Rules
- Clarity remains standalone. Adapters are optional execution surfaces, never truth sources.
- Opening a display session creates a session object and an append-only receipt.
- Closing a display session creates a close receipt and updates session state.
- Adapter requests are receipted.
- No adapter is authoritative. Session ledger + receipts remain authoritative.

Runtime layout
- C:\ProgramData\Clarity\display\sessions\<session_id>\session.json
- C:\ProgramData\Clarity\display\receipts\display_receipts.ndjson
- C:\ProgramData\Clarity\display\adapters\windows_sandbox\requests\<session_id>\request.json
- C:\ProgramData\Clarity\display\adapters\windows_sandbox\requests\<session_id>\clarity_display.wsb

Phase status
- Tier1 Step2 = protected display model + Windows Sandbox adapter request path
- Hyper-V adapter = next phase
- Replay view = separate next task after this fileset is in place
