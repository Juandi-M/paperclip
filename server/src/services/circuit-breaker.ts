import { and, desc, eq, inArray, notInArray } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { agents, heartbeatRuns } from "@paperclipai/db";
import { logger } from "../middleware/logger.js";
import { logActivity } from "./activity-log.js";
import { publishLiveEvent } from "./live-events.js";
import { parseObject, asNumber, asBoolean } from "../adapters/utils.js";

export interface CircuitBreakerConfig {
  enabled: boolean;
  maxConsecutiveFailures: number;
  maxConsecutiveNoProgress: number;
  tokenVelocityMultiplier: number;
}

const DEFAULTS: CircuitBreakerConfig = {
  enabled: true,
  maxConsecutiveFailures: 3,
  maxConsecutiveNoProgress: 5,
  tokenVelocityMultiplier: 3.0,
};

export function parseCircuitBreakerConfig(agent: typeof agents.$inferSelect): CircuitBreakerConfig {
  const runtimeConfig = parseObject(agent.runtimeConfig);
  const cb = parseObject(runtimeConfig.circuitBreaker);

  return {
    enabled: asBoolean(cb.enabled, DEFAULTS.enabled),
    maxConsecutiveFailures: Math.max(1, asNumber(cb.maxConsecutiveFailures, DEFAULTS.maxConsecutiveFailures)),
    maxConsecutiveNoProgress: Math.max(1, asNumber(cb.maxConsecutiveNoProgress, DEFAULTS.maxConsecutiveNoProgress)),
    tokenVelocityMultiplier: Math.max(1.5, asNumber(cb.tokenVelocityMultiplier, DEFAULTS.tokenVelocityMultiplier)),
  };
}

export type TripReason = "consecutive_failures" | "consecutive_no_progress" | "token_velocity_spike";

export interface CircuitBreakerResult {
  tripped: boolean;
  reason?: TripReason;
  details?: Record<string, unknown>;
}

/**
 * Evaluate circuit breaker conditions for an agent after a run completes.
 * Returns whether the breaker should trip and why.
 */
export async function evaluateCircuitBreaker(
  db: Db,
  agentId: string,
  outcome: "succeeded" | "failed" | "cancelled" | "timed_out",
): Promise<CircuitBreakerResult> {
  const agent = await db
    .select()
    .from(agents)
    .where(eq(agents.id, agentId))
    .then((rows) => rows[0] ?? null);

  if (!agent) return { tripped: false };

  const config = parseCircuitBreakerConfig(agent);
  if (!config.enabled) return { tripped: false };

  // Skip evaluation for cancelled runs — those are intentional
  if (outcome === "cancelled") return { tripped: false };

  // Check consecutive failures
  if (outcome === "failed" || outcome === "timed_out") {
    const failureResult = await checkConsecutiveFailures(db, agentId, config);
    if (failureResult.tripped) return failureResult;
  }

  // Check consecutive no-progress (only for succeeded runs that did nothing useful)
  if (outcome === "succeeded") {
    const noProgressResult = await checkConsecutiveNoProgress(db, agentId, config);
    if (noProgressResult.tripped) return noProgressResult;
  }

  // Check token velocity spike — includes failed/timed_out runs since those
  // can be the most expensive. Only excludes cancelled/skipped.
  const velocityResult = await checkTokenVelocity(db, agentId, config);
  if (velocityResult.tripped) return velocityResult;

  return { tripped: false };
}

async function checkConsecutiveFailures(
  db: Db,
  agentId: string,
  config: CircuitBreakerConfig,
): Promise<CircuitBreakerResult> {
  const recentRuns = await db
    .select({ status: heartbeatRuns.status })
    .from(heartbeatRuns)
    .where(eq(heartbeatRuns.agentId, agentId))
    .orderBy(desc(heartbeatRuns.createdAt))
    .limit(config.maxConsecutiveFailures);

  if (recentRuns.length < config.maxConsecutiveFailures) return { tripped: false };

  const allFailed = recentRuns.every(
    (r) => r.status === "failed" || r.status === "timed_out",
  );

  if (allFailed) {
    return {
      tripped: true,
      reason: "consecutive_failures",
      details: {
        consecutiveFailures: config.maxConsecutiveFailures,
        threshold: config.maxConsecutiveFailures,
      },
    };
  }

  return { tripped: false };
}

async function checkConsecutiveNoProgress(
  db: Db,
  agentId: string,
  config: CircuitBreakerConfig,
): Promise<CircuitBreakerResult> {
  const recentRuns = await db
    .select({
      status: heartbeatRuns.status,
      resultJson: heartbeatRuns.resultJson,
    })
    .from(heartbeatRuns)
    .where(eq(heartbeatRuns.agentId, agentId))
    .orderBy(desc(heartbeatRuns.createdAt))
    .limit(config.maxConsecutiveNoProgress);

  if (recentRuns.length < config.maxConsecutiveNoProgress) return { tripped: false };

  // All recent runs must be succeeded (failures are caught by checkConsecutiveFailures)
  const allSucceeded = recentRuns.every((r) => r.status === "succeeded");
  if (!allSucceeded) return { tripped: false };

  // A run counts as "no progress" when resultJson carries none of the known
  // progress indicators. Adapters that don't write these fields at all will
  // produce a false-positive — this is intentionally conservative: a run that
  // claims no work is safer to flag than a runaway loop.
  const allNoProgress = recentRuns.every((r) => {
    const result = r.resultJson as Record<string, unknown> | null;
    if (!result) return true;
    const issuesModified = Number(result.issuesModified ?? result.issuesMoved ?? 0);
    const issuesCreated = Number(result.issuesCreated ?? 0);
    const commentsPosted = Number(result.commentsPosted ?? 0);
    return issuesModified === 0 && issuesCreated === 0 && commentsPosted === 0;
  });

  if (allNoProgress) {
    return {
      tripped: true,
      reason: "consecutive_no_progress",
      details: {
        consecutiveNoProgress: config.maxConsecutiveNoProgress,
        threshold: config.maxConsecutiveNoProgress,
      },
    };
  }

  return { tripped: false };
}

function extractTotalTokens(usageJson: Record<string, unknown> | null): number {
  if (!usageJson) return 0;
  // Anthropic SDK: input_tokens + output_tokens (cache_read_input_tokens is a
  // subset of input_tokens, not additive)
  const input = Number(usageJson.input_tokens ?? 0);
  const output = Number(usageJson.output_tokens ?? 0);
  // OpenAI SDK: prompt_tokens + completion_tokens
  const prompt = Number(usageJson.prompt_tokens ?? 0);
  const completion = Number(usageJson.completion_tokens ?? 0);
  return Math.max(input + output, prompt + completion);
}

async function checkTokenVelocity(
  db: Db,
  agentId: string,
  config: CircuitBreakerConfig,
): Promise<CircuitBreakerResult> {
  // Include succeeded, failed, and timed_out — expensive failed/timed_out runs
  // are the most important case to catch (Greptile fix: original PR only looked
  // at succeeded, missing runaway failed runs entirely).
  const recentRuns = await db
    .select({ usageJson: heartbeatRuns.usageJson, status: heartbeatRuns.status })
    .from(heartbeatRuns)
    .where(
      and(
        eq(heartbeatRuns.agentId, agentId),
        inArray(heartbeatRuns.status, ["succeeded", "failed", "timed_out"]),
      ),
    )
    .orderBy(desc(heartbeatRuns.createdAt))
    .limit(20);

  // Need at least 5 data points for a meaningful average
  if (recentRuns.length < 5) return { tripped: false };

  const tokenCounts = recentRuns.map((r) =>
    extractTotalTokens(r.usageJson as Record<string, unknown> | null),
  );

  const latestTokens = tokenCounts[0] ?? 0;
  if (latestTokens === 0) return { tripped: false };

  // Average of all runs except the latest
  const historicalTokens = tokenCounts.slice(1);
  const avgTokens = historicalTokens.reduce((sum, t) => sum + t, 0) / historicalTokens.length;

  if (avgTokens === 0) return { tripped: false };

  const ratio = latestTokens / avgTokens;

  if (ratio >= config.tokenVelocityMultiplier) {
    return {
      tripped: true,
      reason: "token_velocity_spike",
      details: {
        latestTokens,
        averageTokens: Math.round(avgTokens),
        ratio: Number(ratio.toFixed(2)),
        threshold: config.tokenVelocityMultiplier,
      },
    };
  }

  return { tripped: false };
}

/**
 * Trip the circuit breaker: pause the agent atomically, log activity, publish event.
 *
 * Uses a guarded UPDATE (WHERE status NOT IN paused/terminated) to prevent
 * a TOCTOU race condition when two evaluations run concurrently (Greptile fix).
 */
export async function tripCircuitBreaker(
  db: Db,
  agentId: string,
  result: CircuitBreakerResult,
) {
  // Fetch agent first for companyId and name (needed for logging/events).
  const agent = await db
    .select()
    .from(agents)
    .where(eq(agents.id, agentId))
    .then((rows) => rows[0] ?? null);

  if (!agent) return;

  logger.warn(
    { agentId, agentName: agent.name, reason: result.reason, details: result.details },
    "circuit breaker tripped - pausing agent",
  );

  // Atomic UPDATE: only succeeds if the agent is still in a non-terminal state.
  // If another process already paused or terminated this agent the UPDATE will
  // match 0 rows — we bail out early to avoid double-tripping.
  const updated = await db
    .update(agents)
    .set({ status: "paused", updatedAt: new Date() })
    .where(
      and(
        eq(agents.id, agentId),
        notInArray(agents.status, ["paused", "terminated"]),
      ),
    )
    .returning({ id: agents.id })
    .then((rows) => rows[0] ?? null);

  if (!updated) {
    logger.info({ agentId }, "circuit breaker: agent already paused/terminated, skipping trip");
    return;
  }

  await logActivity(db, {
    companyId: agent.companyId,
    actorType: "system",
    actorId: "circuit-breaker",
    action: "agent.circuit_breaker_tripped",
    entityType: "agent",
    entityId: agentId,
    agentId,
    details: {
      reason: result.reason,
      ...result.details,
    },
  });

  publishLiveEvent({
    companyId: agent.companyId,
    type: "agent.status",
    payload: {
      agentId: agent.id,
      status: "paused",
      reason: "circuit_breaker_tripped",
      circuitBreakerReason: result.reason,
      circuitBreakerDetails: result.details,
    },
  });
}
