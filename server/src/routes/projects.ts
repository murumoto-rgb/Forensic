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
import {
  assertProjectAccess,
  isOrgAdmin,
  sendAccessError,
} from "../access.js";

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
    const callerIsAdmin = await isOrgAdmin(uid);

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
        role = await assertProjectAccess(request.user.id, id, "viewer");
      } catch (err) {
        if (sendAccessError(reply, err)) return;
        request.log.error({ err, projectId: id }, "Failed to check project access");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }

      const { data, error } = await supabaseAdmin
        .from("projects")
        .select("manifest, revision")
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

    // Server's known schema version is the source of truth — but we
    // LOG rather than REJECT on `client > server`. Hard-rejecting
    // during a tandem-shipping window (iOS already updated via
    // TestFlight, Render still building the new server) shows the
    // user "sync failed" toasts for several minutes. The actual
    // shapes are nearly always forward-compatible (new fields with
    // defaults — see Build #5.6.1 `isDeleted`), so accepting +
    // warning gives the user a working app while operations catches
    // up. If a genuinely incompatible future change ships, the zod
    // ProjectSchema parse will catch it.
    const { MANIFEST_SCHEMA_VERSION } = await import("@forensic/shared");
    if (project.manifestSchemaVersion > MANIFEST_SCHEMA_VERSION) {
      request.log.warn(
        {
          projectId: id,
          clientVersion: project.manifestSchemaVersion,
          serverVersion: MANIFEST_SCHEMA_VERSION,
        },
        "Client manifest is newer than this server knows about — accepting anyway. Update server soon."
      );
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
          // First-create on the merge path: the legacy path handles
          // create cleanly (no row to merge against). Fall through.
          break;
        }

        if (!updateAccessChecked) {
          try {
            await assertProjectAccess(request.user.id, id, "editor");
          } catch (err) {
            if (sendAccessError(reply, err)) return;
            throw err;
          }
          updateAccessChecked = true;
        }

        const serverCurrent = existing.manifest as unknown as Project;
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
        const { data: updatedRows, error: writeError } = await supabaseAdmin
          .from("projects")
          .update({
            name: merged.name,
            manifest: merged,
            manifest_schema_version: merged.manifestSchemaVersion,
            revision: newRevision,
          })
          .eq("id", id)
          .eq("revision", expectedServerRev)
          .select("id");
        if (writeError) {
          request.log.error(
            { err: writeError, projectId: id },
            "Failed to write merged project"
          );
          reply.code(500).send({ error: "internal", message: "Database error" });
          return;
        }
        if (updatedRows && updatedRows.length === 1) {
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
      .select("revision, owner_id")
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
        await assertProjectAccess(request.user.id, id, "editor");
      } catch (err) {
        if (sendAccessError(reply, err)) return;
        throw err;
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

    // CRITICAL (Build #5.123.1): on UPDATE, preserve the existing
    // owner_id so a member-editor's save can't quietly steal
    // ownership. On CREATE, the caller becomes owner.
    const ownerIdToWrite = existing ? (existing.owner_id as string) : request.user.id;

    const { error: writeError } = await supabaseAdmin.from("projects").upsert({
      id,
      owner_id: ownerIdToWrite,
      name: project.name,
      manifest: project,
      manifest_schema_version: project.manifestSchemaVersion,
      revision: newRevision,
    });

    if (writeError) {
      request.log.error({ err: writeError, projectId: id }, "Failed to write project");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    return { revision: newRevision };
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
      await assertProjectAccess(request.user.id, id, "editor");
    } catch (err) {
      if (sendAccessError(reply, err)) return;
      throw err;
    }

    const { data, error } = await supabaseAdmin
      .from("projects")
      .select("manifest")
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
    };
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

    const { error: writeError } = await supabaseAdmin
      .from("projects")
      .update({
        manifest: restored,
        revision: newRevision,
      })
      .eq("id", id);

    if (writeError) {
      request.log.error({ err: writeError, projectId: id }, "Failed to restore project");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

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
      await assertProjectAccess(request.user.id, id, "editor");
    } catch (err) {
      if (sendAccessError(reply, err)) return;
      throw err;
    }

    const { data: existing, error: fetchError } = await supabaseAdmin
      .from("projects")
      .select("manifest")
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

    // Step 2: list every file row for the project.
    const { data: files, error: filesError } = await supabaseAdmin
      .from("files")
      .select("object_key")
      .eq("project_id", id);
    if (filesError) {
      request.log.error({ err: filesError, projectId: id }, "Failed to list files for DELETE");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    const objectKeys = (files ?? []).map((r) => r.object_key as string);

    // Step 3: best-effort R2 reaping. Per-blob errors are logged but
    // not surfaced — orphaned blobs are a separate cleanup concern.
    try {
      await deleteObjects(objectKeys);
    } catch (err) {
      request.log.warn(
        { err, projectId: id, objectCount: objectKeys.length },
        "deleteObjects partial failure during project hard-delete; continuing with DB cleanup."
      );
    }

    // Step 4: drop files rows.
    if (objectKeys.length > 0) {
      const { error: filesDeleteError } = await supabaseAdmin
        .from("files")
        .delete()
        .eq("project_id", id);
      if (filesDeleteError) {
        request.log.error({ err: filesDeleteError, projectId: id }, "Failed to drop file rows");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
    }

    // Step 5: drop project row. Access was already checked at the top
    // of the handler; key on id alone here.
    const { error: projDeleteError } = await supabaseAdmin
      .from("projects")
      .delete()
      .eq("id", id);
    if (projDeleteError) {
      request.log.error({ err: projDeleteError, projectId: id }, "Failed to delete project row");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    request.log.info(
      { projectId: id, blobCount: objectKeys.length, by: request.user.id },
      "Project hard-deleted"
    );
    reply.code(204);
    return null;
  });
};
