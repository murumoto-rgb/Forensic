/**
 * Sentry server-side error reporting (Build #5.57.1).
 *
 * Initialises the `@sentry/node` SDK conditionally on the
 * `SENTRY_DSN` env var so dev runs (and any deploy without the var
 * set yet) stay 100% offline. When the DSN is missing, every
 * helper here no-ops cleanly — Fastify still boots, no network
 * call is made.
 *
 * Wire-up lives in `index.ts`:
 *
 *  1. `initSentry()` is called before Fastify is instantiated so
 *     auto-instrumentation can hook into the HTTP server.
 *  2. The Fastify error handler is replaced by one that captures
 *     non-4xx exceptions into Sentry before delegating to the
 *     default error reply.
 *
 * Add ad-hoc captures elsewhere with `captureMessage` /
 * `captureException`, both of which no-op when Sentry is off.
 */

import * as Sentry from "@sentry/node";
import { env } from "./env.js";

/** True after a successful `initSentry()`. */
let sentryReady = false;

export function initSentry(): void {
  if (!env.SENTRY_DSN) {
    return;
  }
  Sentry.init({
    dsn: env.SENTRY_DSN,
    environment: env.NODE_ENV,
    release: env.SENTRY_RELEASE,
    tracesSampleRate: env.SENTRY_TRACES_SAMPLE_RATE,
    // Personal data: server only sees `user.id` (UUID) — no email,
    // no IP, no names. The default integrations capture HTTP
    // method + path + status; that's enough triage context without
    // leaking anything sensitive.
    sendDefaultPii: false,
  });
  sentryReady = true;
}

export function captureException(
  error: unknown,
  context?: Record<string, unknown>
): void {
  if (!sentryReady) return;
  Sentry.captureException(error, context ? { extra: context } : undefined);
}

export function captureMessage(
  message: string,
  level: "info" | "warning" | "error" = "info",
  context?: Record<string, unknown>
): void {
  if (!sentryReady) return;
  Sentry.captureMessage(message, {
    level,
    extra: context,
  });
}

/**
 * Attach a per-request user context to Sentry — runs from the auth
 * middleware once `request.user.id` is resolved so any later
 * exception in that request is tagged with the user.
 */
export function setRequestUser(userId: string): void {
  if (!sentryReady) return;
  Sentry.setUser({ id: userId });
}
