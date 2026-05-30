/**
 * Floor-plan image download endpoint.
 *
 *   GET /v1/projects/:projectId/plans/:planId/image → JSON {url, expiresAt}
 *
 * Mirrors `routes/photos.ts` for plan-kind files. The `files` table
 * stores plan images keyed by `(project_id, photo_id, kind="plan")`
 * where `photo_id` is repurposed for plan IDs (the `buildObjectKey`
 * helper formats them identically). Server validates project
 * ownership, looks up the row, and returns a 5-minute presigned
 * R2 GET URL.
 *
 * Returns 404 when no plan-kind file exists for the given
 * (project, plan) pair — typically because iOS hasn't uploaded the
 * plan image yet (the manifest entry exists, but the binary
 * doesn't). Web treats this 404 as a "pending upload" placeholder,
 * same pattern as photos.
 */

import type { FastifyPluginAsync } from "fastify";
import type { ApiError, PhotoUrlResponse } from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { authPlugin } from "../middleware/auth.js";
import { presignedGet } from "../r2.js";

const DOWNLOAD_URL_TTL_SECONDS = 5 * 60;

interface PlanParams {
  projectId: string;
  planId: string;
}

export const plansRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);

  app.get<{ Params: PlanParams; Reply: PhotoUrlResponse | ApiError }>(
    "/v1/projects/:projectId/plans/:planId/image",
    async (request, reply) => {
      const { projectId, planId } = request.params;
      const userId = request.user.id;

      const { data: project, error: projectErr } = await supabaseAdmin
        .from("projects")
        .select("id")
        .eq("id", projectId)
        .eq("owner_id", userId)
        .maybeSingle();
      if (projectErr) {
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
      if (!project) {
        reply
          .code(404)
          .send({ error: "not_found", message: `Project ${projectId} not found` });
        return;
      }

      const { data: file, error: filesErr } = await supabaseAdmin
        .from("files")
        .select("object_key")
        .eq("project_id", projectId)
        .eq("photo_id", planId)
        .eq("kind", "plan")
        .maybeSingle();
      if (filesErr) {
        reply.code(500).send({ error: "internal", message: "Database error" });
        return;
      }
      if (!file) {
        reply.code(404).send({
          error: "not_found",
          message: `Plan ${planId} has no image in storage yet`,
        });
        return;
      }

      const url = await presignedGet({
        objectKey: file.object_key as string,
        expiresInSeconds: DOWNLOAD_URL_TTL_SECONDS,
      });
      const expiresAt = new Date(
        Date.now() + DOWNLOAD_URL_TTL_SECONDS * 1000
      ).toISOString();
      return { url, expiresAt };
    }
  );
};
