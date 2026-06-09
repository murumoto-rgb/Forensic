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
import { assertProjectAccess, sendAccessError } from "../access.js";
import { sendEmail } from "../email/resend.js";
import {
  lockForceReleasedEmail,
  lockExpiredTakenOverEmail,
} from "../email/templates.js";
import { env } from "../env.js";

/** Lock lifetime per heartbeat — 10 minutes. Matches the plan's
 *  "auto-expires after 10 min without heartbeat." */
const LOCK_TTL_MS = 10 * 60 * 1000;

const AcquireBodySchema = z.object({
  client: z.enum(["web", "ios"]),
  /** Per-tab session token (Build #5.120.1). Web sends a
   *  sessionStorage-backed UUID; iOS omits. Lets the server
   *  distinguish same-user-same-tab from same-user-different-tab. */
  clientSession: z.string().optional(),
});

const ReleaseBodySchema = z.object({
  clientSession: z.string().optional(),
});

interface LockRow {
  project_id: string;
  user_id: string;
  user_email: string;
  client: "web" | "ios";
  acquired_at: string;
  last_heartbeat: string;
  expires_at: string;
  client_session: string | null;
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
    clientSession: row.client_session,
  };
}

/** Compute the caller's relationship to a live lock row.
 *  See `GetLockResponse.heldByYou` for the discriminator semantics. */
function heldByYou(
  row: LockRow,
  callerUserId: string,
  callerSession: string | null
): "session" | "user" | null {
  if (row.user_id !== callerUserId) return null;
  if (callerSession === null || row.client_session === null) return "user";
  return row.client_session === callerSession ? "session" : "user";
}

/** A row is "live" (still holds the lock) when its expiry is in the
 *  future. Past-expiry rows are treated as free. */
function isLive(row: LockRow): boolean {
  return new Date(row.expires_at).getTime() > Date.now();
}

export const locksRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);

  // Access check shared by every write handler. Lock acquisition is
  // an edit intent → editor-or-above (viewers can't take the lock).
  // Build #5.123.1 replaced the legacy owner-only check.

  // Name lookup for the notification-email subject lines. Pulls just
  // the column the templates need and is tolerant of a missing row
  // (caller falls back to the project id). Email is fire-and-forget;
  // a slow GET here would briefly hold the route open but the route
  // already returned 200 to the client before we await, so it doesn't
  // affect latency the user sees.
  async function loadProjectNameOrFallback(projectId: string): Promise<string> {
    try {
      const { data } = await supabaseAdmin
        .from("projects")
        .select("name")
        .eq("id", projectId)
        .maybeSingle();
      const name = (data as { name?: string } | null)?.name;
      return name && name.length > 0 ? name : projectId;
    } catch {
      return projectId;
    }
  }

  // -----------------------------------------------------------------
  // GET /v1/projects/:id/lock — current lock state (or null when free)
  //
  // Query: `?clientSession=<uuid>` — optional. Web sends its per-tab
  // sessionStorage UUID so the response can carry `heldByYou` (see
  // shared `GetLockResponse`) and the hook can distinguish
  // same-tab (resume) from another-tab (gentle re-acquire) from
  // someone-else (read-only). The bug fix for self-lock on back-nav
  // return lives here (Build #5.120.1).
  // -----------------------------------------------------------------
  app.get<{
    Params: { id: string };
    Querystring: { clientSession?: string };
    Reply: GetLockResponse | ApiError;
  }>("/v1/projects/:id/lock", async (request, reply) => {
    const projectId = request.params.id;
    const callerSession = request.query.clientSession ?? null;
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
      return { lock: null, heldByYou: null };
    }
    const row = data as LockRow;
    return {
      lock: rowToLock(row),
      heldByYou: heldByYou(row, request.user.id, callerSession),
    };
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
      await assertProjectAccess(request.user.id, projectId, "editor");
    } catch (err) {
      if (sendAccessError(reply, err)) return;
      request.log.error({ err, projectId }, "lock acquire — access check failed");
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
          client_session: parsed.data.clientSession ?? null,
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

    // Courtesy email to the previous holder when we just picked up
    // an expired lock that belonged to someone else (Build #5.61.1).
    // No-ops cleanly when email isn't configured. Fire-and-forget so
    // the route returns immediately — the user shouldn't wait on a
    // hosted SMTP relay.
    if (
      existing &&
      !isLive(existing as LockRow) &&
      (existing as LockRow).user_id !== request.user.id &&
      (existing as LockRow).user_email
    ) {
      const previousHolderEmail = (existing as LockRow).user_email;
      const newHolderEmail = request.user.email ?? "(unknown)";
      void (async () => {
        const projectName = await loadProjectNameOrFallback(projectId);
        const email = lockExpiredTakenOverEmail({
          projectId,
          projectName,
          webBaseUrl: env.WEB_BASE_URL ?? "",
          newHolderEmail,
        });
        await sendEmail({ ...email, to: previousHolderEmail });
      })();
    }

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
  //
  // Scoped to the caller's per-tab session when one is provided
  // (Build #5.120.1) so closing tab A doesn't free tab B's lock.
  // Without a session token, falls back to "any of my rows" — same
  // behaviour as today for iOS and old web binaries.
  // -----------------------------------------------------------------
  app.delete<{
    Params: { id: string };
    Querystring: { clientSession?: string };
    Reply: { ok: true } | ApiError;
  }>("/v1/projects/:id/lock", async (request, reply) => {
    const projectId = request.params.id;
    const callerSession = request.query.clientSession;
    let query = supabaseAdmin
      .from("project_locks")
      .delete()
      .eq("project_id", projectId)
      .eq("user_id", request.user.id);
    if (callerSession) {
      query = query.eq("client_session", callerSession);
    }
    const { error } = await query;
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
  // POST /v1/projects/:id/lock/release — beacon-friendly release
  //
  // `navigator.sendBeacon` (used on `pagehide` to free the lock when
  // the user closes the tab) can only POST, not DELETE. This route
  // accepts a JSON body with `clientSession` and behaves identically
  // to the scoped DELETE above. Build #5.120.1.
  // -----------------------------------------------------------------
  app.post<{
    Params: { id: string };
    Body: unknown;
    Reply: { ok: true } | ApiError;
  }>("/v1/projects/:id/lock/release", async (request, reply) => {
    const projectId = request.params.id;
    const parsed = ReleaseBodySchema.safeParse(request.body ?? {});
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }
    const callerSession = parsed.data.clientSession;
    let query = supabaseAdmin
      .from("project_locks")
      .delete()
      .eq("project_id", projectId)
      .eq("user_id", request.user.id);
    if (callerSession) {
      query = query.eq("client_session", callerSession);
    }
    const { error } = await query;
    if (error) {
      request.log.error({ err: error, projectId }, "lock release (beacon) failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    request.log.info(
      { projectId, userId: request.user.id, beacon: true },
      "lock released"
    );
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

    // Capture the prior holder's email before we delete, so the
    // Build #5.61.1 notification has somewhere to send. Errors here
    // don't fail the route — the user did request "force release,"
    // they get it; we just lose the email.
    let priorHolderEmail: string | null = null;
    let priorHolderUserId: string | null = null;
    try {
      const { data: existing } = await supabaseAdmin
        .from("project_locks")
        .select("user_id, user_email, expires_at")
        .eq("project_id", projectId)
        .maybeSingle();
      if (
        existing &&
        isLive(existing as LockRow) &&
        (existing as LockRow).user_id !== request.user.id
      ) {
        priorHolderEmail = (existing as LockRow).user_email ?? null;
        priorHolderUserId = (existing as LockRow).user_id;
      }
    } catch (err) {
      request.log.warn(
        { err, projectId },
        "lock force — could not read prior holder for notification"
      );
    }

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
      {
        projectId,
        forcedBy: request.user.id,
        priorHolderUserId,
      },
      "lock force-released"
    );

    // Notify the previous holder that their lock was taken
    // (Build #5.61.1). No-ops when email isn't configured. Fire and
    // forget — don't make the actor wait on email delivery.
    if (priorHolderEmail) {
      const actorEmail = request.user.email ?? "(unknown)";
      void (async () => {
        const projectName = await loadProjectNameOrFallback(projectId);
        const email = lockForceReleasedEmail({
          projectId,
          projectName,
          webBaseUrl: env.WEB_BASE_URL ?? "",
          actorEmail,
        });
        await sendEmail({ ...email, to: priorHolderEmail });
      })();
    }

    return { ok: true };
  });
};
