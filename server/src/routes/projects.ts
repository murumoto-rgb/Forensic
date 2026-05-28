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
  type GetManifestResponse,
  type PutManifestResponse,
  type ApiError,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";

const PutBodySchema = z.object({
  project: ProjectSchema,
  // `null` on first create; previous revision on every subsequent
  // PUT. Server rejects mismatches with 409.
  expectedRevision: z.string().nullable(),
});

interface ProjectListItem {
  id: string;
  name: string;
  manifestSchemaVersion: number;
  revision: string;
  createdAt: string;
  updatedAt: string;
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
  // -----------------------------------------------------------------
  app.get<{ Reply: ProjectListResponse | ApiError }>("/v1/projects", async (request, reply) => {
    const { data, error } = await supabaseAdmin
      .from("projects")
      .select("id, name, manifest_schema_version, revision, created_at, updated_at")
      .eq("owner_id", request.user.id)
      .order("updated_at", { ascending: false });

    if (error) {
      request.log.error({ err: error }, "Failed to list projects");
      reply.code(500).send({ error: "internal", message: "Database error" } satisfies ApiError);
      return;
    }

    const projects: ProjectListItem[] = (data ?? []).map((row) => ({
      id: row.id as string,
      name: row.name as string,
      manifestSchemaVersion: row.manifest_schema_version as number,
      revision: row.revision as string,
      createdAt: row.created_at as string,
      updatedAt: row.updated_at as string,
    }));
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
      const { data, error } = await supabaseAdmin
        .from("projects")
        .select("manifest, revision")
        .eq("id", id)
        .eq("owner_id", request.user.id)
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

      // The DB stores the manifest as jsonb; supabase-js returns it
      // as an already-parsed object. Cast through unknown to the
      // shared Project type — the data was written via PUT after
      // ProjectSchema validation, so the shape is trusted.
      return {
        project: data.manifest as unknown as GetManifestResponse["project"],
        revision: data.revision as string,
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
    const { project, expectedRevision } = parsed.data;

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

    // Server's known schema version is the source of truth — refuse
    // writes from clients on a future version.
    const { MANIFEST_SCHEMA_VERSION } = await import("@forensic/shared");
    if (project.manifestSchemaVersion > MANIFEST_SCHEMA_VERSION) {
      reply.code(409).send({
        error: "schema_version_too_new",
        message:
          `Client manifest is at v${project.manifestSchemaVersion}, server only knows v${MANIFEST_SCHEMA_VERSION}. ` +
          "Update the server first, then retry.",
      });
      return;
    }

    // Look up current state to honor optimistic-concurrency check.
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
      // Updating an existing row: caller must own it, and the
      // revision must match.
      if (existing.owner_id !== request.user.id) {
        // Don't leak existence of someone else's project — return
        // 404 just like an unrelated id would.
        reply.code(404).send({ error: "not_found", message: `Project ${id} not found` });
        return;
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

    const { error: writeError } = await supabaseAdmin.from("projects").upsert({
      id,
      owner_id: request.user.id,
      name: project.name,
      manifest: project,
      manifest_schema_version: project.manifestSchemaVersion,
      revision: newRevision,
      // created_at + updated_at default to now() in SQL; on update
      // the trigger refreshes updated_at automatically.
    });

    if (writeError) {
      request.log.error({ err: writeError, projectId: id }, "Failed to write project");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    return { revision: newRevision };
  });
};
