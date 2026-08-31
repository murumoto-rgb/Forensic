import type { FastifyReply } from "fastify";
import { supabaseAdmin } from "./supabase.js";
import { env } from "./env.js";

/** Fail closed: a broken quota database cannot turn into unlimited paid calls. */
export async function reserveAI(actor: string, reply: FastifyReply): Promise<string | null> {
  const { data, error } = await supabaseAdmin.rpc("reserve_ai_work", {
    actor, daily_limit: env.AI_DAILY_REQUEST_LIMIT, concurrent_limit: env.AI_CONCURRENCY_LIMIT,
  }).abortSignal(AbortSignal.timeout(10000));
  if (error || !data) {
    reply.code(503).send({ error: "limits_unavailable", message: "AI usage limits are unavailable. Retry later." });
    return null;
  }
  if (!data.ok) {
    const daily = data.reason === "daily";
    reply.header("Retry-After", daily ? 3600 : 15).code(429).send({
      error: daily ? "daily_ai_limit" : "ai_busy",
      message: daily ? "Daily AI request limit reached. It resets at midnight UTC."
        : "AI concurrency limit reached. Wait for the current analyses to finish.",
    });
    return null;
  }
  return data.lease as string;
}
export async function releaseAI(actor: string, lease: string): Promise<void> {
  // A failed release remains charged and expires conservatively after 5 minutes.
  try {
    await supabaseAdmin.rpc("release_ai_work", { actor, lease }).abortSignal(AbortSignal.timeout(10000));
  } catch {
    // A failed best-effort release must not turn a completed analysis into
    // a failed response that the client might spend money repeating.
  }
}
export function sendExportLimit(reply: FastifyReply, error: { message: string } | null): boolean {
  if (!error || !/export_(queue_full|daily_limit)/.test(error.message)) return false;
  reply.header("Retry-After", 60).code(429).send({
    error: "export_limit",
    message: error.message.includes("daily") ? "Daily export limit reached (50 requests). It resets at midnight UTC."
      : "Export queue is full. Wait for a current export to finish, then retry.",
  });
  return true;
}
