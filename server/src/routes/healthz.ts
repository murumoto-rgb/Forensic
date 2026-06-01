/**
 * Healthcheck endpoint.
 *
 * Used by Render's deploy probes and by anyone wanting to
 * confirm the server is reachable. Returns the server's expected
 * manifest schema version so clients can detect a version skew
 * before doing any real work.
 */

import type { FastifyPluginAsync } from "fastify";
import { MANIFEST_SCHEMA_VERSION, type HealthzResponse } from "@forensic/shared";

// Render injects the deployed commit SHA as RENDER_GIT_COMMIT. Read it
// once at module load. `null` locally where the var isn't set. Exposing
// it on /healthz lets anyone confirm which build is live with a single
// unauthenticated GET — useful when a deploy's completion isn't
// otherwise observable (the dashboard is the only other signal).
const GIT_SHA = process.env.RENDER_GIT_COMMIT ?? null;
const GIT_SHA_SHORT = GIT_SHA ? GIT_SHA.slice(0, 7) : null;

export const healthzRoute: FastifyPluginAsync = async (app) => {
  app.get<{ Reply: HealthzResponse }>("/healthz", async () => {
    return {
      status: "ok",
      serverManifestSchemaVersion: MANIFEST_SCHEMA_VERSION,
      gitSha: GIT_SHA,
      gitShaShort: GIT_SHA_SHORT,
    };
  });
};
