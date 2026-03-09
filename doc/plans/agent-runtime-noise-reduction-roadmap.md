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

2. Issue #373: Idle agents consuming tokens with nothing to do
   - Directly related to this roadmap. Agents with no assigned tasks, no new comments, and no scheduled work are still spawning, bootstrapping, and burning tokens.
   - Phase 4 of this roadmap addresses the same root cause: a pre-flight check before spawning the adapter subprocess — if the agent has no actionable work, skip the run entirely rather than launching just to have the agent read its docs and exit.
   - The fix is an orchestration-level guard in the heartbeat service: check for assigned tasks, unread comments, or due scheduled events before ever spawning the CLI. This would eliminate the majority of idle token burn across all agent types, not just Codex.

3. PR #385: Model-based token pricing for cost calculation
   - Directly implements part of Phase 7. Adds a model pricing registry (`packages/shared/src/pricing/models.ts`) and a `calculatedCostCents` column on `cost_events`, computed server-side from token counts.
   - Once merged, Codex runs will have estimated costs stored even when the adapter returns `costUsd: null`. Unknown models gracefully produce `null` instead of false data.
   - Phase 7 should align with this PR's pricing table and column rather than duplicating the approach.

4. PR #386: Route heartbeat cost recording through costService
   - Critical bug fix directly related to this roadmap's cost tracking goals. Direct SQL inserts in `updateRuntimeState()` bypassed `costService.createEvent()`, meaning company-level `spentMonthlyCents` was never updated and agent auto-pause on budget exceeded never triggered.
   - Before this fix, budget enforcement in Phase 7 cannot work correctly even after Codex costs are added.
   - Should be merged before or alongside any Phase 7 work.

5. PR #255: Spend & quota dashboard — provider breakdown, rolling windows, live budget tracking
   - Implements the UI component of Phase 7 deliverable #5 (cost dashboard parity). Adds a full Costs → Providers tab with per-provider/per-model breakdowns, rolling 5h/24h/7d burn windows, and live budget tracking.
   - Covers Anthropic vs OpenAI provider separation, which is exactly what Codex API billing visibility requires.
   - Phase 7 cost dashboard work should build on or defer to this PR rather than creating a parallel implementation.

6. PR #179: Worktree cleanup lifecycle on session clear
   - Adjacent infrastructure work: automatically removes `.paperclip-worktrees` directories when an adapter returns `clearSession: true` and the previous session cwd was inside a worktree.
   - Relevant to Phase 3 (session resume policy hardening) because stale worktrees left behind by abandoned or cleared sessions contribute to disk accumulation and could confuse session detection logic.
   - Phase 3 session cleanup work should be compatible with this worktree removal lifecycle.

7. PR #399: General action approvals with adapter-level context injection
   - Relevant because it establishes a strong pattern for adapter-level context injection via environment/context rather than ad hoc agent-specific logic.
   - Runtime cleanup work should reuse that approach when injecting standardized execution metadata, warnings, or policy context into local adapters.

8. Issue #390: Agent circuit breaker — automatic loop detection and token waste prevention
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

## Phase 7: Codex Billing Mode Selection and Cost Tracking

Objective: give operators explicit control over how Codex is billed, and track Codex spend inside Paperclip the same way Claude spend is tracked today.

### Operator Setup Prerequisite (do this now)

Before any code changes, operators running Paperclip with Codex agents must:

1. Go to [platform.openai.com/api-keys](https://platform.openai.com/api-keys)
2. Create a new API key — name it **`paperclip`** so spend is identifiable in the OpenAI dashboard
3. Add the key to the agent config in Paperclip UI: go to the codex agent → settings → env vars section → add `OPENAI_API_KEY = sk-...`
   - Or add it to the `.env` file next to `docker-compose.quickstart.yml` and restart the container

A dedicated key named `paperclip` makes it easy to isolate Paperclip's API usage from other tools sharing the same OpenAI account, and allows revoking or rotating it independently.

### Background

The `codex_local` adapter currently determines billing mode by checking whether `OPENAI_API_KEY` is present in the agent's `adapterConfig.env`. If the key is only set at the Docker/server level (in `process.env`), `resolveCodexBillingType` in `execute.ts` never sees it and records every run as `"subscription"` even when the subprocess is actually using API billing. Additionally, the Codex CLI does not emit a `costUsd` field in its JSON output, so `costCents` is always recorded as `0` for Codex runs — unlike Claude, which emits `total_cost_usd` directly.

A second silent failure exists in `docker-compose.quickstart.yml`: `OPENAI_API_KEY` uses `${OPENAI_API_KEY:-}` which passes an empty string when the host variable is unset, causing the adapter to silently fall back to subscription mode with no warning.

### Deliverables

1. **Fix billing type detection:** extend `resolveCodexBillingType` to fall through to `process.env.OPENAI_API_KEY` when the agent-level env does not contain one, so Docker-level keys are recognized correctly.
2. **Cost calculation from token counts:** when `costUsd` is absent from the Codex output, compute an estimated cost from `inputTokens`/`outputTokens` and a per-model price table (mirroring how OpenAI charges via API). Store this as `costCents` in `cost_events`, flagged as `"estimated"` to distinguish from exact values.
3. **Billing mode UI:** expose a per-agent toggle in the agent config UI — `Subscription` (no API key required, Codex charges the user's ChatGPT/Codex plan) vs `API Key` (requires `OPENAI_API_KEY`, billed through OpenAI API). Make the distinction visible so operators understand where charges land.
4. **Global API key fallback:** allow a server-level `OPENAI_API_KEY` (set via Docker env or secrets provider) to act as a default for all `codex_local` agents that do not override it, without requiring every agent to be reconfigured individually.
5. **Cost dashboard parity:** surface Codex cost events in the existing cost-by-agent and cost-by-project views alongside Claude spend.

### Expected Outcome

- Operators know exactly which billing account each Codex run hits.
- Paperclip tracks Codex spend rather than showing `$0.00` for every run.
- A single `OPENAI_API_KEY` at the deployment level covers all agents by default.
- No cost-tracking regression when Docker-level keys are used.

### Open Questions

1. Should the estimated cost flag be surfaced in the UI, or silently accepted as close enough?
2. How often should the model price table be updated, and where should it live (hardcoded, config, or remote)?
3. Should subscription-mode runs be excluded from budget enforcement (since Paperclip cannot know the real spend)?

---

## Priority Order

1. Runtime isolation for local adapters
2. `AGENT_HOME` injection and runtime env sanity
3. Session resume policy hardening
4. Stderr classification in backend/UI
5. Broader heartbeat-policy hygiene
6. Integrate with the circuit-breaker work from issue #390 once runtime noise is reduced enough that breaker signals are trustworthy
7. Codex billing mode selection and cost tracking

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
