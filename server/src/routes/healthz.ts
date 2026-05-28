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

export const healthzRoute: FastifyPluginAsync = async (app) => {
  app.get<{ Reply: HealthzResponse }>("/healthz", async () => {
    return {
      status: "ok",
      serverManifestSchemaVersion: MANIFEST_SCHEMA_VERSION,
    };
  });
};
