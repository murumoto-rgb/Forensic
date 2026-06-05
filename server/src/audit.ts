/**
 * Append-only audit log writer (Build #5.45.1). Backed by the
 * `audit_log` table from migration 0005. Writes are best-effort —
 * a failure here logs but never fails the caller's request.
 *
 * Today only the `/v1/ai/tag-photo` proxy writes (one row per
 * Anthropic call with token usage + estimated cost). Future
 * surfaces (manifest writes, force-unlock, config edits) can drop
 * rows with their own `event_type` string and bespoke `detail`
 * JSON.
 */

import type { FastifyBaseLogger } from "fastify";
import { supabaseAdmin } from "./supabase.js";

/**
 * Per-1M-token rates per model, in USD. Used to convert token
 * counts into the integer count of hundred-thousandths of a cent
 * the `audit_log` table stores. Keep in sync with Anthropic's
 * pricing page as new generations ship — a drift here just means
 * the per-call cost estimate is wrong, not that anything else
 * breaks.
 *
 * Cache reads land at ~0.1× the input-token rate; cache writes
 * land at ~1.25× the input-token rate. We bill them per the
 * documented multipliers so the totals match Anthropic's invoice.
 */
const PRICING_PER_MILLION_USD: Record<
  string,
  { input: number; output: number; cacheRead: number; cacheWrite: number }
> = {
  "claude-sonnet-4-6": {
    input: 3,
    output: 15,
    cacheRead: 0.3,
    cacheWrite: 3.75,
  },
  "claude-haiku-4-5": {
    input: 1,
    output: 5,
    cacheRead: 0.1,
    cacheWrite: 1.25,
  },
};

export function estimateCostHundredThousandthsOfCents(args: {
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
}): number {
  const rates = PRICING_PER_MILLION_USD[args.model];
  if (!rates) return 0; // unknown model — record 0 rather than guess

  // USD per token = rate_per_million / 1_000_000.
  // Hundred-thousandths of a cent per token = USD * 10_000_000.
  // So multiplier from "$X per 1M tokens" to "h-t-cents per
  // token" = X * 10_000_000 / 1_000_000 = X * 10.
  // i.e. one token at $3/1M ≈ 30 hundred-thousandths of a cent.
  const inputCost = args.inputTokens * rates.input * 10;
  const outputCost = args.outputTokens * rates.output * 10;
  const cacheReadCost = args.cacheReadTokens * rates.cacheRead * 10;
  const cacheWriteCost = args.cacheCreationTokens * rates.cacheWrite * 10;
  return Math.round(inputCost + outputCost + cacheReadCost + cacheWriteCost);
}

export interface AITagAuditRow {
  userId: string | null;
  projectId: string | null;
  photoId: string | null;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  durationMs: number;
  /** Optional extra context — e.g. whether the call was a repair
   *  retry, the raw-response length, etc. Free-form JSON. */
  detail?: Record<string, unknown>;
}

/**
 * Insert an `ai_tag_photo` row into `audit_log`. Best-effort —
 * logs but never throws. Caller's response is sent before we get
 * here (or in parallel via `void`) so even a slow database
 * doesn't add latency to the user-facing path.
 */
export async function recordAITagAudit(
  row: AITagAuditRow,
  log: FastifyBaseLogger
): Promise<void> {
  try {
    const costEstimate = estimateCostHundredThousandthsOfCents({
      model: row.model,
      inputTokens: row.inputTokens,
      outputTokens: row.outputTokens,
      cacheReadTokens: row.cacheReadTokens,
      cacheCreationTokens: row.cacheCreationTokens,
    });
    const { error } = await supabaseAdmin.from("audit_log").insert({
      event_type: "ai_tag_photo",
      user_id: row.userId,
      project_id: row.projectId,
      photo_id: row.photoId,
      model: row.model,
      input_tokens: row.inputTokens,
      output_tokens: row.outputTokens,
      cache_read_tokens: row.cacheReadTokens,
      cache_creation_tokens: row.cacheCreationTokens,
      duration_ms: row.durationMs,
      cost_estimate_hundred_thousandths_of_cents: costEstimate,
      detail: row.detail ?? null,
    });
    if (error) {
      log.warn({ err: error }, "audit_log insert failed (continuing)");
    }
  } catch (err) {
    log.warn({ err }, "audit_log insert threw (continuing)");
  }
}
