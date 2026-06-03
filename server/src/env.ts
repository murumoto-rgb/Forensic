/**
 * Environment-variable loading + validation.
 *
 * Server refuses to start if any required value is missing or
 * malformed. This is on purpose — a server that boots up with
 * placeholder credentials and *silently* returns 401s on every
 * Supabase call is harder to debug than one that refuses to
 * start with a clear "SUPABASE_SECRET_KEY is not set".
 */

import { z } from "zod";

const EnvSchema = z.object({
  PORT: z.coerce.number().int().positive().default(3000),
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),

  SUPABASE_URL: z.string().url(),
  SUPABASE_PUBLISHABLE_KEY: z.string().min(1),
  SUPABASE_SECRET_KEY: z.string().min(1),

  // Cloudflare R2 — S3-compatible object store for photo binaries.
  // Account ID is shown on the R2 dashboard; access keys come from a
  // bucket-scoped R2 API token created with "Object Read & Write"
  // permission on the bucket.
  R2_ACCOUNT_ID: z.string().min(1),
  R2_ACCESS_KEY_ID: z.string().min(1),
  R2_SECRET_ACCESS_KEY: z.string().min(1),
  R2_BUCKET: z.string().min(1),

  // Comma-separated list of allowed origins for CORS. Empty string
  // means "no cross-origin requests allowed" (locks the server
  // down for same-origin only — fine if web is hosted under the
  // same domain).
  CORS_ORIGINS: z.string().default(""),

  // Anthropic API key for the AI-tagging proxy (Build #5.32.1).
  // OPTIONAL at boot — the rest of the server starts fine without it;
  // hitting `/v1/ai/tag-photo` without the key returns a clean 503
  // "AI tagging not configured" rather than crashing the process.
  // Lets us deploy the endpoint before the env var is set, then add
  // it in Render's dashboard separately.
  ANTHROPIC_API_KEY: z.string().min(1).optional(),
});

function loadEnv() {
  const parsed = EnvSchema.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `  ${i.path.join(".")}: ${i.message}`)
      .join("\n");
    console.error(
      `Server cannot start — invalid or missing environment variables:\n${issues}\n\n` +
        "See server/.env.local.example for the full list and copy it to " +
        "server/.env.local with real values."
    );
    process.exit(1);
  }
  return parsed.data;
}

export const env = loadEnv();

/** Parsed comma-separated CORS origins. */
export const corsOrigins = env.CORS_ORIGINS
  .split(",")
  .map((s) => s.trim())
  .filter((s) => s.length > 0);
