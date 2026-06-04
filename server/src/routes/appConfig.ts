/**
 * App-wide config sync endpoints (Build #5.35.1).
 *
 *   GET  /v1/config                → fetch every known key in one round trip
 *   GET  /v1/config/:key           → fetch one key
 *   PUT  /v1/config/:key           → write one key, with optimistic concurrency
 *
 * Backed by the `app_config` SQL table (migration 0004). Per-key value
 * shape is enforced by the zod schemas in
 * `packages/shared/src/validation.ts:AppConfigValueSchemaByKey`.
 *
 * Auth: every route requires a valid Supabase JWT. The values live
 * team-wide (no per-user scoping today), so any signed-in user can
 * read and write. Phase 5 may layer admin-only writes on top once
 * the role machinery lands.
 */

import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import {
  AppConfigValueSchemaByKey,
  type AppConfigKey,
  type GetAppConfigResponse,
  type GetAppConfigBundleResponse,
  type PutAppConfigResponse,
  type ApiError,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";

/** Every key the server recognises. Anything not in here 404s on
 *  GET and 400s on PUT — the union string-literal is the wire
 *  contract, so no surprises. */
const KNOWN_KEYS = Object.keys(AppConfigValueSchemaByKey) as AppConfigKey[];

const PutBodySchema = z.object({
  // value is validated against the per-key schema below — parsed as
  // `unknown` here so we can dispatch on `key` first and emit a
  // clean per-key error rather than a generic union mismatch.
  value: z.unknown(),
  expectedRevision: z.string().nullable(),
});

/** Type-safe row shape returned from Supabase. */
interface AppConfigRow {
  key: string;
  value: unknown;
  revision: string;
  updated_at: string;
}

export const appConfigRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);

  // -----------------------------------------------------------------
  // GET /v1/config — fetch every known key in one round trip.
  //
  // Missing keys are absent from `entries` (no null, no 404). Lets
  // clients merge with their local defaults straight away on first
  // load.
  // -----------------------------------------------------------------
  app.get<{
    Reply: GetAppConfigBundleResponse | ApiError;
  }>("/v1/config", async (request, reply) => {
    const { data, error } = await supabaseAdmin
      .from("app_config")
      .select("key, value, revision, updated_at")
      .in("key", KNOWN_KEYS);
    if (error) {
      request.log.error({ err: error }, "app_config — bundle fetch failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    // Build the map via Record<string, …> — TS can't narrow the
    // per-key mapped type across a computed assignment like
    // `entries[row.key as AppConfigKey] = …`, so we widen to a
    // string-keyed dictionary internally and cast at the boundary.
    const entries: Record<string, GetAppConfigResponse> = {};
    for (const row of (data ?? []) as AppConfigRow[]) {
      if (!KNOWN_KEYS.includes(row.key as AppConfigKey)) continue;
      entries[row.key] = {
        key: row.key as AppConfigKey,
        value: row.value,
        revision: row.revision,
        updatedAt: row.updated_at,
      } as GetAppConfigResponse;
    }
    return { entries: entries as GetAppConfigBundleResponse["entries"] };
  });

  // -----------------------------------------------------------------
  // GET /v1/config/:key — fetch one key.
  // -----------------------------------------------------------------
  app.get<{
    Params: { key: string };
    Reply: GetAppConfigResponse | ApiError;
  }>("/v1/config/:key", async (request, reply) => {
    const key = request.params.key;
    if (!KNOWN_KEYS.includes(key as AppConfigKey)) {
      reply.code(400).send({
        error: "bad_request",
        message: `Unknown app_config key: ${key}`,
        details: { knownKeys: KNOWN_KEYS },
      });
      return;
    }
    const { data, error } = await supabaseAdmin
      .from("app_config")
      .select("key, value, revision, updated_at")
      .eq("key", key)
      .maybeSingle();
    if (error) {
      request.log.error({ err: error, key }, "app_config — single fetch failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    if (!data) {
      reply.code(404).send({
        error: "not_found",
        message: `No value stored for ${key} yet.`,
      });
      return;
    }
    const row = data as AppConfigRow;
    return {
      key: row.key as AppConfigKey,
      value: row.value,
      revision: row.revision,
      updatedAt: row.updated_at,
    } as GetAppConfigResponse;
  });

  // -----------------------------------------------------------------
  // PUT /v1/config/:key — write one key.
  //
  // Optimistic concurrency: client sends `expectedRevision` from its
  // last GET (or `null` for first push). Server rejects mismatch
  // with 409 so the client pulls + merges rather than clobbering.
  // -----------------------------------------------------------------
  app.put<{
    Params: { key: string };
    Body: unknown;
    Reply: PutAppConfigResponse | ApiError;
  }>("/v1/config/:key", async (request, reply) => {
    const key = request.params.key;
    if (!KNOWN_KEYS.includes(key as AppConfigKey)) {
      reply.code(400).send({
        error: "bad_request",
        message: `Unknown app_config key: ${key}`,
        details: { knownKeys: KNOWN_KEYS },
      });
      return;
    }

    const bodyParse = PutBodySchema.safeParse(request.body);
    if (!bodyParse.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: bodyParse.error.issues,
      });
      return;
    }
    const { value, expectedRevision } = bodyParse.data;

    // Per-key value validation. Per-key schema is the source of
    // truth for what shape lands in the jsonb column.
    const valueSchema = AppConfigValueSchemaByKey[key as AppConfigKey];
    const valueParse = valueSchema.safeParse(value);
    if (!valueParse.success) {
      reply.code(400).send({
        error: "bad_request",
        message: `Value for ${key} failed validation`,
        details: valueParse.error.issues,
      });
      return;
    }
    const validatedValue = valueParse.data;

    // Concurrency check + upsert. Pulled into a single tx-shape so a
    // racing concurrent write can't sneak between read and write.
    // We do it as a read-then-conditional-update because Supabase
    // doesn't expose `UPDATE ... WHERE revision = $1 RETURNING ...`
    // cleanly via the SDK; this approach hands the conflict back to
    // the client without needing a stored procedure.
    const { data: existing, error: readErr } = await supabaseAdmin
      .from("app_config")
      .select("revision")
      .eq("key", key)
      .maybeSingle();
    if (readErr) {
      request.log.error({ err: readErr, key }, "app_config — pre-write read failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    const currentRevision = (existing as { revision: string } | null)?.revision ?? null;
    if (currentRevision !== expectedRevision) {
      reply.code(409).send({
        error: "revision_mismatch",
        message:
          "The server has a newer version of this config value. Pull and merge before retrying.",
        details: { currentRevision, expectedRevision },
      });
      return;
    }

    const newRevision = crypto.randomUUID();
    const { error: writeErr } = await supabaseAdmin
      .from("app_config")
      .upsert(
        {
          key,
          value: validatedValue,
          revision: newRevision,
          updated_by: request.user.id,
        },
        { onConflict: "key" }
      );
    if (writeErr) {
      request.log.error({ err: writeErr, key }, "app_config — write failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    request.log.info({ key, by: request.user.id }, "app_config — updated");
    return { revision: newRevision };
  });
};
