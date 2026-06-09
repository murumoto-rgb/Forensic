/**
 * Admin / team management API (Build #5.124.1).
 *
 *   GET    /v1/admin/users
 *   POST   /v1/admin/users/invite
 *   PATCH  /v1/admin/users/:id
 *   DELETE /v1/admin/users/:id
 *   PUT    /v1/admin/projects/:projectId/members
 *
 * All routes here are admin-only (`authPlugin` + `requireAdmin`).
 * The plugin shape guarantees no admin route can ever land without
 * the gate, even if a future handler forgets the assertion.
 */

import type { FastifyPluginAsync } from "fastify";
import {
  InviteUserSchema,
  PatchUserSchema,
  SetProjectMembersSchema,
  type AdminUser,
  type AdminUserAssignment,
  type ApiError,
  type InviteUserResponse,
  type ListAdminUsersResponse,
  type PatchUserResponse,
  type ProjectMemberAssignment,
  type SetProjectMembersResponse,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin, requireAdmin } from "../middleware/auth.js";
import { env } from "../env.js";

interface ProfileRow {
  id: string;
  email: string;
  display_name: string | null;
  is_admin: boolean;
  created_at: string;
}

interface MemberRow {
  project_id: string;
  user_id: string;
  role: "editor" | "viewer";
}

interface ProjectRow {
  id: string;
  name: string;
  owner_id: string;
}

/** Build the AdminUser DTO for one profile. Pulls assignments from
 *  the precomputed member-by-user / project-name maps so this stays
 *  O(1) per user. */
function buildAdminUser(
  p: ProfileRow,
  assignmentsForUser: AdminUserAssignment[],
  lastSignInAt: string | null
): AdminUser {
  return {
    id: p.id,
    email: p.email,
    displayName: p.display_name,
    isAdmin: p.is_admin === true,
    createdAt: p.created_at,
    // "Invited (pending)" heuristic: profile exists but the user has
    // never signed in (last_sign_in_at is null). After their first
    // sign-in they can set display_name; the badge clears.
    pending: lastSignInAt === null,
    assignments: assignmentsForUser,
  };
}

/** Re-fetch + assemble a single AdminUser by id. Used by the
 *  invite / patch handlers so the response carries the fresh row. */
async function loadAdminUser(userId: string): Promise<AdminUser | null> {
  const { data: profile, error: profErr } = await supabaseAdmin
    .from("profiles")
    .select("id, email, display_name, is_admin, created_at")
    .eq("id", userId)
    .maybeSingle();
  if (profErr) throw profErr;
  if (!profile) return null;
  const p = profile as ProfileRow;

  const { data: memberRows, error: memberErr } = await supabaseAdmin
    .from("project_members")
    .select("project_id, role")
    .eq("user_id", userId);
  if (memberErr) throw memberErr;

  let assignments: AdminUserAssignment[] = [];
  if ((memberRows ?? []).length > 0) {
    const projectIds = (memberRows as { project_id: string; role: "editor" | "viewer" }[]).map(
      (r) => r.project_id
    );
    const { data: projectRows, error: projectErr } = await supabaseAdmin
      .from("projects")
      .select("id, name")
      .in("id", projectIds);
    if (projectErr) throw projectErr;
    const nameById = new Map(
      (projectRows ?? []).map((r) => [r.id as string, r.name as string])
    );
    assignments = (memberRows as { project_id: string; role: "editor" | "viewer" }[]).map(
      (m) => ({
        projectId: m.project_id,
        projectName: nameById.get(m.project_id) ?? m.project_id,
        role: m.role,
      })
    );
  }

  // Supabase Auth admin API for last_sign_in_at.
  let lastSignInAt: string | null = null;
  try {
    const { data: authData } = await supabaseAdmin.auth.admin.getUserById(userId);
    lastSignInAt = (authData?.user?.last_sign_in_at as string | null) ?? null;
  } catch {
    // Best-effort — if the admin call fails, treat as not pending
    // rather than block the response.
    lastSignInAt = "(unknown)";
  }

  return buildAdminUser(p, assignments, lastSignInAt);
}

export const adminRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);
  app.addHook("preHandler", requireAdmin);

  // ---------------------------------------------------------------
  // GET /v1/admin/users — list every user with their org role +
  // per-project assignments.
  // ---------------------------------------------------------------
  app.get<{ Reply: ListAdminUsersResponse | ApiError }>(
    "/v1/admin/users",
    async (request, reply) => {
      const { data: profiles, error: profErr } = await supabaseAdmin
        .from("profiles")
        .select("id, email, display_name, is_admin, created_at")
        .order("email");
      if (profErr) {
        request.log.error({ err: profErr }, "admin users list — profiles read failed");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }

      const { data: members, error: memErr } = await supabaseAdmin
        .from("project_members")
        .select("project_id, user_id, role");
      if (memErr) {
        request.log.error({ err: memErr }, "admin users list — members read failed");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }

      const projectIds = Array.from(
        new Set((members ?? []).map((m) => (m as MemberRow).project_id))
      );
      let nameById = new Map<string, string>();
      if (projectIds.length > 0) {
        const { data: projects, error: projErr } = await supabaseAdmin
          .from("projects")
          .select("id, name")
          .in("id", projectIds);
        if (projErr) {
          request.log.error({ err: projErr }, "admin users list — projects read failed");
          reply.code(500).send({ error: "internal", message: "Database error" });
          return;
        }
        nameById = new Map(
          (projects ?? []).map((r) => [r.id as string, r.name as string])
        );
      }

      const assignmentsByUser = new Map<string, AdminUserAssignment[]>();
      for (const row of (members ?? []) as MemberRow[]) {
        const list = assignmentsByUser.get(row.user_id) ?? [];
        list.push({
          projectId: row.project_id,
          projectName: nameById.get(row.project_id) ?? row.project_id,
          role: row.role,
        });
        assignmentsByUser.set(row.user_id, list);
      }

      // Fetch every user's last_sign_in_at in one admin-API page
      // (default page size 50; for our scale that's plenty). Build a
      // map so the assembly loop stays O(N).
      const lastSignInByUser = new Map<string, string | null>();
      try {
        const { data } = await supabaseAdmin.auth.admin.listUsers({
          page: 1,
          perPage: 1000,
        });
        for (const u of data?.users ?? []) {
          lastSignInByUser.set(
            u.id as string,
            (u.last_sign_in_at as string | null) ?? null
          );
        }
      } catch (err) {
        request.log.warn(
          { err },
          "admin users list — auth.admin.listUsers failed; pending flag will be unreliable"
        );
      }

      const users: AdminUser[] = (profiles ?? []).map((row) =>
        buildAdminUser(
          row as ProfileRow,
          assignmentsByUser.get((row as ProfileRow).id) ?? [],
          lastSignInByUser.get((row as ProfileRow).id) ?? null
        )
      );

      return { users };
    }
  );

  // ---------------------------------------------------------------
  // POST /v1/admin/users/invite — invite a new user by email.
  //
  // Supabase Auth creates the auth.users row immediately; the
  // existing on_auth_user_created trigger creates the matching
  // profiles row. We also do a defensive idempotent upsert here in
  // case the trigger ever drifts.
  //
  // The user gets an email with a magic link to set their password
  // and complete sign-up.
  // ---------------------------------------------------------------
  app.post<{ Body: unknown; Reply: InviteUserResponse | ApiError }>(
    "/v1/admin/users/invite",
    async (request, reply) => {
      const parsed = InviteUserSchema.safeParse(request.body);
      if (!parsed.success) {
        reply.code(400).send({
          error: "bad_request",
          message: "Request body failed validation",
          details: parsed.error.issues,
        });
        return;
      }
      const { email } = parsed.data;

      let invitedUserId: string;
      try {
        const { data, error } = await supabaseAdmin.auth.admin.inviteUserByEmail(
          email,
          env.WEB_BASE_URL
            ? { redirectTo: env.WEB_BASE_URL }
            : undefined
        );
        if (error || !data?.user?.id) {
          // Supabase returns 422 for "already registered".
          if (error?.status === 422) {
            reply.code(409).send({
              error: "already_invited",
              message: `User ${email} is already registered.`,
            });
            return;
          }
          throw error ?? new Error("Invite returned no user id");
        }
        invitedUserId = data.user.id;
      } catch (err) {
        request.log.error({ err, email }, "admin invite — Supabase invite failed");
        reply.code(502).send({
          error: "invite_failed",
          message: "Supabase invite call failed.",
        });
        return;
      }

      // Defensive profiles upsert — the trigger usually does this but
      // we don't want to depend on event ordering.
      const { error: profUpsertErr } = await supabaseAdmin
        .from("profiles")
        .upsert(
          { id: invitedUserId, email },
          { onConflict: "id" }
        );
      if (profUpsertErr) {
        request.log.warn(
          { err: profUpsertErr, email, userId: invitedUserId },
          "admin invite — profile upsert failed (trigger may still cover this)"
        );
      }

      const user = await loadAdminUser(invitedUserId);
      if (!user) {
        reply.code(500).send({
          error: "internal",
          message: "Invite succeeded but user profile is missing.",
        });
        return;
      }
      reply.code(201);
      return { user };
    }
  );

  // ---------------------------------------------------------------
  // PATCH /v1/admin/users/:id — set the org-admin flag.
  //
  // Lockout guards:
  //   - Caller cannot self-demote when they're the last admin.
  //   - Cannot clear the last admin via this route at all (a sole
  //     admin demoting a different admin who is the last admin
  //     would otherwise leave the org with no admin).
  // ---------------------------------------------------------------
  app.patch<{
    Params: { id: string };
    Body: unknown;
    Reply: PatchUserResponse | ApiError;
  }>("/v1/admin/users/:id", async (request, reply) => {
    const targetId = request.params.id;
    const parsed = PatchUserSchema.safeParse(request.body);
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }
    const { isAdmin } = parsed.data;

    // Lockout check: if we're about to remove admin from the LAST
    // admin (whether that's the caller or another user), refuse.
    if (!isAdmin) {
      const { count, error: countErr } = await supabaseAdmin
        .from("profiles")
        .select("id", { count: "exact", head: true })
        .eq("is_admin", true);
      if (countErr) {
        request.log.error({ err: countErr }, "admin patch — admin count failed");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
      // We only need to refuse if the TARGET is currently admin AND
      // they're the last one. A non-admin target being PATCHed to
      // false is a no-op (still no admin lost).
      const { data: targetRow } = await supabaseAdmin
        .from("profiles")
        .select("is_admin")
        .eq("id", targetId)
        .maybeSingle();
      const targetIsAdmin = (targetRow as { is_admin: boolean } | null)?.is_admin === true;
      if (targetIsAdmin && (count ?? 0) <= 1) {
        reply.code(409).send({
          error: "last_admin",
          message: "Cannot remove the last org admin.",
        });
        return;
      }
    }

    const { error: updateErr } = await supabaseAdmin
      .from("profiles")
      .update({ is_admin: isAdmin })
      .eq("id", targetId);
    if (updateErr) {
      request.log.error({ err: updateErr, targetId }, "admin patch — update failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    const user = await loadAdminUser(targetId);
    if (!user) {
      reply.code(404).send({ error: "not_found", message: `User ${targetId} not found` });
      return;
    }
    return { user };
  });

  // ---------------------------------------------------------------
  // DELETE /v1/admin/users/:id — revoke all access; optionally
  // hard-delete the auth.users row when the user owns no projects.
  //
  // Guards:
  //   - Can't delete self.
  //   - Can't delete the last admin.
  //   - Can't delete a user who owns projects (409 with hint to
  //     reassign owner first; out of scope to auto-reassign).
  // ---------------------------------------------------------------
  app.delete<{
    Params: { id: string };
    Reply: ApiError | { ok: true };
  }>("/v1/admin/users/:id", async (request, reply) => {
    const targetId = request.params.id;

    if (targetId === request.user.id) {
      reply.code(409).send({
        error: "self_delete",
        message: "Cannot delete your own account.",
      });
      return;
    }

    // Owns projects? Refuse.
    const { count: ownedCount, error: ownErr } = await supabaseAdmin
      .from("projects")
      .select("id", { count: "exact", head: true })
      .eq("owner_id", targetId);
    if (ownErr) {
      request.log.error({ err: ownErr, targetId }, "admin delete — owned count failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    if ((ownedCount ?? 0) > 0) {
      reply.code(409).send({
        error: "owns_projects",
        message: `User owns ${ownedCount} project${(ownedCount ?? 0) === 1 ? "" : "s"}. Reassign ownership before deleting.`,
        details: { ownedCount },
      });
      return;
    }

    // Last admin?
    const { data: targetRow } = await supabaseAdmin
      .from("profiles")
      .select("is_admin")
      .eq("id", targetId)
      .maybeSingle();
    const targetIsAdmin = (targetRow as { is_admin: boolean } | null)?.is_admin === true;
    if (targetIsAdmin) {
      const { count: adminCount } = await supabaseAdmin
        .from("profiles")
        .select("id", { count: "exact", head: true })
        .eq("is_admin", true);
      if ((adminCount ?? 0) <= 1) {
        reply.code(409).send({
          error: "last_admin",
          message: "Cannot delete the last org admin.",
        });
        return;
      }
    }

    // Revoke all memberships first (DB cascade would do this on
    // auth.users delete too, but make it explicit so the audit log
    // is clean).
    const { error: revokeErr } = await supabaseAdmin
      .from("project_members")
      .delete()
      .eq("user_id", targetId);
    if (revokeErr) {
      request.log.error({ err: revokeErr, targetId }, "admin delete — revoke memberships failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    // Hard-delete the auth.users row. profiles cascades via FK.
    const { error: authDelErr } = await supabaseAdmin.auth.admin.deleteUser(targetId);
    if (authDelErr) {
      request.log.error({ err: authDelErr, targetId }, "admin delete — auth.deleteUser failed");
      reply.code(500).send({
        error: "delete_failed",
        message: "Supabase delete-user call failed.",
      });
      return;
    }

    return { ok: true };
  });

  // ---------------------------------------------------------------
  // PUT /v1/admin/projects/:projectId/members — replace the project's
  // member list. Owner is implicit and is never in this list; we
  // refuse to add them (no-op silently for simpler client UX).
  // ---------------------------------------------------------------
  app.put<{
    Params: { projectId: string };
    Body: unknown;
    Reply: SetProjectMembersResponse | ApiError;
  }>("/v1/admin/projects/:projectId/members", async (request, reply) => {
    const { projectId } = request.params;
    const parsed = SetProjectMembersSchema.safeParse(request.body);
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }

    // Confirm the project exists; fetch the owner_id so we can
    // exclude them.
    const { data: project, error: projErr } = await supabaseAdmin
      .from("projects")
      .select("id, owner_id")
      .eq("id", projectId)
      .maybeSingle();
    if (projErr) {
      request.log.error({ err: projErr, projectId }, "set members — project read failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    if (!project) {
      reply.code(404).send({ error: "not_found", message: `Project ${projectId} not found` });
      return;
    }
    const ownerId = (project as ProjectRow).owner_id;

    const requested: ProjectMemberAssignment[] = parsed.data.members.filter(
      (m) => m.userId !== ownerId
    );

    // Full-replace: drop the existing rows for this project, then
    // upsert the new set. The CASCADE on user delete keeps stale
    // user_ids from accumulating — Supabase's FK does the check on
    // upsert too (a non-existent user_id will 23503).
    const { error: delErr } = await supabaseAdmin
      .from("project_members")
      .delete()
      .eq("project_id", projectId);
    if (delErr) {
      request.log.error({ err: delErr, projectId }, "set members — delete existing failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    if (requested.length > 0) {
      const rows = requested.map((m) => ({
        project_id: projectId,
        user_id: m.userId,
        role: m.role,
        added_by: request.user.id,
      }));
      const { error: insErr } = await supabaseAdmin
        .from("project_members")
        .insert(rows);
      if (insErr) {
        request.log.error({ err: insErr, projectId }, "set members — insert failed");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
    }

    return { members: requested };
  });
};
