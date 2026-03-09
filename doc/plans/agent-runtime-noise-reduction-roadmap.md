# Agent Runtime Noise Reduction Roadmap

## Context

Current local-agent runs are succeeding, but the run logs show recurring runtime noise and avoidable overhead:

- MCP auth noise from globally configured providers such as Linear:
  - `rmcp::transport::worker ... invalid_token`
- local CLI cleanup noise:
  - `shell_snapshot ... No such file or directory`
- missing `AGENT_HOME` in the launched shell environment, which causes some agents to fail their first path lookup and recover manually
- large resumed Codex sessions that carry too much historical context for timer/comment wakes
- timer-driven heartbeats spending tokens on reloading docs and restating role posture even when no concrete issue work exists

These are primarily runtime hygiene problems, not product-surface problems.

## Goals

1. Isolate Paperclip-managed local agents from the operator's personal Codex/Claude runtime state.
2. Remove or sharply reduce non-actionable stderr noise in successful runs.
3. Ensure required runtime environment variables such as `AGENT_HOME` are injected consistently.
4. Reduce token burn from unnecessary session resume and timer wakes without breaking useful continuity.
5. Preserve debuggability: real runtime failures must remain visible.

## Non-Goals

- Redesigning the agent model or heartbeat product.
- Replacing Codex/Claude CLIs with a different runtime.
- Hiding real execution failures from operators.
- Large UI redesign work.

## What We Know Today

- Local adapters inherit enough host/runtime state that personal MCP configuration can leak into agent runs.
- The `Linear` MCP auth warning is likely not coming from repo logic directly; it appears because the launched CLI sees an MCP configuration it cannot authenticate.
- Successful runs currently surface benign stderr alongside real errors with little classification.
- Some agent prompts assume `AGENT_HOME`, but the shell environment does not always include it.
- Timer wakes often resume or bootstrap sessions even when no issue-specific work is present.

## Related Work

This roadmap should stay aligned with the following ongoing or proposed work:

1. PR #366: Windows UTF-8 encoding and cross-platform compatibility
   - Relevant because runtime cleanup should not regress cross-platform spawn behavior, env injection, or script compatibility.
   - Cross-platform process-launch and encoding hygiene should be treated as a hard constraint for any local-adapter runtime changes.

2. PR #399: General action approvals with adapter-level context injection
   - Relevant because it establishes a strong pattern for adapter-level context injection via environment/context rather than ad hoc agent-specific logic.
   - Runtime cleanup work should reuse that approach when injecting standardized execution metadata, warnings, or policy context into local adapters.

3. Issue #390: Agent circuit breaker — automatic loop detection and token waste prevention
   - Complementary to this roadmap.
   - This roadmap reduces avoidable noise and unnecessary token burn at launch/resume time.
   - Issue #390 addresses a different but adjacent layer: detecting wasteful behavior after runs complete and auto-pausing agents.

## Roadmap

## Phase 1: Runtime Isolation for Local Adapters

Objective: decouple Paperclip agent runs from the operator's personal CLI environment.

### Deliverables

1. Define a Paperclip-owned runtime home/config directory per agent or per company runtime.
2. Launch `codex_local` and `claude_local` with explicit env/config paths instead of inheriting personal defaults.
3. Add adapter-level config/allowlist for MCP servers that are intentionally available to an agent.
4. Default to no personal MCPs unless explicitly enabled.
5. Preserve cross-platform launch compatibility from PR #366, especially around Windows-safe process spawning, encoding, and env handling.

### Expected Outcome

- `Linear`-style auth noise disappears unless that MCP is explicitly configured for the agent.
- Runs become more reproducible across machines and operators.

## Phase 2: Required Environment Injection

Objective: make agent runtime assumptions explicit and reliable.

### Deliverables

1. Always inject `AGENT_HOME` for local agents that use role folders.
2. Ensure related path variables are consistent with the agent's instructions file and workspace model.
3. Add a startup/runtime sanity check for required env vars before invoking the adapter.
4. Reuse the adapter-level context/env injection style established in PR #399 so runtime metadata is standardized instead of agent-specific.

### Expected Outcome

- Agents stop wasting their first commands on discovering missing home paths.
- Role-specific instructions become reliable and less noisy.

## Phase 3: Session Resume Policy Hardening

Objective: keep useful continuity, but avoid dragging huge stale sessions into low-value wakes.

### Deliverables

1. Tighten resume conditions for timer wakes with no issue/task context.
2. Prefer fresh sessions when:
   - wake source is `timer`
   - no `issueId`/`taskId` is present
   - previous session is too old or too large
3. Add configurable thresholds for session age/size before automatic resume.
4. Preserve resume for same-task execution where continuity is actually valuable.

### Expected Outcome

- Lower token usage on routine heartbeats.
- Cleaner, more focused runs.
- Cleaner inputs for a future circuit-breaker implementation from issue #390, because resume noise and gratuitous context bloat stop looking like "activity."

## Phase 4: Heartbeat Policy Hygiene

Objective: reduce workless wakes that only reread docs and reassert role.

### Deliverables

1. Document and encourage a default operating pattern:
   - executives/managers may use timer wakes
   - execution agents default to `wakeOnDemand` and assignment/comment-driven wakes
2. Add stronger prompt/runtime guidance so agents exit early when no assigned issue exists.
3. Consider optional guardrails in orchestration to skip timer wakes for roles that have no current actionable scope.
4. Align no-progress definitions with the future circuit-breaker model from issue #390 so the system uses one coherent notion of "wasteful execution."

### Expected Outcome

- Less idle token burn.
- Heartbeat activity aligns better with real work.

## Phase 5: Stderr Classification and UI Presentation

Objective: distinguish real failures from benign runtime noise.

### Deliverables

1. Classify known benign stderr patterns separately from fatal execution errors.
2. Store/render successful runs with warning annotations instead of error-style emphasis.
3. Keep full raw logs available for deep debugging.
4. Add a short operator-facing explanation for common warning classes.

### Expected Outcome

- Operators can scan runs faster.
- Successful work is not visually overshadowed by low-signal warnings.

## Phase 6: Observability and Acceptance Metrics

Objective: measure whether the cleanup actually improved runtime quality.

### Deliverables

Track before/after metrics for:

1. successful runs containing stderr noise
2. timer wakes with no issue context
3. median input tokens for timer wakes
4. session resume rate by wake source
5. runs that fail first command due to missing env/path assumptions

### Expected Outcome

- We can verify the cleanup with evidence instead of intuition.

## Priority Order

1. Runtime isolation for local adapters
2. `AGENT_HOME` injection and runtime env sanity
3. Session resume policy hardening
4. Stderr classification in backend/UI
5. Broader heartbeat-policy hygiene
6. Integrate with the circuit-breaker work from issue #390 once runtime noise is reduced enough that breaker signals are trustworthy

## Acceptance Criteria

1. Successful runs no longer emit personal-MCP auth noise by default.
2. Agents that rely on role folders receive `AGENT_HOME` consistently.
3. Timer wakes without concrete issue work use materially fewer input tokens than today.
4. Successful runs may still show warnings, but the UI clearly separates warnings from failures.
5. Operators can reproduce agent runtime behavior without depending on the machine owner's personal CLI state.

## Open Questions

1. Should runtime isolation be per company or per agent?
2. Should MCP access be deny-by-default for all local agents?
3. What session size/age threshold should disable automatic resume?
4. Should timer wakes for non-manager roles be discouraged in product defaults, or enforced more strictly in orchestration?
5. Which pieces of PR #366 should be treated as non-negotiable invariants for all local-adapter runtime changes?
6. Should approval/context injection from PR #399 become the standard mechanism for all adapter runtime metadata, not just approvals?
7. Should issue #390 ship only after Phases 1-4 here, so the breaker does not learn from noisy baseline behavior?
