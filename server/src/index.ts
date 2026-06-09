/**
 * Forensic server entry point.
 *
 * Boots a Fastify instance, registers core plugins (CORS,
 * sensible defaults, healthcheck), and listens on the configured
 * port. Business-logic routes (auth-protected manifest CRUD)
 * land in subsequent commits.
 */

// Sentry must be initialised BEFORE Fastify so its auto-instrumentation
// can hook the HTTP server. Conditional on SENTRY_DSN — no-op when
// the env var is absent.
import { initSentry, captureException } from "./sentry.js";
import { initEmail } from "./email/resend.js";
initSentry();
// Resend transactional email (Build #5.61.1). Conditional on
// RESEND_API_KEY + RESEND_FROM_EMAIL — sends no-op when either is
// blank so the route handlers don't need to special-case it.
initEmail();

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
import { appConfigRoute } from "./routes/appConfig.js";
import { locksRoute } from "./routes/locks.js";
import { exportsRoute } from "./routes/exports.js";
import { projectExportsRoute } from "./routes/projectExports.js";
import { meRoute } from "./routes/me.js";
import { adminRoute } from "./routes/admin.js";
import { startPdfExportWorker } from "./exports/pdfWorker.js";
import { startFolderExportWorker } from "./exports/folderBundleWorker.js";
import { startCsvExportWorker } from "./exports/csvWorker.js";
import { ensureChromium } from "./exports/ensureChromium.js";

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
  await app.register(appConfigRoute);
  await app.register(locksRoute);
  await app.register(exportsRoute);
  await app.register(projectExportsRoute);
  await app.register(meRoute);
  await app.register(adminRoute);

  // Error handler — captures non-4xx exceptions into Sentry then
  // delegates to Fastify's default reply machinery (Build #5.57.1).
  // 4xx responses are caller-driven validation / auth / not-found
  // outcomes that don't warrant Sentry's quota; only 5xx + uncaught
  // throws flow through.
  app.setErrorHandler((error: import("fastify").FastifyError, request, reply) => {
    const statusCode = error.statusCode ?? 500;
    if (statusCode >= 500) {
      captureException(error, {
        method: request.method,
        url: request.url,
        userId: (request as { user?: { id: string } }).user?.id,
      });
    }
    reply.send(error);
  });

  try {
    await app.listen({ port: env.PORT, host: "0.0.0.0" });
    app.log.info(
      `Forensic server listening on port ${env.PORT} (${env.NODE_ENV})`
    );
    // Chromium readiness (Build #5.74.1) runs AFTER the listener
    // binds so `/healthz` stays up even during the ~30s install on
    // a cold cache. The PDF worker waits on this promise before its
    // first tick — kicks off as soon as Chromium is in place.
    void ensureChromium(app.log)
      .then(() => {
        startPdfExportWorker(app.log);
      })
      .catch((err) => {
        app.log.error({ err }, "chromium boot failed; PDF export disabled");
        captureException(err);
      });
    // Folder + CSV export workers don't need Chromium; start them
    // immediately. Each has its own atomic-claim polling loop.
    startFolderExportWorker(app.log);
    startCsvExportWorker(app.log);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

main();
