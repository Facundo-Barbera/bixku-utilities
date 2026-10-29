# Mode agent (`packages/BixkuModeAgent`)

The mode agent lets the user say things like *"chat should only be summarized while I
write"* or *"add a mode for reading papers"*, and turns them into concrete, reviewable
changes to Dock modes. It is a portable SwiftPM package (Foundation only) that builds
and tests on Linux and macOS.

## Pieces

| Type | Role |
| --- | --- |
| `AgentLLM` / `LLMClientAgentLLM` | Minimal "messages in, text out" interface; the adapter runs it on any BixkuLLM `LLMClient`. |
| `ModeAgentPrompt` | Versioned system prompt (`mode-agent/1`) and the JSON reply contract. |
| `AgentTool` | The typed tools: `list_modes`, `get_mode`, `propose_mode_change`, `create_mode`, `delete_mode`, `set_active_mode`, `summarize_recent_activity`, `list_held_notifications`, `release_notification`. |
| `ModeAgent` (actor) | The bounded tool-calling loop. |
| `ProposalCoordinator` (actor) | Validates actions, builds `ModeChangeProposal`s, applies, approves/rejects, reverts. |
| `ApprovalPolicy` | Rates risk and decides what may skip the user. |
| `ModeDiff` | Field-level, human-readable diff of two mode documents. |
| `ModeHistory` (actor) | Versioned log of applied catalog changes (persisted in module storage). |
| `ModeAgentDockAccess` | Seam to the running Dock engine (active mode, activity, held notifications). |
| `AgentModule` | The `BixkuModule` (`online.bixku.mode-agent`); publishes `agent.proposal` and `agent.applied`. |

## Flow

```mermaid
sequenceDiagram
    actor User
    participant Agent as ModeAgent
    participant LLM as LLMClient
    participant Coord as ProposalCoordinator
    participant Policy as ApprovalPolicy
    participant Store as ModeStore
    participant Bus as EventBus

    User->>Agent: run("summarize chat while writing")
    loop until "finish" (max 12 steps)
        Agent->>LLM: system prompt + transcript
        LLM-->>Agent: {"action":"call_tool","tool":"get_mode",...}
        Agent->>Store: load()
        Agent-->>LLM: tool result (untrusted text fenced)
    end
    Agent->>Coord: submit(.update(before, after), justification)
    Coord->>Coord: validate with ModeValidator
    Coord->>Policy: assess + decide
    Coord->>Bus: agent.proposal
    alt low risk and auto-approve enabled
        Coord->>Store: save(after)
        Coord->>Bus: agent.applied
    else needs confirmation
        User->>Coord: approve(id) / reject(id)
        Coord->>Store: save(after) (re-validated, stale check)
        Coord->>Bus: agent.applied
    end
    User->>Coord: revert(version) / revertProposal(id)
```

### Reply contract

Every model reply is one JSON object:

```json
{"action": "call_tool", "tool": "get_mode", "arguments": {"id": "writing"}}
{"action": "finish", "message": "I proposed summarizing chat while writing."}
```

The agent uses this contract instead of provider-native tool calling so the same loop
works on every provider. Code fences around the object are tolerated; malformed
replies are reported back to the model (twice at most) before the run fails.

## Proposals and approval

Mutating tools never change anything directly: they create a `ModeChangeProposal`
with the action, the agent's justification (shown verbatim, never used to decide), a
diff such as `~ notifications.rules[1].action: "hold" → "summarize"`, a risk level
and the reasons for it.

`ApprovalPolicy`:

- **`confirm-all`** (default): every proposal waits for the user.
- **`auto-approve-low-risk`**: low-risk proposals apply immediately. Low risk means
  presentation changes (name, symbol, description, dock order), *adding* focus,
  urgency or always-allow criteria, switching the active mode, or releasing a held
  notification.
- **Never auto-approved**: deleting a mode; anything that newly holds, summarizes or
  silences a critical category (default: `direct-message`, `calendar`); new
  `silence` rules or a `silence` default; removing urgent keywords or categories,
  ignoring time-sensitive flags, or narrowing always-allow; creating modes (medium
  risk); and every proposal made after the run read untrusted data.

Configure it in `config.local.toml`:

```toml
[modules.mode-agent]
approval = "confirm-all"   # or "auto-approve-low-risk"
```

Approving reloads the catalog, re-validates, and checks that the mode still equals
the version the proposal was computed against; otherwise the proposal fails as stale.

## History and revert

Each applied create/update/delete is recorded in `ModeHistory` with a monotonically
increasing version, the before/after definitions and the provenance. `revert(version)`
restores the previous state (removing the user document when the "before" was the
built-in mode or did not exist) and is itself recorded, so a revert can be reverted.
Reverting a version whose result has changed since fails as stale.
`revertProposal(id)` does the same for the entry produced by a proposal.

## Threat model

```mermaid
flowchart LR
    U[User request<br/>trusted] --> A[ModeAgent]
    N[Notification text<br/>UNTRUSTED] -->|fenced, sanitized| A
    W[Window titles, app names<br/>UNTRUSTED] -->|fenced, sanitized| A
    A -->|proposal only| C[ProposalCoordinator]
    C -->|validator + policy| D{risk / taint}
    D -->|low, untainted, opt-in| S[(ModeStore)]
    D -->|otherwise| H[User confirmation] --> S
```

**Assets**: the user's mode catalog, the delivery of important notifications, and the
active mode.

**Adversary**: anyone who can make text appear on the user's screen or in a
notification (a chat message, an email subject, a web page title) and wants the agent
to delete modes, silence notifications or switch modes.

**Defenses**

1. *Fencing*: notification titles and bodies, app names and window titles are
   truncated, stripped of control and format characters, have `<`/`>` replaced by
   `‹`/`›` (so they cannot close or forge the fence), and are wrapped in
   `<untrusted_data>…</untrusted_data>`. The system prompt says fenced text is data,
   never instructions.
2. *Taint tracking*: once a run calls `summarize_recent_activity` or
   `list_held_notifications`, every later proposal in that run is marked
   `influencedByUntrustedData` and always needs confirmation, even if the model is
   fully fooled.
3. *Proposal-only authority*: the model cannot write, only propose. Risky classes of
   change are never auto-approved, and built-in modes cannot be deleted.
4. *Strict tools*: arguments decode into typed structs; unknown tools, invalid modes
   (`ModeValidator`) and unknown ids are rejected and reported back; the loop is
   bounded (12 steps, 2 consecutive malformed replies).
5. *Reversibility*: every catalog change is versioned and revertible.

**Residual risks**: the user may approve a malicious proposal (the diff and the
"influenced by untrusted data" flag are there to make that obvious); the model may
write a misleading *finish* message; mode descriptions written by the user are
treated as trusted. The LLM provider sees mode documents and the fenced untrusted
text; privacy redaction of activity happens upstream in the Dock engine.

## Wiring in the app

The host creates `AgentModule(store:dock:llm:)` with the Dock's `ModeStore`, an
adapter implementing `ModeAgentDockAccess` over the Dock engine, and
`LLMClientAgentLLM(client:)`. The Agent tab's `AgentControlling` maps to
`ModeAgent.run`, `ProposalCoordinator.approve/reject/revertProposal`, and the
`agent.proposal` / `agent.applied` events. That wiring is not done yet.
