/**
 * Client-side env-var loader. Vite exposes any `VITE_*` env var via
 * `import.meta.env`. We fail loud at module-load time if anything is
 * missing — easier to debug than silent undefined-prop errors.
 */

function required(name: string): string {
  const value = import.meta.env[name];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(
      `Missing required env var ${name}. ` +
        "Copy web/.env.local.example to web/.env.local and fill in values."
    );
  }
  return value;
}

function optional(name: string): string | undefined {
  const value = import.meta.env[name];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

export const env = {
  SUPABASE_URL: required("VITE_SUPABASE_URL"),
  SUPABASE_PUBLISHABLE_KEY: required("VITE_SUPABASE_PUBLISHABLE_KEY"),
  API_URL: required("VITE_API_URL"),
  // Optional observability — when unset, Sentry + PostHog SDKs
  // initialise but stay quiet (`init(...)` is skipped). Lets the
  // app run locally without Vercel env-var setup.
  SENTRY_DSN: optional("VITE_SENTRY_DSN"),
  SENTRY_TRACES_SAMPLE_RATE: optional("VITE_SENTRY_TRACES_SAMPLE_RATE"),
  POSTHOG_KEY: optional("VITE_POSTHOG_KEY"),
  POSTHOG_HOST: optional("VITE_POSTHOG_HOST") ?? "https://us.i.posthog.com",
} as const;
