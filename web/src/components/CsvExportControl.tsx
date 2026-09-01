import { useState } from "react";
import type { AiAnalysisCsvOptions } from "@forensic/shared";
import { api, ApiError } from "../lib/api";
import { Modal } from "./Modal";

/**
 * "AI Analysis CSV" export trigger (Build #5.99.1).
 *
 * Full options modal replacing PR #2's inline shortcut. Mirrors
 * iOS's `AIAnalysisCSVExportRunner` controls:
 *
 *   - `onlyAnalyzed` — when true (default), photos without an
 *     `aiAnalysis` block are skipped.
 *   - `minConfidence` — tags below this threshold (0.0–1.0) are
 *     dropped from each row.
 *
 * The CSV layout (one row per primary tag per photo, RFC-4180
 * escaped, UTF-8 BOM) is fixed in the worker — same column shape
 * as iOS so a project exported on either platform produces the
 * same spreadsheet.
 */
interface Props {
  projectId: string;
  canExport: boolean;
  photoCount: number;
}

export function CsvExportControl({
  projectId,
  canExport,
  photoCount,
}: Props) {
  const [showModal, setShowModal] = useState(false);
  const [opts, setOpts] = useState<AiAnalysisCsvOptions>({
    onlyAnalyzed: true,
    minConfidence: 0.5,
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
        kind: "csv",
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
          : "Failed to enqueue CSV"
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
      >
        Export CSV…
      </button>

      {success && (
        <div className="mt-2 text-xs text-green-300">{success}</div>
      )}
      {error && <div className="mt-2 text-xs text-red-300">{error}</div>}

      {showModal && (
        <Modal title="AI Analysis CSV export" onClose={() => { if (!submitting) setShowModal(false); }}>
          <div className="flex w-full max-w-md flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div>
              <h2 className="text-base font-semibold text-neutral-100">
                AI Analysis CSV export
              </h2>
              <p className="text-xs text-neutral-400">
                One row per primary tag per photo. RFC-4180 escaped
                with UTF-8 BOM so Excel + Google Sheets open it
                directly. Column shape matches the iOS export.
              </p>
            </div>

            <label className="flex items-start gap-2 text-xs text-neutral-300">
              <input
                type="checkbox"
                checked={opts.onlyAnalyzed}
                onChange={(e) =>
                  setOpts({ ...opts, onlyAnalyzed: e.target.checked })
                }
                className="mt-0.5"
              />
              <span>
                Include only photos with AI analysis
                <span className="ml-1 text-neutral-500">
                  (uncheck to include user-tagged photos too)
                </span>
              </span>
            </label>

            <label className="flex flex-col gap-1 text-xs text-neutral-300">
              <span>
                Minimum tag confidence:{" "}
                <span className="font-mono text-neutral-100">
                  {opts.minConfidence.toFixed(2)}
                </span>
              </span>
              <input
                type="range"
                min={0}
                max={1}
                step={0.05}
                value={opts.minConfidence}
                onChange={(e) =>
                  setOpts({
                    ...opts,
                    minConfidence: Number.parseFloat(e.target.value),
                  })
                }
                className="accent-blue-500"
              />
              <span className="text-[10px] text-neutral-500">
                Tags below this confidence are dropped from each row.
                Matches iOS default of 0.5.
              </span>
            </label>

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
          </div>
        </Modal>
      )}
    </>
  );
}
