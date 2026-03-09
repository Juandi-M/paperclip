# Agent Runtime Noise Reduction Roadmap

## Problem

Local-agent runs succeed but waste significant money and produce unnecessary noise:

- Idle agents with no assigned work still spawn, bootstrap, and burn tokens (Issue #373)
- Codex agents bill against the ChatGPT subscription quota instead of the OpenAI API, causing rate-limit resets
- Paperclip records `$0.00` cost for all Codex runs — budget enforcement and dashboards are blind to actual spend
- MCP auth noise from personal CLI config leaks into agent runs (`rmcp::transport::worker ... invalid_token`)
- Large stale Codex sessions are resumed on every timer wake, dragging in massive context with no benefit
- Missing `AGENT_HOME` causes agents to waste their first commands recovering missing paths
- Benign stderr warnings are visually indistinguishable from real failures in the run log

## Goals

1. Stop idle agents from spawning when there is no actionable work.
2. Route Codex billing to the OpenAI API (pay-per-token) instead of the subscription plan.
3. Track Codex spend inside Paperclip the same way Claude spend is tracked today.
4. Isolate agent runs from the operator's personal CLI environment.
5. Inject required env vars (`AGENT_HOME`, etc.) consistently.
6. Reduce stale session resume on low-value timer wakes.
7. Separate benign warnings from real failures in logs and UI.

## Non-Goals

- Redesigning the agent model or heartbeat product.
- Replacing Codex/Claude CLIs with a different runtime.
- Hiding real execution failures from operators.
- Large UI redesign work.

## Related PRs & Issues

| # | Title | Relation |
|---|-------|----------|
| [#373](https://github.com/paperclipai/paperclip/issues/373) | Idle agents consuming tokens with nothing to do | Core motivation for Phase 4 pre-flight guard |
| [#385](https://github.com/paperclipai/paperclip/pull/385) | Model-based token pricing for cost calculation | Directly implements Phase 7 cost estimation; Phase 7 should build on this, not duplicate it |
| [#386](https://github.com/paperclipai/paperclip/pull/386) | Route heartbeat cost recording through costService | **Blocker for Phase 7** — without this, company budget and agent auto-pause never trigger |
| [#255](https://github.com/paperclipai/paperclip/pull/255) | Spend & quota dashboard — provider breakdown, rolling windows | Implements Phase 7 UI deliverable; covers Anthropic vs OpenAI split |
| [#179](https://github.com/paperclipai/paperclip/pull/179) | Worktree cleanup lifecycle on session clear | Adjacent to Phase 3; stale worktrees from cleared sessions should be cleaned consistently |
| [#366](https://github.com/paperclipai/paperclip/pull/366) | Windows UTF-8 encoding and cross-platform compatibility | Hard constraint — runtime changes must not regress cross-platform spawn behavior |
| [#390](https://github.com/paperclipai/paperclip/issues/390) | Agent circuit breaker — loop detection and token waste prevention | Complementary; this roadmap reduces noise so the breaker signal is trustworthy |
| [#399](https://github.com/paperclipai/paperclip/pull/399) | General action approvals with adapter-level context injection | Sets the pattern for standardized env/context injection to reuse in Phases 1–2 |

---

## Phases

### Phase 1 — Runtime Isolation for Local Adapters

Decouple Paperclip agent runs from the operator's personal CLI environment.

- Define a Paperclip-owned runtime home/config directory per agent or company.
- Launch `codex_local` and `claude_local` with explicit env/config paths instead of inheriting personal defaults.
- Add an adapter-level allowlist for MCP servers intentionally available to an agent; default to none.
- Preserve cross-platform launch compatibility (PR #366 as hard constraint).

**Outcome:** Linear-style auth noise disappears unless that MCP is explicitly configured. Runs are reproducible across machines.

---

### Phase 2 — Required Environment Injection

Make agent runtime assumptions explicit and reliable.

- Always inject `AGENT_HOME` for local agents that use role folders.
- Ensure path variables are consistent with the agent's instructions file and workspace model.
- Add a pre-flight sanity check for required env vars before invoking the adapter.
- Standardize injection using the pattern from PR #399.

**Outcome:** Agents stop wasting their first commands discovering missing paths.

---

### Phase 3 — Session Resume Policy Hardening

Keep useful continuity, but stop dragging huge stale sessions into low-value wakes.

- Prefer fresh sessions when wake source is `timer`, no `issueId`/`taskId` is present, or the previous session is too old or too large.
- Add configurable thresholds for session age/size before automatic resume.
- Preserve resume only for same-task execution where continuity is genuinely valuable.
- Ensure compatibility with worktree cleanup lifecycle from PR #179.

**Outcome:** Lower token usage on routine heartbeats. Cleaner inputs for the circuit breaker from #390.

---

### Phase 4 — Heartbeat Pre-flight Guard (Idle Token Burn)

Stop spawning the adapter subprocess when there is nothing to do.

- Add an orchestration-level guard in the heartbeat service: check for assigned tasks, unread comments, or due scheduled events before spawning the CLI.
- If nothing actionable exists, exit immediately — no subprocess, no token cost.
- Document the intended wake policy: executives/managers may use timer wakes; execution agents should default to `wakeOnDemand` and assignment/comment-driven wakes.
- Align the "no progress" definition with the circuit breaker from #390.

**Outcome:** The majority of idle token burn across all agent types is eliminated. This directly addresses Issue #373.

---

### Phase 5 — Stderr Classification and UI Presentation

Distinguish real failures from benign runtime noise.

- Classify known benign stderr patterns separately from fatal errors.
- Render successful runs with warning annotations instead of error-style emphasis.
- Keep full raw logs available for deep debugging.
- Add short operator-facing explanations for common warning classes.

**Outcome:** Operators can scan runs faster. Successful work is not overshadowed by low-signal warnings.

---

### Phase 6 — Observability and Acceptance Metrics

Measure whether the cleanup actually worked.

Track before/after for:
- Successful runs containing stderr noise
- Timer wakes with no issue context
- Median input tokens for timer wakes
- Session resume rate by wake source
- Runs that fail first command due to missing env/path assumptions

**Outcome:** Evidence-based validation instead of intuition.

---

### Phase 7 — Codex Billing Mode and Cost Tracking

> **Immediate operator action required** — before any code changes, go to [platform.openai.com/api-keys](https://platform.openai.com/api-keys), create a key named **`paperclip`**, and add it to each codex agent config under `OPENAI_API_KEY`. This switches billing from the subscription quota (with resets) to pay-per-token API billing.

**Root cause:** `resolveCodexBillingType` in `codex-local/execute.ts` only checks `adapterConfig.env`, not `process.env`. So a Docker-level `OPENAI_API_KEY` is invisible to Paperclip's billing detection. Additionally, `docker-compose.quickstart.yml` uses `${OPENAI_API_KEY:-}` which silently passes an empty string when the var is unset. And the Codex CLI never emits `costUsd`, so `costCents` is always `$0`. PRs #385 and #386 must land before this phase produces correct results.

**Deliverables:**

1. **Fix billing detection** — fall through to `process.env.OPENAI_API_KEY` when agent config has no key, so Docker-level vars are recognized.
2. **Fix Docker silent failure** — change `${OPENAI_API_KEY:-}` to `${OPENAI_API_KEY:-}` with a warning, or document it clearly.
3. **Estimated cost from tokens** — build on PR #385's pricing table to compute cost from `inputTokens`/`outputTokens` when `costUsd` is null. Store as `calculatedCostCents`, not `costCents`, to distinguish estimated from adapter-reported.
4. **Global API key fallback** — server-level `OPENAI_API_KEY` acts as default for all `codex_local` agents that don't override it.
5. **Billing mode visibility** — surface whether each agent run used API or subscription billing in the run detail and cost dashboard (PR #255).

**Outcome:** Operators know where Codex charges land. Paperclip tracks Codex spend. Budget enforcement works. No more surprise quota resets.

---

### Phase 8 — Agent Runtime File Centralization and S3 Persistence

Agents currently write memory, notes, and logs scattered across their own subdirectories (`agents/*/memory/`, `agents/*/notes/`, `agents/*/life/`). These are runtime artifacts, not source code — they should never be in git.

**Immediate fix (done):** `.gitignore` now excludes `agents/*/memory/`, `agents/*/notes/`, `agents/*/life/`, `agents/*/plans/`, and `agents/*/logs/`. Instruction files (`AGENTS.md`, `HEARTBEAT.md`, `SOUL.md`, `TOOLS.md`) remain tracked.

**Problem with scattered writes:** agents need to be told explicitly where to write runtime files. Right now each agent decides its own path, leading to drift and inconsistency.

**Deliverables:**

1. **Centralized runtime directory** — define a canonical location for all agent runtime artifacts, e.g. `.agent-runtime/<agent-name>/` at the repo root (already git-ignored via `.agent-runtime/`), or mapped to the Paperclip data dir inside Docker (`/paperclip/instances/default/agent-runtime/`).
2. **Update all AGENTS.md files** — add an explicit `## Runtime Files` section telling each agent where to write memory/notes/logs, pointing to the centralized path.
3. **S3 sync fallback** — piggyback on Paperclip's existing storage provider abstraction (`local_disk` / `S3`). When storage provider is S3, periodically sync the agent runtime directory so files survive container restarts, rebuilds, and re-deployments. This is especially critical since Docker volumes can be wiped.
4. **Already-tracked files cleanup** — run `git rm --cached` on the agent runtime files that were committed before this gitignore landed (`agents/ceo/life/`, `agents/ceo/memory/`, `agents/qa-tester/notes/`, etc.) so they stop showing as modified in git status.

**Outcome:** Agent runtime files are never in git. They survive container restarts via S3. All agents write to a known, consistent location. `git status` stays clean during normal agent operation.

---

## Priority Order

| Priority | Work |
|----------|------|
| 1 | Phase 7 operator setup (create `paperclip` API key, add to agent configs) — do this now |
| 2 | Merge PR #386 (cost recording bug — blocker for budget enforcement) |
| 3 | Phase 4 pre-flight guard (biggest token waste reduction) |
| 4 | Phase 1 runtime isolation |
| 5 | Phase 2 env injection |
| 6 | Phase 3 session resume hardening |
| 7 | Phase 5 stderr classification |
| 8 | Phase 7 code changes (after #385 and #386 are merged) |
| 9 | Phase 6 observability metrics |
| 10 | Integrate circuit breaker (#390) after Phases 1–4 reduce noise |

## Acceptance Criteria

1. Agents with no assigned work do not spawn.
2. Codex API spend is visible in Paperclip's cost dashboard.
3. Successful runs no longer emit personal-MCP auth noise by default.
4. Agents that rely on role folders receive `AGENT_HOME` consistently.
5. Timer wakes without concrete issue work use materially fewer input tokens.
6. Successful runs show warnings separately from failures in the UI.
7. Operators can reproduce agent runtime behavior without depending on personal CLI state.

## Open Questions

1. Should runtime isolation be per company or per agent?
2. What session size/age threshold should disable automatic resume?
3. Should subscription-mode Codex runs be excluded from budget enforcement entirely?
4. Should the estimated cost flag (`calculatedCostCents`) be surfaced in the UI or silently accepted?
5. Should timer wakes for non-manager roles be discouraged in defaults or enforced in orchestration?
6. Should #390 ship only after Phases 1–4 complete, so the breaker doesn't learn from noisy baseline behavior?
