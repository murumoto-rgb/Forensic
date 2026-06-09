/**
 * One-shot: set the R2 bucket's CORS policy so browsers can fetch
 * objects directly via presigned URLs (Build #5.111.1).
 *
 * The client-side folder export (#5.110.1) has the browser
 * `fetch()` photos straight from R2. R2 rejects cross-origin
 * browser reads unless the bucket has a CORS policy allowing the
 * web app's origin. iOS uploads + the server-side worker aren't
 * affected (URLSession + server-to-server bypass CORS).
 *
 * R2 is S3-compatible, so we set CORS via the S3 `PutBucketCors`
 * API using the same credentials the server already holds. This
 * requires the R2 API token to have bucket-config write scope (the
 * "Admin Read & Write" or "Object Read & Write" token types both
 * include it on R2; "Object Read only" does not).
 *
 * Run once from the repo root:
 *   cd server && tsx --env-file=.env.local scripts/set-r2-cors.ts
 *
 * Or with explicit env:
 *   R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... \
 *   R2_BUCKET=forensic-photos \
 *   ALLOWED_ORIGINS='https://forensic-web.vercel.app,http://localhost:5173' \
 *   tsx scripts/set-r2-cors.ts
 *
 * Idempotent — re-running overwrites the CORS config with the same
 * value. Safe to run as many times as needed.
 */

import {
  S3Client,
  PutBucketCorsCommand,
  GetBucketCorsCommand,
} from "@aws-sdk/client-s3";

function reqEnv(name: string): string {
  const v = process.env[name];
  if (!v || v.trim().length === 0) {
    console.error(`Missing required env var: ${name}`);
    process.exit(1);
  }
  return v;
}

const R2_ACCOUNT_ID = reqEnv("R2_ACCOUNT_ID");
const R2_ACCESS_KEY_ID = reqEnv("R2_ACCESS_KEY_ID");
const R2_SECRET_ACCESS_KEY = reqEnv("R2_SECRET_ACCESS_KEY");
const R2_BUCKET = reqEnv("R2_BUCKET");

// Origins allowed to fetch objects directly in the browser. Default
// covers the production Vercel domain + local dev; override with
// ALLOWED_ORIGINS (comma-separated) to add a custom domain.
const allowedOrigins = (
  process.env.ALLOWED_ORIGINS ??
  "https://forensic-web.vercel.app,http://localhost:5173"
)
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

const endpoint = `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
const r2 = new S3Client({
  region: "auto",
  endpoint,
  credentials: {
    accessKeyId: R2_ACCESS_KEY_ID,
    secretAccessKey: R2_SECRET_ACCESS_KEY,
  },
});

async function main(): Promise<void> {
  console.log(`Setting CORS on bucket "${R2_BUCKET}"`);
  console.log(`Allowed origins:`);
  for (const o of allowedOrigins) console.log(`  - ${o}`);

  await r2.send(
    new PutBucketCorsCommand({
      Bucket: R2_BUCKET,
      CORSConfiguration: {
        CORSRules: [
          {
            AllowedOrigins: allowedOrigins,
            AllowedMethods: ["GET", "HEAD"],
            AllowedHeaders: ["*"],
            ExposeHeaders: ["ETag", "Content-Length"],
            MaxAgeSeconds: 3600,
          },
        ],
      },
    })
  );
  console.log("✓ PutBucketCors succeeded.");

  // Read it back to confirm.
  const got = await r2.send(
    new GetBucketCorsCommand({ Bucket: R2_BUCKET })
  );
  console.log("\nCurrent CORS config on the bucket:");
  console.log(JSON.stringify(got.CORSRules, null, 2));
  console.log(
    "\nCORS rules take effect within ~30 seconds. Hard-refresh the web app and retry the export."
  );
}

main().catch((err) => {
  console.error("\n✗ Failed to set CORS.");
  if (err instanceof Error) {
    console.error(err.message);
  }
  console.error(
    "\nIf this is a permissions error (AccessDenied / 403), the R2 API token\n" +
      "lacks bucket-config write scope. Either:\n" +
      "  1. Create a new R2 API token with 'Admin Read & Write' and re-run, OR\n" +
      "  2. Set CORS via the Cloudflare dashboard: R2 → forensic-photos →\n" +
      "     Settings → CORS Policy → Add, with the JSON in this script's CORSRules."
  );
  process.exit(1);
});
