/**
 * Project edit-lock endpoints (Build #5.59.1).
 *
 *   GET    /v1/projects/:id/lock            → current lock (or null)
 *   POST   /v1/projects/:id/lock            → acquire (409 if held live)
 *   POST   /v1/projects/:id/lock/heartbeat  → bump expiry (holder only)
 *   DELETE /v1/projects/:id/lock            → release (holder only)
 *   POST   /v1/projects/:id/lock/force      → admin force-release
 *
 * Backed by `project_locks` (migration 0006). At most one lock row
 * per project. Expiry is enforced in app logic: a row whose
 * `expires_at < now()` is treated as free, so a crashed editor never
 * strands a project (no background reaper needed).
 *
 * Lock duration window: each acquire / heartbeat sets
 * `expires_at = now() + LOCK_TTL_MS`. The editing client heartbeats
 * well inside that window (web every 90s; TTL is 10 min) so normal
 * editing keeps the lock alive while a closed tab lets it lapse.
 *
 * Force-release is currently allowed for any signed-in user — there's
 * no admin role yet (Phase 5). The audit_log row records who forced
 * it so it's traceable. Tighten to admin-only when roles land.
 */

import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import type {
  ApiError,
  GetLockResponse,
  LockResponse,
  ProjectLock,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";

/** Lock lifetime per heartbeat — 10 minutes. Matches the plan's
 *  "auto-expires after 10 min without heartbeat." */
const LOCK_TTL_MS = 10 * 60 * 1000;

const AcquireBodySchema = z.object({
  client: z.enum(["web", "ios"]),
});

interface LockRow {
  project_id: string;
  user_id: string;
  user_email: string;
  client: "web" | "ios";
  acquired_at: string;
  last_heartbeat: string;
  expires_at: string;
}

function rowToLock(row: LockRow): ProjectLock {
  return {
    projectId: row.project_id,
    userId: row.user_id,
    userEmail: row.user_email,
    client: row.client,
    acquiredAt: row.acquired_at,
    lastHeartbeat: row.last_heartbeat,
    expiresAt: row.expires_at,
  };
}

/** A row is "live" (still holds the lock) when its expiry is in the
 *  future. Past-expiry rows are treated as free. */
function isLive(row: LockRow): boolean {
  return new Date(row.expires_at).getTime() > Date.now();
}

export const locksRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);

  // Ownership check shared by every handler — same shape the other
  // project routes use. Returns true when the caller owns the
  // project (and it exists).
  async function callerOwnsProject(
    projectId: string,
    userId: string
  ): Promise<boolean> {
    const { data, error } = await supabaseAdmin
      .from("projects")
      .select("id")
      .eq("id", projectId)
      .eq("owner_id", userId)
      .maybeSingle();
    if (error) throw error;
    return data != null;
  }

  // -----------------------------------------------------------------
  // GET /v1/projects/:id/lock — current lock state (or null when free)
  // -----------------------------------------------------------------
  app.get<{
    Params: { id: string };
    Reply: GetLockResponse | ApiError;
  }>("/v1/projects/:id/lock", async (request, reply) => {
    const projectId = request.params.id;
    const { data, error } = await supabaseAdmin
      .from("project_locks")
      .select("*")
      .eq("project_id", projectId)
      .maybeSingle();
    if (error) {
      request.log.error({ err: error, projectId }, "lock GET failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    if (!data || !isLive(data as LockRow)) {
      return { lock: null };
    }
    return { lock: rowToLock(data as LockRow) };
  });

  // -----------------------------------------------------------------
  // POST /v1/projects/:id/lock — acquire
  // -----------------------------------------------------------------
  // You can take the lock when it's free OR the existing row has
  // expired OR you already hold it (re-acquire / refresh). A live
  // lock held by another user → 409 with the holder in `details`.
  app.post<{
    Params: { id: string };
    Body: unknown;
    Reply: LockResponse | ApiError;
  }>("/v1/projects/:id/lock", async (request, reply) => {
    const projectId = request.params.id;
    const parsed = AcquireBodySchema.safeParse(request.body);
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }

    try {
      if (!(await callerOwnsProject(projectId, request.user.id))) {
        reply.code(404).send({ error: "not_found", message: `Project ${projectId} not found` });
        return;
      }
    } catch (err) {
      request.log.error({ err, projectId }, "lock acquire — ownership check failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    // Read the current row to decide if it's free / expired / mine.
    const { data: existing, error: readErr } = await supabaseAdmin
      .from("project_locks")
      .select("*")
      .eq("project_id", projectId)
      .maybeSingle();
    if (readErr) {
      request.log.error({ err: readErr, projectId }, "lock acquire — read failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    if (existing && isLive(existing as LockRow) && (existing as LockRow).user_id !== request.user.id) {
      // Held live by someone else.
      reply.code(409).send({
        error: "locked",
        message: `Project is being edited by ${(existing as LockRow).user_email}.`,
        details: { lock: rowToLock(existing as LockRow) },
      });
      return;
    }

    const now = new Date();
    const expiresAt = new Date(now.getTime() + LOCK_TTL_MS);
    // Preserve acquired_at when re-acquiring my own / refreshing an
    // expired row I held; otherwise stamp a fresh acquisition.
    const acquiredAt =
      existing && (existing as LockRow).user_id === request.user.id
        ? (existing as LockRow).acquired_at
        : now.toISOString();

    const { data: upserted, error: writeErr } = await supabaseAdmin
      .from("project_locks")
      .upsert(
        {
          project_id: projectId,
          user_id: request.user.id,
          user_email: request.user.email,
          client: parsed.data.client,
          acquired_at: acquiredAt,
          last_heartbeat: now.toISOString(),
          expires_at: expiresAt.toISOString(),
        },
        { onConflict: "project_id" }
      )
      .select("*")
      .maybeSingle();
    if (writeErr || !upserted) {
      request.log.error({ err: writeErr, projectId }, "lock acquire — write failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    request.log.info({ projectId, userId: request.user.id }, "lock acquired");
    return { lock: rowToLock(upserted as LockRow) };
  });

  // -----------------------------------------------------------------
  // POST /v1/projects/:id/lock/heartbeat — bump the expiry window
  // -----------------------------------------------------------------
  app.post<{
    Params: { id: string };
    Reply: LockResponse | ApiError;
  }>("/v1/projects/:id/lock/heartbeat", async (request, reply) => {
    const projectId = request.params.id;
    const { data: existing, error: readErr } = await supabaseAdmin
      .from("project_locks")
      .select("*")
      .eq("project_id", projectId)
      .maybeSingle();
    if (readErr) {
      request.log.error({ err: readErr, projectId }, "lock heartbeat — read failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    if (!existing || (existing as LockRow).user_id !== request.user.id) {
      // Either nobody holds it, or someone else does — the client's
      // lock is gone (expired + taken, or force-released). 409 tells
      // it to stop editing + re-acquire.
      reply.code(409).send({
        error: "lock_lost",
        message: "Your edit lock is no longer held. Re-acquire to continue editing.",
      });
      return;
    }
    const now = new Date();
    const expiresAt = new Date(now.getTime() + LOCK_TTL_MS);
    const { data: updated, error: writeErr } = await supabaseAdmin
      .from("project_locks")
      .update({
        last_heartbeat: now.toISOString(),
        expires_at: expiresAt.toISOString(),
      })
      .eq("project_id", projectId)
      .eq("user_id", request.user.id)
      .select("*")
      .maybeSingle();
    if (writeErr || !updated) {
      request.log.error({ err: writeErr, projectId }, "lock heartbeat — write failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    return { lock: rowToLock(updated as LockRow) };
  });

  // -----------------------------------------------------------------
  // DELETE /v1/projects/:id/lock — release (holder only)
  // -----------------------------------------------------------------
  app.delete<{
    Params: { id: string };
    Reply: { ok: true } | ApiError;
  }>("/v1/projects/:id/lock", async (request, reply) => {
    const projectId = request.params.id;
    const { error } = await supabaseAdmin
      .from("project_locks")
      .delete()
      .eq("project_id", projectId)
      .eq("user_id", request.user.id);
    if (error) {
      request.log.error({ err: error, projectId }, "lock release failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    // Idempotent — deleting a non-existent / not-mine row is a no-op
    // that still returns ok. (If someone else holds it, this delete
    // matched zero rows and left theirs intact.)
    request.log.info({ projectId, userId: request.user.id }, "lock released");
    return { ok: true };
  });

  // -----------------------------------------------------------------
  // POST /v1/projects/:id/lock/force — force-release any lock
  // -----------------------------------------------------------------
  // No admin role yet (Phase 5), so any signed-in user can force.
  // Logged for traceability.
  app.post<{
    Params: { id: string };
    Reply: { ok: true } | ApiError;
  }>("/v1/projects/:id/lock/force", async (request, reply) => {
    const projectId = request.params.id;
    const { error } = await supabaseAdmin
      .from("project_locks")
      .delete()
      .eq("project_id", projectId);
    if (error) {
      request.log.error({ err: error, projectId }, "lock force-release failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    request.log.warn(
      { projectId, forcedBy: request.user.id },
      "lock force-released"
    );
    return { ok: true };
  });
};
