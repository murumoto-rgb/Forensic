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

export const env = {
  SUPABASE_URL: required("VITE_SUPABASE_URL"),
  SUPABASE_PUBLISHABLE_KEY: required("VITE_SUPABASE_PUBLISHABLE_KEY"),
  API_URL: required("VITE_API_URL"),
} as const;
