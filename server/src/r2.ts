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

import {
  S3Client,
  HeadObjectCommand,
  GetObjectCommand,
  PutObjectCommand,
  DeleteObjectsCommand,
} from "@aws-sdk/client-s3";
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
 * Read an object's raw bytes from R2. Used by the AI-tagging proxy
 * (Build #5.32.1) — the server fetches the photo bytes server-side
 * so the client doesn't have to upload them, and so the Anthropic
 * call originates from the server's outbound IP, not the user's
 * browser. Throws on any error including 404; callers wrap with
 * appropriate HTTP error mapping.
 */
export async function getObjectBytes(objectKey: string): Promise<Buffer> {
  const resp = await r2.send(
    new GetObjectCommand({
      Bucket: r2Bucket,
      Key: objectKey,
    })
  );
  if (!resp.Body) {
    throw new Error(`R2 GetObject returned no body for ${objectKey}`);
  }
  const bytes = await resp.Body.transformToByteArray();
  return Buffer.from(bytes);
}

/**
 * Server-side upload helper — pushes a buffer straight into R2. Used
 * by the PDF export worker (Build #5.62.1) to land the rendered PDF
 * without round-tripping through a presigned URL. Photo uploads from
 * iOS / web stay on the presigned-PUT path so the byte stream avoids
 * the server entirely; this helper is for the small number of cases
 * where the server itself generates the artifact.
 */
export async function putObjectBytes(args: {
  objectKey: string;
  body: Buffer;
  contentType: string;
}): Promise<void> {
  await r2.send(
    new PutObjectCommand({
      Bucket: r2Bucket,
      Key: args.objectKey,
      Body: args.body,
      ContentType: args.contentType,
      ContentLength: args.body.byteLength,
    })
  );
}

/**
 * Batch-delete a set of objects from R2. Used by the permanent-
 * delete project endpoint (Build #5.93.1) to reap every blob a
 * project owned. Chunks at 1000 (the S3 / R2 DeleteObjects limit).
 *
 * Best-effort: per-object errors come back in the response's
 * `Errors[]` array but we log + continue rather than throwing —
 * the manifest row + files-table rows are deleted unconditionally,
 * so a stray R2 blob is an unused-storage cost, not a correctness
 * issue. The unused-blob reaper (separate concern) cleans those up.
 */
export async function deleteObjects(objectKeys: string[]): Promise<void> {
  if (objectKeys.length === 0) return;
  const CHUNK = 1000;
  for (let i = 0; i < objectKeys.length; i += CHUNK) {
    const chunk = objectKeys.slice(i, i + CHUNK);
    await r2.send(
      new DeleteObjectsCommand({
        Bucket: r2Bucket,
        Delete: {
          Objects: chunk.map((Key) => ({ Key })),
          Quiet: true,
        },
      })
    );
  }
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
