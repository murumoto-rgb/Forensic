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
  });

  await app.register(sensible);
  await app.register(cors, {
    // If no origins are configured, refuse all cross-origin
    // requests. If origins are configured, allow only those
    // exact strings (no regex / wildcards for now — narrower is
    // safer).
    origin: corsOrigins.length === 0 ? false : corsOrigins,
    credentials: true,
  });

  await app.register(healthzRoute);
  await app.register(projectsRoute);

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
