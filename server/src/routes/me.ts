/**
 * Per-user routes (Build #5.95.1).
 *
 *   GET /v1/me/prefs  → load the calling user's UI preferences.
 *   PUT /v1/me/prefs  → write them, with revision-token concurrency.
 *
 * Backed by the `user_prefs` table (migration 0010). Rows are
 * keyed by `auth.uid()` and unique per user. A first-time read
 * before any write returns a default `{}` blob shaped like the
 * `UserPrefs` interface; clients merge with their local defaults.
 */

import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import {
  UserPrefsSchema,
  type GetUserPrefsResponse,
  type MeResponse,
  type PutUserPrefsResponse,
  type GetUserStorageStatusResponse,
  type ApiError,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";

const PutBodySchema = z.object({
  prefs: UserPrefsSchema,
  expectedRevision: z.string().nullable(),
});

export const meRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);

  // -----------------------------------------------------------------
  // GET /v1/me — identity + org-role for the calling user
  // (Build #5.124.1). NOT admin-gated — every signed-in user calls
  // this on mount so the web client can render the right admin
  // links and gate the admin page.
  // -----------------------------------------------------------------
  app.get<{ Reply: MeResponse | ApiError }>(
    "/v1/me",
    async (request, reply) => {
      const userId = request.user.id;
      const { data, error } = await supabaseAdmin
        .from("profiles")
        .select("id, email, display_name, is_admin")
        .eq("id", userId)
        .maybeSingle();
      if (error) {
        request.log.error({ err: error, userId }, "me — read failed");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
      if (!data) {
        // First-login race: the on_auth_user_created trigger should
        // have created the profile row, but if we're called before
        // it commits, fall back to the JWT-derived identity.
        return {
          id: userId,
          email: request.user.email ?? "",
          displayName: null,
          isAdmin: false,
        };
      }
      return {
        id: data.id as string,
        email: data.email as string,
        displayName: (data.display_name as string | null) ?? null,
        isAdmin: (data.is_admin as boolean | null) === true,
      };
    }
  );

  // -----------------------------------------------------------------
  // GET /v1/me/prefs
  // -----------------------------------------------------------------
  app.get<{ Reply: GetUserPrefsResponse | ApiError }>(
    "/v1/me/prefs",
    async (request, reply) => {
      const userId = request.user.id;
      const { data, error } = await supabaseAdmin
        .from("user_prefs")
        .select("prefs, revision")
        .eq("user_id", userId)
        .maybeSingle();
      if (error) {
        request.log.error({ err: error, userId }, "user_prefs — read failed");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
      if (!data) {
        // First-time read — synthesize a 200 with an empty shape +
        // sentinel "null" revision so the client can PUT with
        // expectedRevision=null on first write.
        return {
          prefs: {
            aiModel: null,
            tagConfidenceThreshold: null,
            aiConcurrency: null,
            planBubbleScale: null,
            planColorMode: null,
          },
          revision: "",
        };
      }
      // Existing rows may pre-date the planBubbleScale field
      // (Build #6.13.1) — coerce undefined → null so the response
      // matches the wire shape without a backfill migration.
      const dbPrefs = data.prefs as Partial<GetUserPrefsResponse["prefs"]>;
      return {
        prefs: {
          aiModel: dbPrefs.aiModel ?? null,
          tagConfidenceThreshold: dbPrefs.tagConfidenceThreshold ?? null,
          aiConcurrency: dbPrefs.aiConcurrency ?? null,
          planBubbleScale: dbPrefs.planBubbleScale ?? null,
          planColorMode: dbPrefs.planColorMode ?? null,
        },
        revision: data.revision as string,
      };
    }
  );

  // -----------------------------------------------------------------
  // PUT /v1/me/prefs
  //
  // Concurrency: client echoes `expectedRevision` from its last GET.
  //   * `""`   — first-time write (no row yet).
  //   * `<uuid>` — update existing; 409 if mismatched.
  // -----------------------------------------------------------------
  app.put<{
    Body: unknown;
    Reply: PutUserPrefsResponse | ApiError;
  }>("/v1/me/prefs", async (request, reply) => {
    const userId = request.user.id;
    const parsed = PutBodySchema.safeParse(request.body);
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }
    const { prefs, expectedRevision } = parsed.data;

    // Read current revision.
    const { data: existing, error: readErr } = await supabaseAdmin
      .from("user_prefs")
      .select("revision")
      .eq("user_id", userId)
      .maybeSingle();
    if (readErr) {
      request.log.error({ err: readErr, userId }, "user_prefs — pre-write read failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    const currentRevision = (existing as { revision: string } | null)?.revision ?? null;
    // First write: client may either send null or "" (server stub
    // emits "" for absent rows). Accept both as "create".
    const isFirstWrite = currentRevision === null;
    const expected = expectedRevision === "" ? null : expectedRevision;
    if (currentRevision !== expected) {
      reply.code(409).send({
        error: "revision_mismatch",
        message:
          "Preferences were modified elsewhere. Pull and merge before retrying.",
        details: { currentRevision, expectedRevision },
      });
      return;
    }

    const newRevision = crypto.randomUUID();
    const { error: writeErr } = await supabaseAdmin
      .from("user_prefs")
      .upsert(
        {
          user_id: userId,
          prefs,
          revision: newRevision,
        },
        { onConflict: "user_id" }
      );
    if (writeErr) {
      request.log.error({ err: writeErr, userId }, "user_prefs — write failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    request.log.info(
      { userId, isFirstWrite },
      "user_prefs — updated"
    );
    return { revision: newRevision };
  });

  // -----------------------------------------------------------------
  // GET /v1/me/storage — aggregated cloud-storage usage for the
  // calling user.
  //
  // Walks: projects table (count + manifest jsonb digests for photo
  // / floor plan counts) + files table (sum of size_bytes). Per-kind
  // breakdown lets the UI render a stacked bar showing how much
  // photos vs. plans vs. markups vs. exports consume.
  // -----------------------------------------------------------------
  app.get<{ Reply: GetUserStorageStatusResponse | ApiError }>(
    "/v1/me/storage",
    async (request, reply) => {
      const userId = request.user.id;

      // 1) Project counts + manifest digests.
      const { data: projectRows, error: projErr } = await supabaseAdmin
        .from("projects")
        .select("manifest")
        .eq("owner_id", userId);
      if (projErr) {
        request.log.error({ err: projErr, userId }, "storage — projects read failed");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }

      let activeProjectCount = 0;
      let photoCount = 0;
      let floorPlanCount = 0;
      for (const row of projectRows ?? []) {
        const manifest = (row as { manifest: { isDeleted?: boolean; photos?: unknown[]; floorPlans?: unknown[] } }).manifest;
        if (manifest.isDeleted !== true) activeProjectCount += 1;
        photoCount += Array.isArray(manifest.photos) ? manifest.photos.length : 0;
        floorPlanCount += Array.isArray(manifest.floorPlans) ? manifest.floorPlans.length : 0;
      }
      const projectCount = projectRows?.length ?? 0;

      // 2) Files table — aggregate by kind for the calling user's
      // projects. Postgres GROUP BY would be cleaner but supabase-js
      // doesn't expose SUM via the REST layer easily; the file row
      // count is bounded by photos*kinds + plans so a JS-side
      // aggregation is fine.
      const { data: fileRows, error: fileErr } = await supabaseAdmin
        .from("files")
        .select("kind, size_bytes, projects!inner(owner_id)")
        .eq("projects.owner_id", userId);
      if (fileErr) {
        request.log.error({ err: fileErr, userId }, "storage — files read failed");
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }

      let totalBlobBytes = 0;
      const blobBytesByKind: Record<string, number> = {};
      for (const row of fileRows ?? []) {
        const r = row as { kind: string; size_bytes: number | null };
        const bytes = r.size_bytes ?? 0;
        totalBlobBytes += bytes;
        blobBytesByKind[r.kind] = (blobBytesByKind[r.kind] ?? 0) + bytes;
      }

      return {
        status: {
          projectCount,
          activeProjectCount,
          photoCount,
          floorPlanCount,
          totalBlobBytes,
          blobBytesByKind,
        },
        computedAt: new Date().toISOString(),
      };
    }
  );
};
