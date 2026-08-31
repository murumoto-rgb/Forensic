import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import type { BrandingLogoUploadResponse, GetBrandingLogoResponse, ApiError } from "@forensic/shared";
import { authPlugin } from "../middleware/auth.js";
import { isOrgAdmin } from "../access.js";
import { supabaseAdmin } from "../supabase.js";
import { presignedGet, putObjectBytes } from "../r2.js";
import { probeImageDimensions } from "../exports/imageProbe.js";

const MAX_LOGO_BYTES = 1024 * 1024;
const uploadSchema = z.object({ pngBase64: z.string().min(1).max(Math.ceil(MAX_LOGO_BYTES / 3) * 4).regex(/^[A-Za-z0-9+/]*={0,2}$/) });

/** Branding is an app configuration asset, not evidence belonging to an
 * arbitrary first project. Upload does not publish it: the normal config CAS
 * must still succeed before other clients use this immutable object key. */
export const brandingRoute: FastifyPluginAsync = async (app) => {
  await app.register(authPlugin);
  app.post<{ Body: unknown; Reply: BrandingLogoUploadResponse | ApiError }>(
    "/v1/branding/logo", { bodyLimit: 1_500_000 }, async (request, reply) => {
      if (!(await isOrgAdmin(request.user.id, request))) {
        return reply.code(403).send({ error: "forbidden", message: "Only an admin can change report branding." });
      }
      const parsed = uploadSchema.safeParse(request.body);
      if (!parsed.success) return reply.code(400).send({ error: "bad_request", message: "Provide a PNG logo no larger than 1 MiB." });
      const bytes = Buffer.from(parsed.data.pngBase64, "base64");
      try {
        const size = probeImageDimensions(bytes);
        if (size.type !== "png" || bytes.length > MAX_LOGO_BYTES || size.width * size.height > 4_000_000) throw new Error("Logo size");
      } catch {
        return reply.code(400).send({ error: "bad_request", message: "Logo must be a PNG up to 1 MiB and 4 megapixels." });
      }
      const objectKey = `branding/${request.user.id}/${crypto.randomUUID()}.png`;
      await putObjectBytes({ objectKey, body: bytes, contentType: "image/png", ifNoneMatch: "*" });
      return { objectKey };
    });

  app.get<{ Reply: GetBrandingLogoResponse | ApiError }>("/v1/branding/logo", async (_request, reply) => {
    const { data, error } = await supabaseAdmin.from("app_config").select("value").eq("key", "reportBranding").maybeSingle();
    if (error) return reply.code(503).send({ error: "config_unavailable", message: "Report branding is unavailable." });
    const objectKey = data?.value?.logoStoragePath;
    if (typeof objectKey !== "string" || !objectKey) return reply.code(404).send({ error: "not_found", message: "No shared logo has been saved." });
    const ttl = 300;
    return { objectKey, url: await presignedGet({ objectKey, expiresInSeconds: ttl }), expiresAt: new Date(Date.now() + ttl * 1000).toISOString() };
  });
};
