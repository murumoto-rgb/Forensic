import { useRef, useState } from "react";
import type { Photo, Project } from "@forensic/shared";
import { uploadFile } from "../lib/uploadFile";

/**
 * "+ Add photos" control on the Photos tab (Build #5.90.1).
 *
 * Hidden file input + a styled button. Accepts `image/*`, multi-
 * select. On change:
 *   1. Build a Photo struct per file with a fresh UUID, the next
 *      sequence number, and EXIF-free defaults that mirror iOS's
 *      `Photo.init`.
 *   2. Upload originals to R2 in parallel (cap 3 concurrent) via
 *      the existing presigned-PUT + commit endpoints.
 *   3. After every file lands, manifest.save the project with the
 *      new photos appended.
 *
 * Web does NOT generate thumbnails. The server's thumb endpoint
 * already falls back to `kind=photo` when no thumb row exists
 * (see `server/src/routes/photos.ts:223`), so the rich list keeps
 * working on web-uploaded photos. Generating client-side thumbs is
 * a follow-on quality-of-life improvement.
 */
interface Props {
  project: Project;
  canEdit: boolean;
  onProjectChanged: (next: Project) => void;
}

const MAX_CONCURRENT = 3;
const ACCEPTED_TYPES = "image/*";

interface RunningUpload {
  photoId: string;
  filename: string;
  state: "uploading" | "done" | "failed";
  error?: string;
}

export function AddPhotosControl({
  project,
  canEdit,
  onProjectChanged,
}: Props) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const [uploads, setUploads] = useState<RunningUpload[]>([]);
  const [busy, setBusy] = useState(false);
  const latest = useRef({ project, canEdit });
  latest.current = { project, canEdit };

  function openPicker() {
    if (!canEdit || busy) return;
    inputRef.current?.click();
  }

  async function onFilesChosen(e: React.ChangeEvent<HTMLInputElement>) {
    const files = e.currentTarget.files;
    if (!files || files.length === 0) return;
    e.currentTarget.value = ""; // Allow re-picking the same files later
    void runBatch(Array.from(files));
  }

  async function runBatch(files: File[]) {
    if (!latest.current.canEdit || busy) return;
    setBusy(true);
    // Build all the photo structs up front so sequenceNumber + IDs
    // are stable across the run and the final manifest write can
    // append them in the order picked.
    const baseSeq = project.photos.length + 1;
    const records = files.map((file, i) => {
      const photoId = crypto.randomUUID();
      const ext = filenameExtension(file.name) ?? "jpg";
      const newPhoto: Photo = {
        id: photoId,
        sequenceNumber: baseSeq + i,
        timestamp: deriveTimestamp(file),
        imageFilename: `${photoId}.${ext}`,
        thumbnailFilename: null,
        floorPlanID: null,
        localXFeet: null,
        localYFeet: null,
        planPixelX: null,
        planPixelY: null,
        headingDegrees: null,
        positionSource: "none",
        groupID: null,
        isPrimary: true,
        cameraZoom: 1,
        lensName: null,
        flashMode: "auto",
        aiDescription: null,
        aiSeverity: null,
        aiObservation: null,
        aiFollowUp: null,
        aiAnalysis: null,
        tags: [],
        pendingSuggestions: [],
        bucketID: null,
        markupOverlayFilename: null,
        markupDrawingFilename: null,
        reshootsPhotoID: null,
        isFavorite: false,
        trashedAt: null,
        userCaption: null,
        userObservation: null,
        previewRotation: 0,
      };
      return { file, photoId, newPhoto };
    });

    setUploads(
      records.map((r) => ({
        photoId: r.photoId,
        filename: r.file.name,
        state: "uploading" as const,
      }))
    );

    // Bounded-concurrency worker pattern (same shape useBatchRetag
    // uses for AI tagging).
    const successful: Photo[] = [];
    let nextIdx = 0;
    async function worker() {
      while (true) {
        const i = nextIdx++;
        if (i >= records.length) return;
        const { file, photoId, newPhoto } = records[i]!;
        try {
          await uploadFile({
            projectId: project.id,
            photoId,
            kind: "photo",
            sourceFilename: newPhoto.imageFilename,
            file,
            contentType: file.type || "image/jpeg",
          });
          successful.push(newPhoto);
          setUploads((cur) =>
            cur.map((u) =>
              u.photoId === photoId ? { ...u, state: "done" } : u
            )
          );
        } catch (e: unknown) {
          const message = e instanceof Error ? e.message : "Upload failed";
          setUploads((cur) =>
            cur.map((u) =>
              u.photoId === photoId
                ? { ...u, state: "failed", error: message }
                : u
            )
          );
        }
      }
    }

    const workers: Promise<void>[] = [];
    for (let i = 0; i < Math.min(MAX_CONCURRENT, records.length); i++) {
      workers.push(worker());
    }
    await Promise.all(workers);

    if (successful.length > 0 && latest.current.canEdit) {
      // Append in the original picker order — sort by sequenceNumber
      // so the appended block is contiguous even when uploads
      // finished out of order.
      successful.sort((a, b) => a.sequenceNumber - b.sequenceNumber);
      const current = latest.current.project;
      const nextSequence = Math.max(0, ...current.photos.map((p) => p.sequenceNumber), ...current.trashedPhotos.map((p) => p.sequenceNumber)) + 1;
      onProjectChanged({ ...current, photos: [...current.photos,
        ...successful.map((p, i) => ({ ...p, sequenceNumber: nextSequence + i }))] });
    }
    setBusy(false);
  }

  function dismiss() {
    setUploads([]);
  }

  return (
    <>
      <input
        ref={inputRef}
        type="file"
        accept={ACCEPTED_TYPES}
        multiple
        onChange={onFilesChosen}
        className="hidden"
      />
      <button
        type="button"
        onClick={openPicker}
        disabled={!canEdit || busy}
        className="rounded border border-blue-700 bg-blue-900/40 px-3 py-1 text-sm text-blue-100 hover:bg-blue-900/60 disabled:cursor-not-allowed disabled:opacity-50"
        title={
          canEdit
            ? "Upload one or more photos from disk."
            : "Take the edit lock to upload photos."
        }
      >
        + Add photos
      </button>

      {uploads.length > 0 && (
        <div className="fixed bottom-4 right-4 z-40 w-80 rounded-lg border border-neutral-700 bg-neutral-900 shadow-2xl">
          <div className="flex items-center justify-between border-b border-neutral-800 px-3 py-2 text-sm font-semibold text-neutral-100">
            <span>
              Uploading {uploads.filter((u) => u.state !== "uploading").length}
              {" / "}
              {uploads.length}
            </span>
            {!busy && (
              <button
                type="button"
                onClick={dismiss}
                className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800"
              >
                Dismiss
              </button>
            )}
          </div>
          <ul className="max-h-60 overflow-y-auto">
            {uploads.map((u) => (
              <li
                key={u.photoId}
                className="flex items-center gap-2 border-t border-neutral-800 px-3 py-1.5 text-xs first:border-t-0"
              >
                <span className="flex-1 truncate text-neutral-300">
                  {u.filename}
                </span>
                <span
                  className={
                    u.state === "done"
                      ? "text-green-400"
                      : u.state === "failed"
                        ? "text-red-400"
                        : "text-neutral-400"
                  }
                  title={u.error}
                >
                  {u.state === "uploading" && "…"}
                  {u.state === "done" && "✓"}
                  {u.state === "failed" && "✗"}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </>
  );
}

function filenameExtension(name: string): string | null {
  const dot = name.lastIndexOf(".");
  if (dot < 0 || dot === name.length - 1) return null;
  return name.slice(dot + 1).toLowerCase();
}

function deriveTimestamp(file: File): string {
  // File.lastModified is a unix-ms timestamp; modern browsers set it
  // from the file's mtime on disk. EXIF parsing would be more
  // accurate but requires a heavier dep — fall back to ISO of
  // lastModified, then `new Date().toISOString()` if unavailable.
  const ms = file.lastModified;
  if (Number.isFinite(ms) && ms > 0) {
    return new Date(ms).toISOString();
  }
  return new Date().toISOString();
}
