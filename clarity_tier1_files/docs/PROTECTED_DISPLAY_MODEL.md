# Clarity Protected Display Model v1

## Purpose
The protected display shell is the operator-facing read-only inspection surface.

It must not auto-open content in the host context.

## Required panes

### 1. Identity pane
Shows:
- packet id
- content ref
- object sha256
- session id
- environment id

### 2. Verification pane
Shows:
- verified / not verified
- signature status
- hash status
- manifest status
- receipt chain status

### 3. Policy pane
Shows:
- policy decision
- allow / deny / inspect-only / release / archive / destroy
- reason tokens

### 4. Quarantine pane
Shows:
- current state
- allowed transitions
- latest session event

### 5. Replay pane
Shows:
- timeline of receipts
- launch target
- environment used
- operator actions

## Interaction law
Default controls:
- Inspect metadata
- Replay session
- Launch in sandbox
- Launch in Hyper-V
- Release only if policy allows
- Destroy only if policy allows

Forbidden defaults:
- double-click opens host app
- implicit release
- hidden network enablement
- hidden writes back to source
