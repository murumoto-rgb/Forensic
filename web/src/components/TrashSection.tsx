import { useState } from "react";
import type { Photo, Project } from "@forensic/shared";

/**
 * Trash management (Build #5.83.1 — Path P #8/8).
 *
 * Collapsible section at the bottom of the Photos tab. Lists every
 * photo in `project.trashedPhotos`. Per-photo:
 *
 *   - **Restore** — clears `trashedAt`, moves the photo back from
 *     `trashedPhotos[]` to `photos[]`. The pre-existing
 *     `sequenceNumber` is preserved (iOS does the same).
 *   - **Delete permanently** — drops the photo from
 *     `trashedPhotos[]` entirely. Soft-deleted blobs are reaped by
 *     the server's blob-GC pass; we don't have a synchronous
 *     server-side delete today and don't need one (the manifest
 *     PUT alone is enough to make the photo invisible).
 *
 * Bulk:
 *
 *   - **Empty trash** — drops every entry from `trashedPhotos[]`.
 *     Confirm dialog warns about permanent loss first.
 *
 * The list is intentionally information-dense without the
 * thumbnail grid — restoring is usually a "the seq # I deleted
 * five minutes ago" workflow, not a visual one, and skipping the
 * URL batch keeps this section cheap on a project with hundreds
 * of trashed photos.
 */
interface Props {
  project: Project;
  canEdit: boolean;
  onProjectChanged: (next: Project) => void;
}

export function TrashSection({ project, canEdit, onProjectChanged }: Props) {
  const [expanded, setExpanded] = useState(false);
  const [confirmEmpty, setConfirmEmpty] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<Photo | null>(null);

  const trashed = [...project.trashedPhotos].sort(
    (a, b) =>
      new Date(b.trashedAt ?? 0).getTime() -
      new Date(a.trashedAt ?? 0).getTime()
  );

  if (trashed.length === 0) {
    // Don't render anything for an empty trash — collapsing the
    // header takes space the rest of the tab can use better.
    return null;
  }

  function restore(photo: Photo) {
    onProjectChanged({
      ...project,
      photos: [...project.photos, { ...photo, trashedAt: null }],
      trashedPhotos: project.trashedPhotos.filter((p) => p.id !== photo.id),
    });
  }
  function deletePermanently(photo: Photo) {
    onProjectChanged({
      ...project,
      trashedPhotos: project.trashedPhotos.filter((p) => p.id !== photo.id),
    });
    setConfirmDelete(null);
  }
  function emptyTrash() {
    onProjectChanged({ ...project, trashedPhotos: [] });
    setConfirmEmpty(false);
  }

  return (
    <section className="mt-6 rounded border border-neutral-800 bg-neutral-900/40">
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        className="flex w-full items-center justify-between px-3 py-2 text-left text-sm text-neutral-300 hover:bg-neutral-800/40"
      >
        <span>
          🗑 Trash · {trashed.length} photo{trashed.length === 1 ? "" : "s"}
        </span>
        <span className="text-xs text-neutral-500">
          {expanded ? "Hide" : "Show"}
        </span>
      </button>
      {expanded && (
        <div className="border-t border-neutral-800 px-3 py-3">
          <div className="mb-2 flex items-center justify-end gap-2">
            <button
              type="button"
              onClick={() => setConfirmEmpty(true)}
              disabled={!canEdit}
              className="rounded border border-red-700 px-2 py-1 text-xs text-red-200 hover:bg-red-950/40 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Empty trash
            </button>
          </div>
          <ul className="flex flex-col gap-1">
            {trashed.map((photo) => (
              <li
                key={photo.id}
                className="flex items-center gap-2 rounded border border-neutral-800 bg-neutral-950/40 px-2 py-1 text-xs"
              >
                <span className="font-mono text-neutral-300">
                  #{photo.sequenceNumber}
                </span>
                {photo.userCaption && (
                  <span className="truncate text-neutral-400">
                    {photo.userCaption}
                  </span>
                )}
                <span className="ml-auto text-[10px] text-neutral-500">
                  Trashed{" "}
                  {photo.trashedAt
                    ? new Date(photo.trashedAt).toLocaleString()
                    : "(unknown)"}
                </span>
                <button
                  type="button"
                  onClick={() => restore(photo)}
                  disabled={!canEdit}
                  className="rounded border border-neutral-700 px-2 py-0.5 text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Restore
                </button>
                <button
                  type="button"
                  onClick={() => setConfirmDelete(photo)}
                  disabled={!canEdit}
                  className="rounded border border-red-700 px-2 py-0.5 text-red-200 hover:bg-red-950/40 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Delete
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      {confirmEmpty && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-200">
              Empty trash — permanently remove{" "}
              <span className="font-semibold">{trashed.length}</span>{" "}
              photo{trashed.length === 1 ? "" : "s"}?
              <div className="mt-2 text-xs text-neutral-400">
                There's no undo for this step. Restore individual photos
                first if you might still want them.
              </div>
            </div>
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmEmpty(false)}
                className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={emptyTrash}
                className="rounded border border-red-600 bg-red-700/40 px-4 py-1.5 text-sm text-red-100 hover:bg-red-700/60"
              >
                Empty trash
              </button>
            </div>
          </div>
        </div>
      )}

      {confirmDelete && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-200">
              Delete photo{" "}
              <span className="font-semibold">
                #{confirmDelete.sequenceNumber}
              </span>{" "}
              permanently?
              <div className="mt-2 text-xs text-neutral-400">
                Removes it from the trash. There's no undo for this step.
              </div>
            </div>
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmDelete(null)}
                className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => deletePermanently(confirmDelete)}
                className="rounded border border-red-600 bg-red-700/40 px-4 py-1.5 text-sm text-red-100 hover:bg-red-700/60"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}
