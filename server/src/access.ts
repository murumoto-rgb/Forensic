/**
 * Project access control (Phase 3, Build #5.123.1).
 *
 * One reusable helper — `assertProjectAccess(userId, projectId, minRole)`
 * — replaces the ~16 ad-hoc `.eq("owner_id", request.user.id)` checks
 * scattered across `projects.ts`, `photos.ts`, `plans.ts`, `locks.ts`,
 * `projectExports.ts`, `exports.ts`, `aiTag.ts`, and `files.ts`.
 *
 * Effective-role resolution order:
 *     admin  >  owner (implicit editor)  >  member.role  >  none
 *
 * Where:
 *   - **admin**  — `profiles.is_admin = true` (org-level, single team).
 *   - **owner**  — `projects.owner_id = userId` → implicit editor.
 *   - **member** — row in `project_members` with `role` either `editor`
 *                  or `viewer`.
 *
 * Behaviour on failure:
 *   - **404** when the project doesn't exist OR the caller has no
 *     relationship to it. This matches the existing "don't leak
 *     existence" pattern from `projects.ts` and avoids enumeration
 *     attacks.
 *   - **403** when the caller has SOME access but below `minRole`
 *     (e.g. a Viewer hitting a write path).
 *
 * Throws a typed `AccessError`. Route handlers catch it and forward to
 * `sendAccessError(reply, err)`.
 */

import type { FastifyReply, FastifyRequest } from "fastify";
import { supabaseAdmin } from "./supabase.js";

export type ProjectRole = "admin" | "editor" | "viewer";

/**
 * Per-request memoization (Build #6.14.1).
 *
 * `isOrgAdmin` runs an indexed point lookup on `profiles.is_admin`,
 * which is cheap individually but called multiple times on the same
 * request hot path: `assertProjectAccess` already calls it once, and
 * routes that need elevated-role gating (freeze flip, force-release,
 * admin endpoints) call it a second time. With Render-free-tier round
 * trips, the second call adds latency for no fresh information — the
 * caller's admin status doesn't change mid-request.
 *
 * Pattern: stash a `cache` Map on the FastifyRequest (Fastify allows
 * decorating but a per-call assertion works without registering at
 * boot). `isOrgAdmin(userId, request)` consults it first; existing
 * call sites that don't pass `request` keep working unchanged.
 */
type RequestAccessCache = { orgAdmin?: boolean };

function getRequestCache(req: FastifyRequest): RequestAccessCache {
  const r = req as FastifyRequest & { __access?: RequestAccessCache };
  if (!r.__access) r.__access = {};
  return r.__access;
}

export class AccessError extends Error {
  constructor(
    public readonly status: 403 | 404,
    public readonly code: "not_found" | "forbidden",
    message: string
  ) {
    super(message);
    this.name = "AccessError";
  }
}

export class FrozenProjectError extends Error {
  readonly status = 409 as const;
  readonly code = "project_frozen" as const;

  constructor(message = "Project is finalized. An owner or admin must unlock it before editing.") {
    super(message);
    this.name = "FrozenProjectError";
  }
}

const RANK: Record<ProjectRole, number> = {
  viewer: 1,
  editor: 2,
  admin: 3,
};

/**
 * Resolve the caller's effective role on a project, or throw an
 * `AccessError`. Returns the role on success.
 *
 * Up to two reads against the DB (admin check + owner-or-member
 * resolution); both are point queries on indexed columns. When called
 * with the FastifyRequest, the admin check is memoized for the
 * remainder of the request (Build #6.14.1) — subsequent calls to
 * `isOrgAdmin(uid, request)` (e.g. for the freeze-flip elevated-role
 * gate) reuse the cached answer.
 */
export async function assertProjectAccess(
  userId: string,
  projectId: string,
  minRole: ProjectRole,
  request?: FastifyRequest
): Promise<ProjectRole> {
  // 1) Org Admin — bypass everything.
  if (await isOrgAdmin(userId, request)) return "admin";

  // 2) Owner-or-member, resolved together via two cheap point lookups.
  const { data: proj, error: projErr } = await supabaseAdmin
    .from("projects")
    .select("owner_id")
    .eq("id", projectId)
    .maybeSingle();
  if (projErr) throw projErr;
  if (!proj) {
    throw new AccessError(404, "not_found", `Project ${projectId} not found`);
  }

  let role: ProjectRole | null = null;
  if (proj.owner_id === userId) {
    role = "editor"; // owner = implicit editor
  } else {
    const { data: m, error: mErr } = await supabaseAdmin
      .from("project_members")
      .select("role")
      .eq("project_id", projectId)
      .eq("user_id", userId)
      .maybeSingle();
    if (mErr) throw mErr;
    if (m) role = (m.role as ProjectRole) ?? null;
  }

  if (role === null) {
    // No relationship — 404 to avoid leaking project existence.
    throw new AccessError(404, "not_found", `Project ${projectId} not found`);
  }

  if (RANK[role] < RANK[minRole]) {
    throw new AccessError(403, "forbidden", "You don't have edit access to this project.");
  }
  return role;
}

/** Light-weight existence check used by `requireAdmin` and by
 *  callers that need to surface org-admin UI affordances.
 *
 *  When called with the FastifyRequest, the answer is memoized for
 *  the remainder of that request (Build #6.14.1) — repeated calls
 *  hit the cached boolean instead of re-querying `profiles`. */
export async function isOrgAdmin(
  userId: string,
  request?: FastifyRequest
): Promise<boolean> {
  if (request) {
    const cache = getRequestCache(request);
    if (cache.orgAdmin !== undefined) return cache.orgAdmin;
  }
  const { data, error } = await supabaseAdmin
    .from("profiles")
    .select("is_admin")
    .eq("id", userId)
    .maybeSingle();
  if (error) throw error;
  const result = data?.is_admin === true;
  if (request) getRequestCache(request).orgAdmin = result;
  return result;
}

/** Returns true when `userId` is the literal `projects.owner_id`. Used
 *  for the rare gates that need to distinguish owner from member-
 *  editor (e.g. flipping `isFrozen` on the project — only Owner or
 *  Admin can). */
export async function isProjectOwner(
  userId: string,
  projectId: string
): Promise<boolean> {
  const { data, error } = await supabaseAdmin
    .from("projects")
    .select("owner_id")
    .eq("id", projectId)
    .maybeSingle();
  if (error) throw error;
  return data?.owner_id === userId;
}

/** Translate an `AccessError` into a Fastify reply. Returns true when
 *  the error was handled (so callers can early-return). Returns false
 *  on other error types so they can be re-thrown for the generic 500
 *  handler. */
export function sendAccessError(reply: FastifyReply, err: unknown): boolean {
  if (err instanceof AccessError) {
    reply.code(err.status).send({ error: err.code, message: err.message });
    return true;
  }
  if (err instanceof FrozenProjectError) {
    reply.code(err.status).send({ error: err.code, message: err.message });
    return true;
  }
  return false;
}

/** Require editor access and reject edits to an existing finalized project. */
export async function assertProjectMutable(
  userId: string,
  projectId: string,
  request?: FastifyRequest
): Promise<ProjectRole> {
  const role = await assertProjectAccess(userId, projectId, "editor", request);
  const { data, error } = await supabaseAdmin
    .from("projects")
    .select("manifest")
    .eq("id", projectId)
    .maybeSingle();
  if (error) throw error;
  if ((data?.manifest as { isFrozen?: boolean } | null)?.isFrozen === true) {
    throw new FrozenProjectError();
  }
  return role;
}
