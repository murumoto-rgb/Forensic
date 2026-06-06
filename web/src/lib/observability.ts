/**
 * Sentry + PostHog initialisation for the web client (Build #5.57.1).
 *
 * Both SDKs initialise conditionally on env vars — when their keys
 * are missing, the helpers in this module no-op cleanly. That keeps
 * local dev and any deploy without the keys set up running silently
 * without network noise.
 *
 * Sentry captures unhandled errors, Suspense / Promise rejections,
 * and the React-Router navigation traces. PostHog autocaptures
 * pageviews + click events; specific user actions can fire custom
 * events via `trackEvent(...)`.
 *
 * Personal data: neither SDK gets the user's email or any PII.
 * `setUser({id})` carries only the Supabase UUID so support can
 * cross-reference an error to a user without leaking identity.
 */

import * as Sentry from "@sentry/react";
import posthog from "posthog-js";
import { env } from "./env";

let sentryReady = false;
let posthogReady = false;

export function initObservability(): void {
  if (env.SENTRY_DSN) {
    Sentry.init({
      dsn: env.SENTRY_DSN,
      environment: import.meta.env.MODE,
      release: import.meta.env.VITE_GIT_SHA ?? undefined,
      tracesSampleRate: env.SENTRY_TRACES_SAMPLE_RATE
        ? Number.parseFloat(env.SENTRY_TRACES_SAMPLE_RATE)
        : 0.1,
      // Default integrations include browser error + unhandled
      // rejection capture, which is what we want. We deliberately
      // skip session replay (heavy + privacy implications) and
      // browser tracing for performance (quota-friendly default).
      sendDefaultPii: false,
    });
    sentryReady = true;
  }

  if (env.POSTHOG_KEY) {
    posthog.init(env.POSTHOG_KEY, {
      api_host: env.POSTHOG_HOST,
      autocapture: true,
      // We're a B2B internal tool — heatmaps + session recording
      // add noise without much benefit, and the latter has obvious
      // privacy implications.
      disable_session_recording: true,
      capture_pageview: true,
      person_profiles: "identified_only",
    });
    posthogReady = true;
  }
}

export function identifyUser(args: {
  userId: string;
  email?: string;
}): void {
  if (sentryReady) {
    Sentry.setUser({ id: args.userId });
  }
  if (posthogReady) {
    // PostHog identify pins this browser to the given user id;
    // subsequent pageviews + events are attributed. We pass email
    // as a person property (PostHog dashboard search uses it),
    // accepting the trade-off for support efficiency.
    posthog.identify(args.userId, args.email ? { email: args.email } : undefined);
  }
}

export function resetUser(): void {
  if (sentryReady) {
    Sentry.setUser(null);
  }
  if (posthogReady) {
    posthog.reset();
  }
}

/**
 * Custom event. Use sparingly for product-level decisions (which
 * tag library is most edited; how often "Re-tag all" runs).
 * Pageviews + clicks are already autocaptured.
 */
export function trackEvent(
  name: string,
  properties?: Record<string, unknown>
): void {
  if (!posthogReady) return;
  posthog.capture(name, properties);
}

/** Manual Sentry capture. UI code generally doesn't call this
 *  directly — the global error handler picks up uncaught
 *  exceptions. Useful for soft-failures the user shouldn't see
 *  but support should. */
export function captureException(
  error: unknown,
  context?: Record<string, unknown>
): void {
  if (!sentryReady) return;
  Sentry.captureException(error, context ? { extra: context } : undefined);
}
