import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import type { ProjectExport } from "@forensic/shared";
import { api, ApiError } from "../lib/api";

/**
 * Project Exports page (Build #5.98.1).
 *
 * Persistent listing of every export the user has generated for
 * this project — PDF reports, Folder bundles, AI Analysis CSVs.
 * Each row carries a status pill, size, age, Download button (when
 * done), and Delete button.
 *
 * In-flight (queued / running) exports are polled every 3 seconds
 * so progress flips to "done" without a page refresh.
 *
 * PDF exports created via the legacy `pdf_export_jobs` flow don't
 * show here yet — Round 3 PR #2 ships folder + CSV; a PDF
 * unification adapter ships separately.
 */
interface Props {
  session: Session;
}

export function ProjectExportsPage({ session: _session }: Props) {
  const { id: projectId } = useParams<{ id: string }>();
  const [exports, setExports] = useState<ProjectExport[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!projectId) return;
    try {
      const resp = await api.listProjectExports(projectId);
      setExports(resp.exports);
      setError(null);
    } catch (e: unknown) {
      setError(
        e instanceof ApiError
          ? `${e.errorCode}: ${e.message}`
          : "Failed to load exports"
      );
    }
  }, [projectId]);

  useEffect(() => {
    void reload();
  }, [reload]);

  // Poll while any export is in-flight.
  useEffect(() => {
    if (!exports) return;
    const inFlight = exports.some(
      (e) => e.status === "queued" || e.status === "running"
    );
    if (!inFlight) return;
    const id = setInterval(() => {
      void reload();
    }, 3000);
    return () => clearInterval(id);
  }, [exports, reload]);

  async function downloadOne(exportId: string) {
    try {
      const resp = await api.getProjectExport(exportId);
      if (!resp.downloadUrl) {
        setError("Download URL not ready — try again in a few seconds.");
        return;
      }
      // Trigger via anchor click so the browser handles the
      // content-disposition + filename.
      const a = document.createElement("a");
      a.href = resp.downloadUrl;
      a.rel = "noopener noreferrer";
      a.click();
    } catch (e: unknown) {
      setError(
        e instanceof ApiError
          ? `${e.errorCode}: ${e.message}`
          : "Download failed"
      );
    }
  }

  async function deleteOne(exportId: string) {
    if (
      !window.confirm(
        "Delete this export permanently? The R2 blob is reaped; this can't be undone."
      )
    ) {
      return;
    }
    try {
      await api.deleteProjectExport(exportId);
      await reload();
    } catch (e: unknown) {
      setError(
        e instanceof ApiError
          ? `${e.errorCode}: ${e.message}`
          : "Delete failed"
      );
    }
  }

  return (
    <div className="mx-auto max-w-4xl px-6 py-10">
      <header className="mb-6 flex items-center justify-between">
        <div>
          {projectId && (
            <Link
              to={`/projects/${projectId}`}
              className="text-xs text-neutral-500 hover:text-neutral-300"
            >
              ← Back to project
            </Link>
          )}
          <h1 className="text-2xl font-semibold">Exports</h1>
          <p className="text-xs text-neutral-500">
            Every PDF, folder bundle, and CSV you've generated for
            this project. Links survive page refresh until deleted.
          </p>
        </div>
      </header>

      {error && (
        <div className="mb-4 rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
          {error}
        </div>
      )}

      {exports === null && !error && (
        <div className="text-sm text-neutral-500">Loading…</div>
      )}

      {exports !== null && exports.length === 0 && (
        <div className="rounded border border-dashed border-neutral-800 p-10 text-center text-sm text-neutral-500">
          No exports yet. Use the Export tab inside the project to
          generate one — they'll appear here.
        </div>
      )}

      {exports !== null && exports.length > 0 && (
        <ul className="divide-y divide-neutral-900 rounded border border-neutral-800 bg-neutral-950">
          {exports.map((e) => (
            <ExportRow
              key={e.id}
              exp={e}
              onDownload={() => downloadOne(e.id)}
              onDelete={() => deleteOne(e.id)}
            />
          ))}
        </ul>
      )}
    </div>
  );
}

function ExportRow({
  exp,
  onDownload,
  onDelete,
}: {
  exp: ProjectExport;
  onDownload: () => void;
  onDelete: () => void;
}) {
  const inFlight = exp.status === "queued" || exp.status === "running";
  return (
    <li className="flex flex-wrap items-center gap-3 px-4 py-3 text-sm">
      <KindIcon kind={exp.kind} />
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="font-medium text-neutral-100">
            {kindLabel(exp.kind)}
          </span>
          <StatusPill status={exp.status} />
        </div>
        <div className="text-xs text-neutral-500">
          {new Date(exp.createdAt).toLocaleString()}
          {exp.sizeBytes != null && (
            <>
              {" · "}
              {humanBytes(exp.sizeBytes)}
            </>
          )}
        </div>
        {exp.errorMessage && (
          <div className="mt-1 text-xs text-red-300">{exp.errorMessage}</div>
        )}
      </div>
      <div className="flex items-center gap-2">
        {exp.status === "done" && (
          <button
            type="button"
            onClick={onDownload}
            className="rounded border border-blue-700 bg-blue-900/40 px-3 py-1 text-xs text-blue-100 hover:bg-blue-900/70"
          >
            Download
          </button>
        )}
        <button
          type="button"
          onClick={onDelete}
          disabled={inFlight}
          className="rounded border border-red-800 px-3 py-1 text-xs text-red-300 hover:bg-red-950/40 disabled:cursor-not-allowed disabled:opacity-50"
          title={inFlight ? "Wait for it to finish before deleting." : "Delete this export."}
        >
          Delete
        </button>
      </div>
    </li>
  );
}

function KindIcon({ kind }: { kind: ProjectExport["kind"] }) {
  const emoji = kind === "pdf" ? "📄" : kind === "folder" ? "📁" : "📊";
  return <span className="text-2xl">{emoji}</span>;
}

function kindLabel(kind: ProjectExport["kind"]): string {
  switch (kind) {
    case "pdf":
      return "PDF report";
    case "folder":
      return "Folder by Bucket";
    case "csv":
      return "AI Analysis CSV";
  }
}

function StatusPill({ status }: { status: ProjectExport["status"] }) {
  const palette =
    status === "done"
      ? "border-green-700 bg-green-950/40 text-green-200"
      : status === "failed"
        ? "border-red-700 bg-red-950/40 text-red-200"
        : "border-amber-700 bg-amber-950/30 text-amber-200";
  return (
    <span
      className={`rounded border px-2 py-0.5 text-[10px] uppercase tracking-wide ${palette}`}
    >
      {status}
    </span>
  );
}

function humanBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}
