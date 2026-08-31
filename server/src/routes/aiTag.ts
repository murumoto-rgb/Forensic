/**
 * AI-tagging proxy endpoint.
 *
 *   POST /v1/ai/tag-photo
 *
 * Phase 4 (Build #5.32.1). Moves the Anthropic API key off iOS / web
 * client devices and onto the server. iOS used to call Anthropic
 * directly with the user's own key; with this endpoint signed-in
 * users hit the team server, which forwards to Anthropic using a
 * single ANTHROPIC_API_KEY env var. Per-user cost tracking can be
 * added on top later by writing to an `audit_log` table.
 *
 * The server is a thin pass-through:
 *  1. Validate the JWT (existing auth middleware).
 *  2. Validate the body shape with zod.
 *  3. Confirm the caller owns the project the photo belongs to.
 *  4. Look up the photo's R2 object key from the `files` table.
 *  5. Fetch the photo bytes from R2 via the server's R2 creds.
 *  6. Call Anthropic's Messages API with the client-supplied
 *     systemPrompt + (image + userText) user turn.
 *  7. Return the concatenated text response + usage metrics.
 *
 * Parsing of the model output into the `AIPhotoAnalysis` struct is
 * deliberately NOT done here — iOS already has a mature parser and
 * we don't want to duplicate it. The server returns rawText; the
 * client parses.
 */

import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import Anthropic from "@anthropic-ai/sdk";
import type {
  ApiError,
  AITagPhotoResponse,
  Project,
  TagLibrary,
} from "@forensic/shared";
import {
  compilePrompt,
  compileUserPrompt,
  PromptCompileError,
  TagLibrarySchema,
  AIRulesTemplateSchema,
} from "@forensic/shared";
import { env } from "../env.js";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";
import { assertProjectAccess, sendAccessError } from "../access.js";
import { getObjectBytes } from "../r2.js";
import { recordAITagAudit } from "../audit.js";
import { reserveAI, releaseAI } from "../resourceLimits.js";

// Cap on max_tokens so a client typo can't force a 60-second
// response. 16384 is generous for a per-photo structured analysis
// (the longest AIPhotoAnalysis JSON we've seen on iOS is ~1500
// tokens) and well below the model ceilings.
const MAX_TOKENS_CEILING = env.AI_MAX_OUTPUT_TOKENS;
const DEFAULT_MAX_TOKENS = Math.min(4096, MAX_TOKENS_CEILING);

const AITagPhotoBodySchema = z.object({
  projectId: z.string().uuid(),
  photoId: z.string().uuid(),
  model: z.enum(["claude-sonnet-4-6", "claude-haiku-4-5"]),
  // Optional as of Build #5.46.1. When either is omitted, the
  // server compiles its own prompt from the project's manifest +
  // the team's tagLibrary + aiRulesTemplate in app_config. Either
  // both are present (client-driven mode) or both are absent
  // (server-driven mode); a mismatch lands as a 400 below.
  systemPrompt: z.string().min(1).max(200_000).optional(),
  userText: z.string().min(1).max(50_000).optional(),
  maxTokens: z
    .number()
    .int()
    .positive()
    .max(MAX_TOKENS_CEILING)
    .optional(),
});

// Build #6.19.1: module-level cache for the server-driven-mode
// app_config reads (tagLibrary + aiRulesTemplate). See the fetch
// site below for rationale. Single-process server, so a plain
// module variable is the whole story.
let aiConfigCache: {
  tagLibrary: TagLibrary;
  rulesText: string;
  fetchedAt: number;
} | null = null;
const AI_CONFIG_CACHE_TTL_MS = 60_000;

// Lazy-init the Anthropic client so the module can still load when
// ANTHROPIC_API_KEY isn't set (server starts cleanly; the route
// itself 503s on call).
let anthropicClient: Anthropic | null = null;
function getAnthropic(): Anthropic | null {
  if (!env.ANTHROPIC_API_KEY) return null;
  if (!anthropicClient) {
    anthropicClient = new Anthropic({ apiKey: env.ANTHROPIC_API_KEY, maxRetries: 0, timeout: 60000 });
  }
  return anthropicClient;
}

/**
 * Best-effort MIME-type detection from the on-disk filename stored
 * on the Photo's `imageFilename`. iPhone captures are HEIC by default
 * but iOS converts to JPEG before upload; markup overlays may be
 * PNG. We default to JPEG when unsure since that covers >99% of the
 * dataset and Anthropic accepts any of these for the `image` content
 * block.
 */
function mimeTypeFromExtension(ext: string): "image/jpeg" | "image/png" | "image/webp" | "image/gif" {
  const e = ext.toLowerCase();
  if (e === "png") return "image/png";
  if (e === "webp") return "image/webp";
  if (e === "gif") return "image/gif";
  return "image/jpeg";
}

export const aiTagRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);

  app.post<{
    Body: unknown;
    Reply: AITagPhotoResponse | ApiError;
  }>("/v1/ai/tag-photo", async (request, reply) => {
    const anthropic = getAnthropic();
    if (!anthropic) {
      // Endpoint deployed but env var not yet set in Render. Clean
      // 503 so the client UI can show "AI tagging not configured —
      // ask an admin to set ANTHROPIC_API_KEY on the server."
      reply.code(503).send({
        error: "service_unavailable",
        message:
          "AI tagging is not configured on this server (ANTHROPIC_API_KEY missing).",
      });
      return;
    }

    const parsed = AITagPhotoBodySchema.safeParse(request.body);
    if (!parsed.success) {
      reply.code(400).send({
        error: "bad_request",
        message: "Request body failed validation",
        details: parsed.error.issues,
      });
      return;
    }
    const { projectId, photoId, model } = parsed.data;
    const maxTokens = parsed.data.maxTokens ?? DEFAULT_MAX_TOKENS;
    const clientSuppliedSystemPrompt = parsed.data.systemPrompt;
    const clientSuppliedUserText = parsed.data.userText;
    // Two valid modes: BOTH client-supplied (legacy iOS path,
    // current web path) OR NEITHER client-supplied (server compiles
    // from manifest + config). A mismatched half-and-half is a
    // 400 — it's almost certainly a client bug rather than a
    // deliberate request shape.
    if (
      (clientSuppliedSystemPrompt == null) !==
      (clientSuppliedUserText == null)
    ) {
      reply.code(400).send({
        error: "bad_request",
        message:
          "Either both systemPrompt and userText must be supplied, or neither (server-side compilation).",
      });
      return;
    }
    const serverDrivenMode =
      clientSuppliedSystemPrompt == null && clientSuppliedUserText == null;

    // Ownership check + (in server-driven mode) manifest fetch.
    // Pull the manifest column unconditionally — it's needed for
    // server-side compilation AND lets us look up the photo's
    // imageFilename for the `photo_id` echo in the user prompt even
    // in client-driven mode (currently unused there, but cheap to
    // have available for future audit-row enrichment).
    // AI re-tag mutates analysis → editor-or-above.
    try {
      await assertProjectAccess(request.user.id, projectId, "editor", request);
    } catch (err) {
      if (sendAccessError(reply, err)) return;
      request.log.error({ err, projectId }, "AI tag — access check failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }

    const { data: projectRow, error: projectErr } = await supabaseAdmin
      .from("projects")
      .select("id, manifest")
      .eq("id", projectId)
      .maybeSingle();
    if (projectErr) {
      request.log.error({ err: projectErr, projectId }, "AI tag — project lookup failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    if (!projectRow) {
      reply.code(404).send({
        error: "not_found",
        message: `Project ${projectId} not found`,
      });
      return;
    }
    const projectManifest = projectRow.manifest as Project;
    const photo = projectManifest.photos.find((p) => p.id === photoId);
    if (!photo) {
      reply.code(404).send({ error: "not_found", message: "Photo is not in this project." });
      return;
    }

    // ---------- Build the prompt ----------
    let systemPrompt: string;
    let userText: string;
    if (serverDrivenMode) {
      // Look up the photo on the manifest so the user prompt can
      // echo `imageFilename` back as the model's photo_id (matches
      // iOS's compileUserPrompt behaviour).
      if (!photo) {
        reply.code(404).send({
          error: "not_found",
          message: `Photo ${photoId} not found on project ${projectId}`,
        });
        return;
      }

      // Fetch app_config tagLibrary + aiRulesTemplate. tagLibrary
      // is required; rules template falls back to empty string
      // when not pushed yet (rare, since iOS auto-pushes on first
      // edit).
      //
      // Build #6.19.1: 60s module-level cache. The config rarely
      // changes, but every server-driven tag-photo request was
      // re-reading it — a 229-photo batch issued 229 identical
      // queries. Admin edits propagate within a minute, which is
      // faster than a typical batch finishes anyway; a failed or
      // empty fetch is never cached.
      let tagLibrary: TagLibrary | null = null;
      let rulesText = "";
      const cached = aiConfigCache;
      if (cached && Date.now() - cached.fetchedAt < AI_CONFIG_CACHE_TTL_MS) {
        tagLibrary = cached.tagLibrary;
        rulesText = cached.rulesText;
      } else {
        const { data: configRows, error: configErr } = await supabaseAdmin
          .from("app_config")
          .select("key, value")
          .in("key", ["tagLibrary", "aiRulesTemplate"]);
        if (configErr) {
          request.log.error({ err: configErr }, "AI tag — app_config fetch failed");
          reply.code(500).send({ error: "internal", message: "Database error" });
          return;
        }
        for (const row of (configRows ?? []) as { key: string; value: unknown }[]) {
          if (row.key === "tagLibrary") {
            const tlParse = TagLibrarySchema.safeParse(row.value);
            if (tlParse.success) tagLibrary = tlParse.data;
          } else if (row.key === "aiRulesTemplate") {
            const arParse = AIRulesTemplateSchema.safeParse(row.value);
            if (arParse.success) rulesText = arParse.data.text;
          }
        }
        if (tagLibrary) {
          aiConfigCache = { tagLibrary, rulesText, fetchedAt: Date.now() };
        }
      }
      if (!tagLibrary) {
        reply.code(422).send({
          error: "config_missing",
          message:
            "No tagLibrary in app_config yet. Push one from iOS (Settings → Tag Library → edit) or via the web admin (/admin/tag-library) before requesting server-side prompt compilation.",
        });
        return;
      }
      try {
        const compiled = compilePrompt({
          rulesTemplate: rulesText,
          tagLibrary,
          project: projectManifest,
        });
        systemPrompt = compiled.joinedSystemPrompt;
      } catch (e: unknown) {
        if (e instanceof PromptCompileError) {
          reply.code(422).send({
            error: "no_tag_selection",
            message:
              "Project has no AI tag selection yet. Pick contexts in iOS (project → AI Tags) before requesting server-side prompt compilation.",
          });
          return;
        }
        request.log.error({ err: e, projectId }, "AI tag — compilePrompt threw");
        reply.code(500).send({ error: "internal", message: "Prompt compile failed" });
        return;
      }
      userText = compileUserPrompt(photo.imageFilename);
    } else {
      // Client-driven mode — both fields are guaranteed non-null
      // by the half-and-half guard above.
      systemPrompt = clientSuppliedSystemPrompt!;
      userText = clientSuppliedUserText!;
    }

    // Resolve the photo's object key from the files table. We
    // always send the full-resolution `photo` (not the thumb) to
    // Anthropic — thumbs lose detail the model needs for accurate
    // tagging.
    const { data: fileRow, error: fileErr } = await supabaseAdmin
      .from("current_project_files")
      .select("object_key, source_filename")
      .eq("project_id", projectId)
      .eq("photo_id", photoId)
      .eq("kind", "photo")
      .order("uploaded_at", { ascending: false })
      .limit(1)
      .abortSignal(AbortSignal.timeout(10000))
      .maybeSingle();
    if (fileErr) {
      request.log.error({ err: fileErr, projectId, photoId }, "AI tag — file lookup failed");
      reply.code(500).send({ error: "internal", message: "Database error" });
      return;
    }
    if (!fileRow) {
      reply.code(404).send({
        error: "not_found",
        message: `Photo ${photoId} has no full-resolution file in storage`,
      });
      return;
    }
    // The view follows the live manifest; prompt compilation used the earlier
    // snapshot. Never analyze replacement bytes under that snapshot's filename.
    if (fileRow.source_filename !== photo.imageFilename) {
      reply.code(409).send({ error: "revision_mismatch", message: "Photo changed before analysis. Refresh the project and retry." });
      return;
    }

    // The lease covers only bounded storage/provider operations; DB
    // lookups above cannot consume its lifetime before paid work starts.
    const lease = await reserveAI(request.user.id, reply);
    if (!lease) return;
    try {
    // Fetch the photo bytes from R2 and base64-encode for the
    // Anthropic message. Anthropic's image content block accepts
    // base64-encoded image data directly; max ~5 MB per image,
    // which is well under our 50 MB upload cap.
    let imageBytes: Buffer;
    try {
      imageBytes = await getObjectBytes(fileRow.object_key as string);
    } catch (err) {
      request.log.error({ err, objectKey: fileRow.object_key }, "AI tag — R2 fetch failed");
      reply.code(502).send({
        error: "storage_error",
        message: "Failed to fetch photo from object store",
      });
      return;
    }

    // Anthropic refuses image payloads above 5 MB. iOS thumbnails
    // are tiny (~30 KB); full photos are typically 2-5 MB after
    // iOS's compression. Reject before we round-trip a huge payload
    // through Anthropic only for it to 400.
    const ANTHROPIC_IMAGE_LIMIT_BYTES = 5 * 1024 * 1024;
    if (imageBytes.length > ANTHROPIC_IMAGE_LIMIT_BYTES) {
      reply.code(413).send({
        error: "image_too_large",
        message: `Photo bytes exceed Anthropic's 5 MB limit (${imageBytes.length} bytes). Re-export at lower quality and retry.`,
      });
      return;
    }

    const extension =
      photo.imageFilename.split(".").pop() ?? "jpg";
    const mediaType = mimeTypeFromExtension(extension);
    const base64Data = imageBytes.toString("base64");

    const startedAt = Date.now();
    let anthropicResponse: Awaited<ReturnType<typeof anthropic.messages.create>>;
    try {
      anthropicResponse = await anthropic.messages.create({
        model,
        max_tokens: maxTokens,
        system: systemPrompt,
        messages: [
          {
            role: "user",
            content: [
              {
                type: "image",
                source: {
                  type: "base64",
                  media_type: mediaType,
                  data: base64Data,
                },
              },
              { type: "text", text: userText },
            ],
          },
        ],
      });
    } catch (err: unknown) {
      // Surface Anthropic's status codes through if we recognize
      // them; otherwise 502 so the client knows it's an upstream
      // issue rather than auth / validation.
      if (err instanceof Anthropic.APIError) {
        request.log.error(
          { status: err.status, message: err.message, projectId, photoId },
          "AI tag — Anthropic error"
        );
        // Map a few common cases to actionable statuses for the
        // client. Anything we don't specifically map falls through
        // to 502 below.
        if (err.status === 401 || err.status === 403) {
          reply.code(503).send({
            error: "service_unavailable",
            message:
              "Server's Anthropic credentials were rejected. Check ANTHROPIC_API_KEY.",
          });
          return;
        }
        if (err.status === 429) {
          reply.code(429).send({
            error: "rate_limited",
            message: "Anthropic rate limit hit — wait a moment and retry.",
          });
          return;
        }
      } else {
        request.log.error({ err, projectId, photoId }, "AI tag — Anthropic call threw");
      }
      reply.code(502).send({
        error: "upstream_error",
        message: "Anthropic call failed",
      });
      return;
    }
    const durationMs = Date.now() - startedAt;

    // Concatenate every `text` content block in the response. Sonnet
    // and Haiku in non-thinking mode emit a single text block here,
    // but joining is robust against future changes.
    const rawText = anthropicResponse.content
      .filter((block): block is Extract<typeof block, { type: "text" }> => block.type === "text")
      .map((block) => block.text)
      .join("");

    request.log.info(
      {
        projectId,
        photoId,
        model,
        inputTokens: anthropicResponse.usage.input_tokens,
        outputTokens: anthropicResponse.usage.output_tokens,
        durationMs,
      },
      "AI tag — completed"
    );

    // Best-effort audit row (Build #5.45.1). Doesn't block the
    // response — we await it inline only because Render's free
    // tier sometimes drops connections on a request that returns
    // before the background promise flushes. The insert itself
    // is small and the supabase admin client pools connections,
    // so the added latency is sub-100ms on a warm route.
    await recordAITagAudit(
      {
        userId: request.user.id,
        projectId,
        photoId,
        model,
        inputTokens: anthropicResponse.usage.input_tokens,
        outputTokens: anthropicResponse.usage.output_tokens,
        cacheReadTokens:
          anthropicResponse.usage.cache_read_input_tokens ?? 0,
        cacheCreationTokens:
          anthropicResponse.usage.cache_creation_input_tokens ?? 0,
        durationMs,
        detail: {
          rawTextLength: rawText.length,
          serverDrivenMode,
        },
      },
      request.log
    );

    return {
      rawText,
      usage: {
        inputTokens: anthropicResponse.usage.input_tokens,
        outputTokens: anthropicResponse.usage.output_tokens,
        cacheReadTokens:
          anthropicResponse.usage.cache_read_input_tokens ?? 0,
        cacheCreationTokens:
          anthropicResponse.usage.cache_creation_input_tokens ?? 0,
      },
      durationMs,
      model,
    };
    } finally { await releaseAI(request.user.id, lease); }
  });
};
