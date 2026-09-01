/**
 * Manifest CRUD endpoints. All routes here are behind the auth
 * middleware (registered at plugin level) and operate on the
 * `public.projects` table.
 *
 *   GET    /v1/projects          → list calling user's projects
 *   GET    /v1/projects/:id      → fetch one (404 if not owned)
 *   PUT    /v1/projects/:id      → create or update one; optimistic
 *                                  concurrency via `expectedRevision`
 *
 * All writes go through the Supabase admin client (bypasses RLS).
 * Per-user authorization is enforced at the app layer by including
 * `eq("owner_id", request.user.id)` in every query.
 */

import type { FastifyPluginAsync } from "fastify";
import { isDeepStrictEqual } from "node:util";
import { z } from "zod";
import {
  ProjectSchema,
  mergeManifest,
  type GetManifestResponse,
  type Project,
  type ProjectRole,
  type PutManifestResponse,
  type ApiError,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";
import { deleteObjects } from "../r2.js";
import { saveProject, sendTransactionError, clientSession } from "../projectTransactions.js";
import {
  assertProjectAccess,
  isOrgAdmin,
  isProjectOwner,
  sendAccessError,
} from "../access.js";

function hasFrozenContentChange(current: Project, incoming: Project): boolean {
  const withoutFreeze = (value: Project) => {
    const normalized = ProjectSchema.safeParse(value).success
      ? ProjectSchema.parse(value)
      : value;
    const copy = structuredClone(normalized) as Project & { isFrozen?: boolean };
    copy.isFrozen = true;
    return copy;
  };
  return !isDeepStrictEqual(withoutFreeze(current), withoutFreeze(incoming));
}

const PutBodySchema = z.object({
  project: ProjectSchema,
  // `null` on first create; previous revision on every subsequent
  // PUT. Server rejects mismatches with 409 on the legacy path. On
  // the merge path it's advisory (the merge handles concurrency).
  expectedRevision: z.string().nullable(),
  // Cloud-first 3-way merge (Build #5.117.1). When present, the
  // server merges `(baseManifest, current, project)` against current
  // truth and returns the merged manifest in the response so the
  // client can adopt it. When absent, the legacy optimistic-
  // concurrency path runs (back-compat for un-upgraded clients).
  baseManifest: ProjectSchema.optional(),
});

/** Compare-and-swap retry budget on the merge path. Two concurrent
 *  writers landing in sequence is the common case (1 retry); 3 is a
 *  safe ceiling for occasional storms. Merge is idempotent so retries
 *  never duplicate work. */
const MERGE_CAS_RETRIES = 3;

interface ProjectListItem {
  id: string;
  name: string;
  manifestSchemaVersion: number;
  revision: string;
  createdAt: string;
  updatedAt: string;
  /** Caller's effective role on this project (Build #5.123.1). */
  role?: ProjectRole;
}

interface ProjectListResponse {
  projects: ProjectListItem[];
}

export const projectsRoute: FastifyPluginAsync = async (app) => {
  // All routes below the auth plugin require a valid JWT.
  await app.register(authPlugin);

  // -----------------------------------------------------------------
  // GET /v1/projects — list calling user's projects.
  // Returns the metadata columns only (no manifest blob) so the
  // project-list view loads quickly on slow connections.
  // Filters out soft-deleted projects (iOS sets `isDeleted=true` on
  // the manifest when the user trashes a project; we read that
  // straight from the JSONB so there's no extra writer to keep in
  // sync). The default `.or` clause keeps projects whose manifest
  // never carried the field (older clients pre-isDeleted) as well
  // as those that explicitly set it to false.
  //
  // Query parameter `?trashed=true` flips the filter so the trashed
  // projects section on the web list page can fetch its set. Old
  // clients omit it; behaviour unchanged for them.
  // -----------------------------------------------------------------
  app.get<{
    Querystring: { trashed?: string };
    Reply: ProjectListResponse | ApiError;
  }>("/v1/projects", async (request, reply) => {
    const trashed = request.query.trashed === "true";
    const uid = request.user.id;

    // Phase 3 (Build #5.123.1): the list is the union of
    //   (admin: every project) OR
    //   (non-admin: owned + member-projects).
    // We run the query against `projects` once with the appropriate
    // id-set filter rather than two queries + JS merge — keeps the
    // sort + isDeleted filter on the database side.
    const callerIsAdmin = await isOrgAdmin(uid, request);

    let query = supabaseAdmin
      .from("projects")
      .select("id, owner_id, name, manifest_schema_version, revision, created_at, updated_at")
      .order("updated_at", { ascending: false });

    if (!callerIsAdmin) {
      // Member project IDs first — `.in()` payload is bounded by the
      // user's assignment count (typically tiny).
      const { data: memberRows, error: memberErr } = await supabaseAdmin
        .from("project_members")
        .select("project_id, role")
        .eq("user_id", uid);
      if (memberErr) {
        request.log.error({ err: memberErr }, "Failed to list member projects");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
      const memberIds = (memberRows ?? []).map((r) => r.project_id as string);
      if (memberIds.length === 0) {
        query = query.eq("owner_id", uid);
      } else {
        // Comma-separated IN for the `or` filter so we OR
        // `owner_id = uid` with `id in (memberIds)`.
        const inList = memberIds.map((id) => `"${id}"`).join(",");
        query = query.or(`owner_id.eq.${uid},id.in.(${inList})`);
      }
    }

    if (trashed) {
      query = query.eq("manifest->>isDeleted", "true");
    } else {
      query = query.or("manifest->>isDeleted.is.null,manifest->>isDeleted.eq.false");
    }

    const { data, error } = await query;

    if (error) {
      request.log.error({ err: error }, "Failed to list projects");
      reply.code(500).send({ error: "internal", message: "Database error" } satisfies ApiError);
      return;
    }

    // Build the per-user member-role lookup once so we can stamp each
    // row's `role` without an N+1 query.
    let memberRoleByProject = new Map<string, ProjectRole>();
    if (!callerIsAdmin) {
      const { data: roleRows } = await supabaseAdmin
        .from("project_members")
        .select("project_id, role")
        .eq("user_id", uid);
      memberRoleByProject = new Map(
        (roleRows ?? []).map((r) => [
          r.project_id as string,
          (r.role as ProjectRole) ?? "viewer",
        ])
      );
    }

    const projects: ProjectListItem[] = (data ?? []).map((row) => {
      const ownerId = row.owner_id as string;
      let role: ProjectRole;
      if (callerIsAdmin) role = "admin";
      else if (ownerId === uid) role = "editor"; // owner = implicit editor
      else role = memberRoleByProject.get(row.id as string) ?? "viewer";
      return {
        id: row.id as string,
        name: row.name as string,
        manifestSchemaVersion: row.manifest_schema_version as number,
        revision: row.revision as string,
        createdAt: row.created_at as string,
        updatedAt: row.updated_at as string,
        role,
      };
    });
    return { projects };
  });

  // -----------------------------------------------------------------
  // GET /v1/projects/:id — fetch one project's full manifest.
  // 404 if the row doesn't exist or isn't owned by the caller.
  // -----------------------------------------------------------------
  app.get<{ Params: { id: string }; Reply: GetManifestResponse | ApiError }>(
    "/v1/projects/:id",
    async (request, reply) => {
      const { id } = request.params;

      // viewer is the lowest read role. assertProjectAccess throws
      // 404 on no-relationship (don't leak existence) and 403 on
      // insufficient role (can't happen at viewer minRole; included
      // for symmetry with write paths).
      let role: ProjectRole;
      try {
        role = await assertProjectAccess(request.user.id, id, "viewer", request);
      } catch (err) {
        if (sendAccessError(reply, err)) return;
        request.log.error({ err, projectId: id }, "Failed to check project access");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }

      const { data, error } = await supabaseAdmin
        .from("projects")
        .select("manifest, revision, owner_id")
        .eq("id", id)
        .maybeSingle();

      if (error) {
        request.log.error({ err: error, projectId: id }, "Failed to fetch project");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
      if (!data) {
        reply.code(404).send({ error: "not_found", message: `Project ${id} not found` });
        return;
      }

      const manifest = data.manifest as unknown as GetManifestResponse["project"] & {
        isDeleted?: boolean;
      };

      if (manifest.isDeleted === true) {
        reply.code(404).send({ error: "not_found", message: `Project ${id} not found` });
        return;
      }

      return {
        project: manifest,
        revision: data.revision as string,
        role,
        isOwner: data.owner_id === request.user.id,
      };
    }
  );

  // -----------------------------------------------------------------
  // PUT /v1/projects/:id — create or update a project.
  //
  // Body shape: `{ project: Project, expectedRevision: string | null }`.
  //   * expectedRevision === null → create; 409 if a row already
  //     exists for this id (caller must use a fresh UUID).
  //   * expectedRevision === "<old>" → update; 409 if the stored
  //     revision doesn't match (someone else wrote in the meantime).
  //
  // Server generates a new revision (random UUID) on every write
  // and returns it in the response. Clients echo it on the next PUT.
  // -----------------------------------------------------------------
  app.put<{
    Params: { id: string };
    Body: unknown;
    Reply: PutManifestResponse | ApiError;
  }>("/v1/projects/:id", async (request, reply) => {
    const { id } = request.params;

    const parsed = PutBodySchema.safeParse(request.body);
    if (!parsed.success) {
      // Surface the specific zod issues to Render's logs so we can
      // debug client/server schema drift. Without this, all the
      // client sees is "Request body failed validation" with no
      // pointer to which field. iOS / web clients still get the
      // `details` array in the response body — this log just makes
      // it visible to engineering operators too.
      request.log.warn(
        {
          projectId: id,
          issues: parsed.error.issues,
        },
        "PUT /v1/projects/:id zod validation failed"
      );
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }
    const { project, expectedRevision, baseManifest } = parsed.data;

    // An older iOS codec can retain manifestSchemaVersion=4 while dropping
    // fields it does not know. Inspect the raw payload before Zod defaults
    // turn those omitted fields into empty arrays.
    const rawProject = (request.body as { project: Record<string, unknown> }).project;
    const preservesWorkflowFields = Array.isArray(rawProject.inspectionChecklist)
      && Array.isArray(rawProject.inspectionSessions);
    const rejectLegacyWrite = (current: Project): boolean => {
      if (current.manifestSchemaVersion < 4 || (project.manifestSchemaVersion >= 4 && preservesWorkflowFields)) return false;
      reply.code(426).send({ error: "upgrade_required", message: "Update the app before editing this project. Schema v4 workflow fields must be preserved." });
      return true;
    };

    // The URL identifies the project. The body's project.id must
    // agree or it's a client bug. Compared case-insensitively
    // because RFC 4122 doesn't mandate a UUID-string case
    // convention — Swift's `UUID.uuidString` is uppercase while
    // the iOS APIClient lowercases the URL segment. Both
    // representations refer to the same UUID; rejecting one for
    // the other is a server-side mistake.
    if (project.id.toLowerCase() !== id.toLowerCase()) {
      reply.code(400).send({
        error: "bad_request",
        message: `URL :id (${id}) does not match body project.id (${project.id})`,
      });
      return;
    }

    // Refuse unknown schemas before persisting a zod-normalized payload: accepting
    // them could silently discard fields this server does not understand.
    const { MANIFEST_SCHEMA_VERSION } = await import("@forensic/shared");
    if (project.manifestSchemaVersion > MANIFEST_SCHEMA_VERSION) {
      reply.code(409).send({ error: "manifest_schema_unsupported", message: "Server update required before this manifest can be saved." });
      return;
    }

    // ---------------------------------------------------------------
    // Merge path (cloud-first, Build #5.117.1)
    // ---------------------------------------------------------------
    // When the client provides `baseManifest`, run a 3-way merge
    // against current truth + compare-and-swap update so concurrent
    // writers from web and iOS no longer clobber each other. The
    // merge is idempotent, so retrying on a CAS miss is safe and
    // converges.
    if (baseManifest !== undefined) {
      // Verify caller has editor-or-above on this project once, up
      // front. We re-check inside the loop only via the CAS guard
      // (which protects against revision races, not access changes).
      let updateAccessChecked = false;

      for (let attempt = 0; attempt < MERGE_CAS_RETRIES; attempt++) {
        const { data: existing, error: fetchError } = await supabaseAdmin
          .from("projects")
          .select("manifest, revision, owner_id")
          .eq("id", id)
          .maybeSingle();
        if (fetchError) {
          request.log.error(
            { err: fetchError, projectId: id },
            "Failed to fetch project for merge PUT"
          );
          reply.code(500).send({ error: "internal", message: "Database error" });
          return;
        }

        if (!existing) {
          const revision = crypto.randomUUID();
          const result = await saveProject(request, id, expectedRevision, revision, project);
          if (sendTransactionError(reply, result)) return;
          return { revision, project };
        }

        if (!updateAccessChecked) {
          try {
            await assertProjectAccess(request.user.id, id, "editor", request);
          } catch (err) {
            if (sendAccessError(reply, err)) return;
            throw err;
          }
          updateAccessChecked = true;
        }

        const serverCurrent = existing.manifest as unknown as Project;
        if (rejectLegacyWrite(serverCurrent)) return;

        if ((serverCurrent.isFrozen ?? false) && hasFrozenContentChange(serverCurrent, project)) {
          reply.code(409).send({
            error: "project_frozen",
            message: "Project is finalized. An owner or admin must unlock it before editing.",
          });
          return;
        }

        // Phase 4 (Build #5.126.1): flipping `isFrozen` requires
        // Owner OR Admin. assertProjectAccess(..., "editor") already
        // ran above for any save, so we only need the extra check
        // when the flag is actually changing.
        if ((serverCurrent.isFrozen ?? false) !== (project.isFrozen ?? false)) {
          // Build #6.14.1: pass `request` so the admin check reuses
          // the cached value `assertProjectAccess` populated above.
          const allowed =
            (await isOrgAdmin(request.user.id, request)) ||
            (await isProjectOwner(request.user.id, id));
          if (!allowed) {
            reply.code(403).send({
              error: "forbidden",
              message: "Only an owner or admin can lock or unlock a project.",
            });
            return;
          }
        }

        const { merged, report } = mergeManifest(baseManifest, serverCurrent, project);
        if (report.conflicts.length > 0) {
          // Audit observability — never blocks the write.
          request.log.info(
            {
              projectId: id,
              userId: request.user.id,
              conflictCount: report.conflicts.length,
              conflicts: report.conflicts,
            },
            "manifest merge forced winners"
          );
        }

        const newRevision = crypto.randomUUID();
        const expectedServerRev = existing.revision as string;

        // Compare-and-swap: only update if the row's revision is
        // still the one we just merged against. If another writer
        // raced us, rowCount comes back 0 and we loop.
        const result = await saveProject(request, id, expectedServerRev, newRevision, merged);
        if (result.error && result.error !== "revision_mismatch") {
          sendTransactionError(reply, result); return;
        }
        if (result.ok) {
          if (attempt > 0) {
            request.log.info(
              { projectId: id, attempts: attempt + 1 },
              "merge CAS converged after retry"
            );
          }
          return { revision: newRevision, project: merged };
        }
        // CAS miss → another writer landed first; loop and re-merge
        // against the new server state.
        request.log.info(
          { projectId: id, attempt: attempt + 1 },
          "merge CAS miss; retrying"
        );
      }
      // Exhausted retries (extremely rare — three concurrent writers
      // in flight at once). Degrade to a generic 409 so the client
      // re-syncs and tries again on the next save tick.
      request.log.warn(
        { projectId: id, retries: MERGE_CAS_RETRIES },
        "merge CAS retries exhausted"
      );
      reply.code(409).send({
        error: "merge_cas_exhausted",
        message: "Project was modified repeatedly during merge. Retry.",
      });
      return;
    }

    // ---------------------------------------------------------------
    // Legacy optimistic-concurrency path (no baseManifest)
    // ---------------------------------------------------------------
    const { data: existing, error: fetchError } = await supabaseAdmin
      .from("projects")
      .select("revision, owner_id, manifest")
      .eq("id", id)
      .maybeSingle();

    if (fetchError) {
      request.log.error({ err: fetchError, projectId: id }, "Failed to fetch project for PUT");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    if (existing) {
      // Updating an existing row: caller must be editor-or-above
      // (owner, admin, or member-editor), and the revision must match.
      try {
        await assertProjectAccess(request.user.id, id, "editor", request);
      } catch (err) {
        if (sendAccessError(reply, err)) return;
        throw err;
      }

      // Phase 4 (Build #5.126.1): flipping `isFrozen` requires Owner
      // OR Admin on the legacy path too.
      const existingManifest = existing.manifest as unknown as Project;
      if (rejectLegacyWrite(existingManifest)) return;
      if ((existingManifest.isFrozen ?? false) && hasFrozenContentChange(existingManifest, project)) {
        reply.code(409).send({
          error: "project_frozen",
          message: "Project is finalized. An owner or admin must unlock it before editing.",
        });
        return;
      }
      if ((existingManifest.isFrozen ?? false) !== (project.isFrozen ?? false)) {
        // Build #6.14.1: pass `request` so the admin check reuses
        // the cached value `assertProjectAccess` populated above.
        const allowed =
          (await isOrgAdmin(request.user.id, request)) ||
          (await isProjectOwner(request.user.id, id));
        if (!allowed) {
          reply.code(403).send({
            error: "forbidden",
            message: "Only an owner or admin can lock or unlock a project.",
          });
          return;
        }
      }

      if (expectedRevision !== existing.revision) {
        reply.code(409).send({
          error: "revision_mismatch",
          message: `Project has been modified by someone else. Refetch and retry.`,
          details: { serverRevision: existing.revision },
        });
        return;
      }
    } else {
      // Creating a new row: caller must declare so via null
      // expectedRevision.
      if (expectedRevision !== null) {
        reply.code(409).send({
          error: "revision_mismatch",
          message: "Project does not exist; expectedRevision must be null.",
        });
        return;
      }
    }

    // Server-controlled revision. crypto.randomUUID is available on
    // Node 22 without an import.
    const newRevision = crypto.randomUUID();

    const result = await saveProject(request, id, expectedRevision, newRevision, project);
    if (sendTransactionError(reply, result)) return;

    return { revision: newRevision };
  });

  // Explicit unlock action. Content edits cannot be bundled with an unlock;
  // callers must send a pure PUT flag change or use this endpoint.
  app.post<{
    Params: { id: string };
    Reply: PutManifestResponse | ApiError;
  }>("/v1/projects/:id/unlock", async (request, reply) => {
    const { id } = request.params;
    try {
      const allowed =
        (await isOrgAdmin(request.user.id, request)) ||
        (await isProjectOwner(request.user.id, id));
      if (!allowed) {
        reply.code(403).send({
          error: "forbidden",
          message: "Only an owner or admin can unlock a project.",
        });
        return;
      }
      const { data: row, error: readError } = await supabaseAdmin
        .from("projects")
        .select("manifest, revision")
        .eq("id", id)
        .maybeSingle();
      if (readError) throw readError;
      if (!row) {
        reply.code(404).send({ error: "not_found", message: `Project ${id} not found` });
        return;
      }
      const manifest = row.manifest as Project;
      if (manifest.isFrozen !== true) return { revision: row.revision as string };
      const newRevision = crypto.randomUUID();
      const result = await saveProject(request, id, row.revision as string, newRevision, { ...manifest, isFrozen: false });
      if (sendTransactionError(reply, result)) return;
      return { revision: newRevision };
    } catch (err) {
      if (sendAccessError(reply, err)) return;
      request.log.error({ err, projectId: id }, "Failed to unlock project");
      reply.code(500).send({ error: "internal", message: "Database error" });
    }
  });

  // -----------------------------------------------------------------
  // POST /v1/projects/:id/restore — flip a trashed project back to
  // active (isDeleted: false).
  //
  // We can't restore via the normal PUT roundtrip because GET
  // returns 404 for trashed projects (intentionally — deep-linking a
  // trashed project's URL shouldn't bypass the list filter). The
  // restore button on the web trash list only has the row's id +
  // revision, not the full manifest, so the server reads the
  // manifest itself, flips the flag, generates a fresh revision,
  // and writes it back.
  //
  // No body. Returns the new revision so callers can keep their
  // optimistic-concurrency token in sync if they navigate into the
  // workspace afterward.
  // -----------------------------------------------------------------
  app.post<{
    Params: { id: string };
    Reply: PutManifestResponse | ApiError;
  }>("/v1/projects/:id/restore", async (request, reply) => {
    const { id } = request.params;

    // Restore is a write — editor-or-above. 404 from the access
    // helper covers both not-found and no-relationship.
    try {
      await assertProjectAccess(request.user.id, id, "editor", request);
    } catch (err) {
      if (sendAccessError(reply, err)) return;
      throw err;
    }

    const { data, error } = await supabaseAdmin
      .from("projects")
      .select("manifest, revision")
      .eq("id", id)
      .maybeSingle();

    if (error) {
      request.log.error({ err: error, projectId: id }, "Failed to fetch project for restore");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    if (!data) {
      reply.code(404).send({ error: "not_found", message: `Project ${id} not found` });
      return;
    }

    const manifest = data.manifest as Record<string, unknown> & {
      isDeleted?: boolean;
      isFrozen?: boolean;
    };
    if (manifest.isFrozen === true) {
      reply.code(409).send({
        error: "project_frozen",
        message: "Project is finalized. Unlock it before changing project state.",
      });
      return;
    }
    if (manifest.isDeleted !== true) {
      // Already active — nothing to do. Return current revision so
      // the client's UI can refresh without erroring.
      const { data: row } = await supabaseAdmin
        .from("projects")
        .select("revision")
        .eq("id", id)
        .maybeSingle();
      return { revision: (row?.revision as string) ?? "" };
    }

    const restored = { ...manifest, isDeleted: false };
    const newRevision = crypto.randomUUID();

    const result = await saveProject(request, id, data.revision as string, newRevision, restored as Project);
    if (sendTransactionError(reply, result)) return;

    return { revision: newRevision };
  });

  // -----------------------------------------------------------------
  // DELETE /v1/projects/:id — permanently delete a trashed project.
  //
  // Safety-net: refuse to hard-delete an active project; the caller
  // must soft-delete (isDeleted=true) first. Mirrors iOS's two-step
  // swipe-to-trash then swipe-to-purge flow.
  //
  // Steps:
  //   1. Confirm ownership + isDeleted=true.
  //   2. Gather every object_key in `files` for this project.
  //   3. Batch-delete from R2 (best effort).
  //   4. Delete the `files` rows.
  //   5. Delete the `projects` row.
  //
  // Returns 204 on success.
  // -----------------------------------------------------------------
  app.delete<{
    Params: { id: string };
    Reply: ApiError | null;
  }>("/v1/projects/:id", async (request, reply) => {
    const { id } = request.params;

    // Hard-delete requires editor-or-above (owner, admin, or
    // member-editor). The two-step soft-then-hard flow is the same
    // intentional safety net as today.
    try {
      await assertProjectAccess(request.user.id, id, "editor", request);
    } catch (err) {
      if (sendAccessError(reply, err)) return;
      throw err;
    }

    const { data: existing, error: fetchError } = await supabaseAdmin
      .from("projects")
      .select("manifest, revision")
      .eq("id", id)
      .maybeSingle();
    if (fetchError) {
      request.log.error({ err: fetchError, projectId: id }, "Failed to fetch project for DELETE");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    if (!existing) {
      reply.code(404).send({ error: "not_found", message: `Project ${id} not found` });
      return;
    }

    const manifest = existing.manifest as Record<string, unknown> & {
      isDeleted?: boolean;
    };
    if (manifest.isDeleted !== true) {
      reply.code(409).send({
        error: "precondition_failed",
        message: "Project is still active. Move it to trash before permanently deleting.",
      });
      return;
    }

    // Transaction first: a concurrent restore/save must not lose its binaries.
    // The cascade removes metadata only after all guards pass. Failed storage
    // deletion leaves an orphan, never a live project with destroyed evidence.
    const { data: result, error: deleteError } = await supabaseAdmin.rpc("delete_project_evidence", {
      pid: id, actor: request.user.id, expected: existing.revision, session: clientSession(request),
    });
    if (deleteError) throw deleteError;
    if (!result) throw new Error("Delete transaction returned no result");
    if (sendTransactionError(reply, result)) return;
    const objectKeys = result.objectKeys as string[];
    try { await deleteObjects(objectKeys); }
    catch (err) { request.log.warn({ err, projectId: id }, "Project deleted; orphan storage cleanup is still needed"); }

    request.log.info(
      { projectId: id, blobCount: objectKeys.length, by: request.user.id },
      "Project hard-deleted"
    );
    reply.code(204);
    return null;
  });
};
