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
  type PutUserPrefsResponse,
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
          },
          revision: "",
        };
      }
      return {
        prefs: data.prefs as GetUserPrefsResponse["prefs"],
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
};
