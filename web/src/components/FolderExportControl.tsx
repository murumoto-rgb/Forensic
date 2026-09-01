import { useState } from "react";
import type { FolderExportOptions } from "@forensic/shared";
import { api, ApiError } from "../lib/api";
import { Modal } from "./Modal";

/**
 * "Folder by Bucket" export trigger (Build #5.98.1).
 *
 * Mirrors iOS's `FolderExportRunner` — opens an options modal,
 * then enqueues a `kind=folder` job on the unified exports
 * pipeline. The actual zip + download lives on the Exports
 * page (`/projects/:id/exports`).
 *
 * Scope toggle today: all photos (default). The "filtered" /
 * "selected" scopes will hook into PhotosTab in a follow-on —
 * for now the most common workflow (export everything) ships.
 */
interface Props {
  projectId: string;
  canExport: boolean;
  photoCount: number;
}

export function FolderExportControl({
  projectId,
  canExport,
  photoCount,
}: Props) {
  const [showModal, setShowModal] = useState(false);
  const [opts, setOpts] = useState<FolderExportOptions>({
    burnTimestampAndGPS: false,
    scope: "all",
    selectedPhotoIds: null,
  });
  const [submitting, setSubmitting] = useState(false);
  const [success, setSuccess] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function submit() {
    setSubmitting(true);
    setError(null);
    setSuccess(null);
    try {
      const resp = await api.createProjectExport(projectId, {
        kind: "folder",
        options: opts,
      });
      setSuccess(
        `Queued — track progress on the Exports page (id ${resp.export.id.slice(0, 8)}…).`
      );
      setShowModal(false);
    } catch (e: unknown) {
      setError(
        e instanceof ApiError
          ? `${e.errorCode}: ${e.message}`
          : "Failed to enqueue export"
      );
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <>
      <button
        type="button"
        onClick={() => setShowModal(true)}
        disabled={!canExport || photoCount === 0}
        className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:opacity-50"
        title={
          !canExport
            ? "Take the edit lock to export."
            : photoCount === 0
              ? "Add photos before exporting."
              : "Export every photo into a per-bucket folder bundle."
        }
      >
        Export folder bundle…
      </button>

      {success && (
        <div className="mt-2 text-xs text-green-300">{success}</div>
      )}
      {error && <div className="mt-2 text-xs text-red-300">{error}</div>}

      {showModal && (
        <Modal title="Folder by Bucket export" onClose={() => { if (!submitting) setShowModal(false); }}>
            <div>
              <h2 className="text-base font-semibold text-neutral-100">
                Folder by Bucket export
              </h2>
              <p className="text-xs text-neutral-400">
                One subfolder per bucket. Photos copied in full
                resolution with EXIF preserved bit-for-bit. Plus a
                `captions.txt` per folder. Matches iOS's
                FolderExportRunner output.
              </p>
            </div>

            <label className="flex items-start gap-2 text-xs text-neutral-300">
              <input
                type="checkbox"
                checked={opts.burnTimestampAndGPS}
                onChange={(e) =>
                  setOpts({ ...opts, burnTimestampAndGPS: e.target.checked })
                }
                className="mt-0.5"
              />
              <span>
                Burn capture timestamp + GPS into the JPGs
                <span className="ml-1 text-neutral-500">
                  (litigation-grade; re-encodes the image and loses original EXIF)
                </span>
                <br />
                <span className="text-[10px] text-amber-400">
                  Note: not yet implemented server-side — toggle accepted but ignored in this build.
                </span>
              </span>
            </label>

            <div className="text-xs text-neutral-500">
              Scope: <span className="text-neutral-300">all photos ({photoCount})</span>
            </div>

            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setShowModal(false)}
                disabled={submitting}
                className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800 disabled:opacity-50"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={submit}
                disabled={submitting}
                className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1 text-xs font-medium text-white hover:bg-blue-600 disabled:opacity-50"
              >
                {submitting ? "Queuing…" : "Start export"}
              </button>
            </div>
        </Modal>
      )}
    </>
  );
}
