# Clarity Protected Display Model (Tier1 Step2)

Purpose
- Provide a small, boring, deterministic protected display session model for Clarity.
- Display sessions are content-addressed by session_id, receipted, and replayable.
- Windows Sandbox and Hyper-V are host-side adapter surfaces with the same session and receipt model.

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
- vm_profiles\<profile>.v1.json

Phase status
- Tier1 protected display = session model, chained receipts, adapter request binding, and replay verification
- Windows Sandbox = request/optional launch adapter
- Hyper-V = deterministic request adapter; VM provisioning remains a future authority-layer implementation
- VM profiles and snapshot manifests are validated before request creation; manifest-only snapshots remain deferred.
