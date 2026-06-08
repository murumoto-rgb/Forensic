import { FILE_MAX_BYTES, type FileKind } from "@forensic/shared";
import { api, ApiError } from "./api";

/**
 * Three-step upload: request presigned URL → PUT to R2 → commit
 * registry row.
 *
 * The R2 PUT must NOT include the app's Bearer token (R2 doesn't
 * know about it and rejects unrecognised auth headers). We use a
 * plain `fetch` instead of going through `api.request` so the
 * Authorization header isn't injected.
 *
 * Throws on any failure; caller catches and surfaces.
 */
export async function uploadFile(args: {
  projectId: string;
  photoId: string;
  kind: FileKind;
  file: File | Blob;
  contentType: string;
}): Promise<void> {
  const { projectId, photoId, kind, file, contentType } = args;
  if (file.size > FILE_MAX_BYTES) {
    throw new Error(
      `File too large (${(file.size / 1_000_000).toFixed(1)} MB). Limit is 50 MB.`
    );
  }

  const { uploadUrl, objectKey } = await api.requestUploadUrl(projectId, {
    photoId,
    kind,
    sizeBytes: file.size,
    contentType,
  });

  const r2Response = await fetch(uploadUrl, {
    method: "PUT",
    headers: { "content-type": contentType },
    body: file,
  });
  if (!r2Response.ok) {
    throw new Error(
      `R2 upload failed: HTTP ${r2Response.status} ${r2Response.statusText}`
    );
  }

  // Server HEADs R2 + records the files row. 409 if R2 didn't land
  // (race / network failure); surface for retry.
  try {
    await api.commitUpload(projectId, {
      objectKey,
      photoId,
      kind,
      sizeBytes: file.size,
    });
  } catch (e: unknown) {
    if (e instanceof ApiError) {
      throw new Error(`Commit failed: ${e.errorCode} — ${e.message}`);
    }
    throw e;
  }
}
