/**
 * Forensic server entry point.
 *
 * Boots a Fastify instance, registers core plugins (CORS,
 * sensible defaults, healthcheck), and listens on the configured
 * port. Business-logic routes (auth-protected manifest CRUD)
 * land in subsequent commits.
 */

import Fastify from "fastify";
import cors from "@fastify/cors";
import sensible from "@fastify/sensible";
import { env, corsOrigins } from "./env.js";
import "./types.js";
import { healthzRoute } from "./routes/healthz.js";
import { projectsRoute } from "./routes/projects.js";
import { filesRoute } from "./routes/files.js";
import { photosRoute } from "./routes/photos.js";
import { plansRoute } from "./routes/plans.js";
import { aiTagRoute } from "./routes/aiTag.js";

async function main() {
  const app = Fastify({
    logger: {
      level: env.NODE_ENV === "production" ? "info" : "debug",
      transport:
        env.NODE_ENV === "development"
          ? { target: "pino-pretty", options: { translateTime: "HH:MM:ss" } }
          : undefined,
    },
    trustProxy: true,
    // Manifest JSON can grow with photo count + AI-analysis blobs.
    // A forensic project with hundreds of photos easily exceeds
    // Fastify's 1 MB default. 50 MB matches the per-photo binary
    // cap on the upload endpoints — sized to handle ~500-1000
    // photos worth of metadata. Render free tier has 512 MB RAM
    // so a single 50 MB body is comfortably within budget.
    bodyLimit: 50 * 1024 * 1024,
  });

  await app.register(sensible);
  await app.register(cors, {
    // If no origins are configured, refuse all cross-origin
    // requests. If origins are configured, allow only those
    // exact strings (no regex / wildcards for now — narrower is
    // safer).
    origin: corsOrigins.length === 0 ? false : corsOrigins,
    credentials: true,
    // @fastify/cors v11 defaults `methods` to "GET,HEAD,POST" —
    // it leaves PUT, PATCH, DELETE out, so the OPTIONS preflight
    // for our manifest PUT returns "Access-Control-Allow-Methods:
    // GET,HEAD,POST" and the browser blocks the actual PUT
    // ("Method PUT is not allowed by Access-Control-Allow-Methods"
    // — Build #5.22.1 fix). Web pin-drag save is the only PUT we
    // do today; DELETE/PATCH are listed pre-emptively for Phase 3
    // distress add/edit/delete in the near future.
    methods: ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
  });

  await app.register(healthzRoute);
  await app.register(projectsRoute);
  await app.register(filesRoute);
  await app.register(photosRoute);
  await app.register(plansRoute);
  await app.register(aiTagRoute);

  try {
    await app.listen({ port: env.PORT, host: "0.0.0.0" });
    app.log.info(
      `Forensic server listening on port ${env.PORT} (${env.NODE_ENV})`
    );
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

main();
