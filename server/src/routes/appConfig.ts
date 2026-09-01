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
import { isOrgAdmin } from "../access.js";

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

    if (!(await isOrgAdmin(request.user.id, request))) {
      reply.code(403).send({ error: "forbidden", message: "Only an owner or admin can update shared configuration." });
      return;
    }

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

    const newRevision = crypto.randomUUID();
    const { data: casResult, error: writeErr } = await supabaseAdmin.rpc("cas_app_config", {
      p_key: key,
      p_value: validatedValue,
      p_expected_revision: expectedRevision,
      p_new_revision: newRevision,
      p_updated_by: request.user.id,
    });
    if (writeErr) {
      request.log.error({ err: writeErr, key }, "app_config — atomic write failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    const cas = (Array.isArray(casResult) ? casResult[0] : casResult) as { ok?: boolean; current_revision?: string | null } | null;
    if (!cas?.ok) {
      reply.code(409).send({
        error: "revision_mismatch",
        message: "The server has a newer version of this config value. Pull and merge before retrying.",
        details: { currentRevision: cas?.current_revision ?? null, expectedRevision },
      });
      return;
    }

    request.log.info({ key, by: request.user.id }, "app_config — updated");
    return { revision: newRevision };
  });
};
