/**
 * Cloudflare R2 client + presigned-URL helpers.
 *
 * R2 is S3-compatible — we use AWS's SDK pointed at R2's endpoint
 * (`https://<account>.r2.cloudflarestorage.com`). Server holds the
 * credentials; clients only see short-lived presigned URLs for
 * individual objects.
 *
 * Why presigned URLs (not server-proxied uploads/downloads):
 *   - Render's free / Starter tiers cap throughput. Sending hundreds
 *     of MB of photo data through the server would saturate fast.
 *   - R2 is built to handle direct binary uploads. The server's job
 *     is to gate access, not to relay bytes.
 *   - Same pattern works identically for iOS uploads and web reads.
 */

import { S3Client, HeadObjectCommand, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { env } from "./env.js";

/** R2's S3-compatible endpoint, scoped to our account. */
const R2_ENDPOINT = `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;

/**
 * Shared S3 client targeting R2. Region is required by the SDK but
 * ignored by R2; "auto" is the documented placeholder.
 */
export const r2 = new S3Client({
  region: "auto",
  endpoint: R2_ENDPOINT,
  credentials: {
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
  },
});

/** Bucket name from env — used by every presigner. */
export const r2Bucket = env.R2_BUCKET;

/**
 * Build the canonical object key for a project/photo/kind tuple.
 * Keeps the layout consistent across upload and download paths.
 */
export function buildObjectKey(args: {
  projectId: string;
  photoId: string;
  kind: string;
}): string {
  return `${args.projectId}/${args.photoId}/${args.kind}`;
}

/**
 * Issue a presigned PUT URL that the client can upload to directly.
 * `contentLength` constrains the upload to the declared size so a
 * client that lies can't waste R2 bandwidth.
 */
export async function presignedPut(args: {
  objectKey: string;
  contentType: string;
  contentLength: number;
  expiresInSeconds: number;
}): Promise<string> {
  const command = new PutObjectCommand({
    Bucket: r2Bucket,
    Key: args.objectKey,
    ContentType: args.contentType,
    ContentLength: args.contentLength,
  });
  return getSignedUrl(r2, command, { expiresIn: args.expiresInSeconds });
}

/**
 * Issue a presigned GET URL the client can fetch directly. Used by
 * the photo redirect endpoints.
 */
export async function presignedGet(args: {
  objectKey: string;
  expiresInSeconds: number;
}): Promise<string> {
  const command = new GetObjectCommand({
    Bucket: r2Bucket,
    Key: args.objectKey,
  });
  return getSignedUrl(r2, command, { expiresIn: args.expiresInSeconds });
}

/**
 * Check whether an object already exists in R2. Used by
 * `POST /v1/sync/files/check` so iOS can skip re-uploads on
 * launch-time sync passes.
 */
export async function objectExists(objectKey: string): Promise<boolean> {
  try {
    await r2.send(
      new HeadObjectCommand({
        Bucket: r2Bucket,
        Key: objectKey,
      })
    );
    return true;
  } catch (err: unknown) {
    // S3 SDK throws NotFound / 404 errors with various typed shapes
    // depending on the version. Treat any 404-ish error as "doesn't
    // exist" rather than propagating; surface real errors (auth,
    // network) as 500.
    if (
      err instanceof Error &&
      ("name" in err || "$metadata" in err)
    ) {
      const e = err as Error & { name?: string; $metadata?: { httpStatusCode?: number } };
      if (e.name === "NotFound" || e.$metadata?.httpStatusCode === 404) {
        return false;
      }
    }
    throw err;
  }
}
