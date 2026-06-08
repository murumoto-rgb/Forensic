import { useCallback, useEffect, useRef, useState } from "react";
import JSZip from "jszip";
import type {
  FolderExportManifest,
  FolderExportManifestPhoto,
} from "@forensic/shared";
import { api, ApiError } from "../lib/api";

/**
 * Client-side folder export (Build #5.110.1).
 *
 * Replaces the server-side streaming worker with a browser-driven
 * pipeline: the server hands back a manifest of presigned R2 URLs,
 * the browser downloads photos in parallel directly from R2, builds
 * the ZIP in memory via JSZip, and triggers a Blob download.
 *
 * Why this exists: the server-side worker on Render's free tier
 * runs out of resources for 200+ photo projects. Doing the work in
 * the browser uses the user's machine instead — much more RAM,
 * faster CPU, and direct R2 throughput from their ISP.
 *
 * Limits:
 *   - Tab must stay open for the duration.
 *   - Browser memory caps somewhere around 4 GB on most modern
 *     browsers; a 1000+ photo project may hit that.
 *   - No resume on tab close — the in-progress ZIP is lost.
 */
interface Props {
  projectId: string;
  canExport: boolean;
  photoCount: number;
}

type State =
  | { kind: "idle" }
  | { kind: "fetching-manifest" }
  | { kind: "downloading"; done: number; total: number; failed: number }
  | { kind: "zipping"; pct: number }
  | { kind: "done"; sizeMb: number }
  | { kind: "error"; message: string };

const FETCH_CONCURRENCY = 6;

export function FolderExportClient({
  projectId,
  canExport,
  photoCount,
}: Props) {
  const [state, setState] = useState<State>({ kind: "idle" });
  const cancelRef = useRef(false);

  const reset = useCallback(() => {
    cancelRef.current = false;
    setState({ kind: "idle" });
  }, []);

  async function start() {
    cancelRef.current = false;
    setState({ kind: "fetching-manifest" });
    try {
      const { manifest } = await api.getFolderExportManifest(projectId);
      await runDownload(manifest);
    } catch (e: unknown) {
      setState({
        kind: "error",
        message:
          e instanceof ApiError
            ? `${e.errorCode}: ${e.message}`
            : e instanceof Error
              ? e.message
              : "Manifest fetch failed",
      });
    }
  }

  async function runDownload(manifest: FolderExportManifest): Promise<void> {
    const zip = new JSZip();
    const bucketFolderByBucketId = new Map(
      manifest.buckets.map((b) => [b.id, b.folderName])
    );

    // Bucketed groupings for captions.txt sidecars.
    const photosByFolder = new Map<string, FolderExportManifestPhoto[]>();
    for (const p of manifest.photos) {
      const folder = p.bucketId
        ? bucketFolderByBucketId.get(p.bucketId) ?? manifest.unbucketedFolderName
        : manifest.unbucketedFolderName;
      if (!photosByFolder.has(folder)) photosByFolder.set(folder, []);
      photosByFolder.get(folder)!.push(p);
    }

    // Sidecar files written upfront so they appear in the ZIP even
    // if every photo's R2 fetch fails — captures the manifest as
    // human-readable text.
    for (const [folder, photos] of photosByFolder.entries()) {
      zip.file(`${folder}/captions.txt`, buildCaptionsText(manifest.projectName, photos));
    }
    if (manifest.plans.length > 0) {
      zip.file(
        "00 Floor Plans/plans.txt",
        buildPlansText(manifest.projectName, manifest.plans)
      );
    }

    // Floor plans first (small, fast).
    setState({
      kind: "downloading",
      done: 0,
      total: manifest.photos.length + manifest.plans.length,
      failed: 0,
    });

    let done = 0;
    let failed = 0;
    const tick = () => {
      done += 1;
      setState((s) =>
        s.kind === "downloading"
          ? { ...s, done, failed }
          : s
      );
    };
    const tickFailed = () => {
      failed += 1;
      done += 1;
      setState((s) =>
        s.kind === "downloading"
          ? { ...s, done, failed }
          : s
      );
    };

    for (const [idx, plan] of manifest.plans.entries()) {
      if (cancelRef.current) return;
      try {
        const blob = await fetchAsBlob(plan.presignedUrl);
        zip.file(
          `00 Floor Plans/${String(idx + 1).padStart(2, "0")} ${plan.filename}`,
          blob
        );
        tick();
      } catch {
        tickFailed();
      }
    }

    // Photos with bounded concurrency.
    const queue = manifest.photos.map((p) => ({ photo: p }));
    let nextIdx = 0;
    async function worker(): Promise<void> {
      while (true) {
        if (cancelRef.current) return;
        const i = nextIdx++;
        if (i >= queue.length) return;
        const { photo } = queue[i]!;
        const folder = photo.bucketId
          ? bucketFolderByBucketId.get(photo.bucketId) ??
            manifest.unbucketedFolderName
          : manifest.unbucketedFolderName;
        try {
          const blob = await fetchAsBlob(photo.presignedUrl);
          zip.file(`${folder}/${photo.filename}`, blob);
          tick();
        } catch {
          tickFailed();
        }
      }
    }
    const workers: Promise<void>[] = [];
    for (let i = 0; i < FETCH_CONCURRENCY; i++) workers.push(worker());
    await Promise.all(workers);

    if (cancelRef.current) return;

    // Zip + download.
    setState({ kind: "zipping", pct: 0 });
    const blob = await zip.generateAsync(
      {
        type: "blob",
        compression: "STORE", // photos don't compress; skip CPU cost
        streamFiles: true,
      },
      (metadata) => {
        setState((s) =>
          s.kind === "zipping" ? { ...s, pct: Math.round(metadata.percent) } : s
        );
      }
    );

    if (cancelRef.current) return;

    const ts = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
    const filename = `${manifest.projectName} - export ${ts}.zip`;
    triggerDownload(blob, filename);
    setState({ kind: "done", sizeMb: Math.round(blob.size / 1024 / 1024) });
  }

  // Cleanup on unmount.
  useEffect(() => {
    return () => {
      cancelRef.current = true;
    };
  }, []);

  return (
    <>
      <button
        type="button"
        onClick={start}
        disabled={
          !canExport ||
          photoCount === 0 ||
          state.kind === "fetching-manifest" ||
          state.kind === "downloading" ||
          state.kind === "zipping"
        }
        className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:opacity-50"
        title={
          !canExport
            ? "Take the edit lock to export."
            : photoCount === 0
              ? "Add photos before exporting."
              : "Download everything in your browser — no Render dyno involved."
        }
      >
        Download folder bundle…
      </button>

      {state.kind === "fetching-manifest" && (
        <div className="mt-2 text-xs text-neutral-400">
          Preparing manifest…
        </div>
      )}

      {state.kind === "downloading" && (
        <div className="mt-2 max-w-md">
          <div className="mb-0.5 flex items-center justify-between text-[11px] text-neutral-400">
            <span>
              Downloading {state.done.toLocaleString()} /{" "}
              {state.total.toLocaleString()}
              {state.failed > 0 && (
                <span className="ml-2 text-amber-400">
                  ({state.failed} failed)
                </span>
              )}
            </span>
            <span className="font-mono">
              {Math.round((state.done / Math.max(state.total, 1)) * 100)}%
            </span>
          </div>
          <div className="h-1.5 overflow-hidden rounded bg-neutral-800">
            <div
              className="h-full bg-blue-500 transition-all duration-200"
              style={{
                width: `${(state.done / Math.max(state.total, 1)) * 100}%`,
              }}
            />
          </div>
        </div>
      )}

      {state.kind === "zipping" && (
        <div className="mt-2 max-w-md">
          <div className="mb-0.5 flex items-center justify-between text-[11px] text-neutral-400">
            <span>Building ZIP…</span>
            <span className="font-mono">{state.pct}%</span>
          </div>
          <div className="h-1.5 overflow-hidden rounded bg-neutral-800">
            <div
              className="h-full bg-blue-500 transition-all duration-200"
              style={{ width: `${state.pct}%` }}
            />
          </div>
        </div>
      )}

      {state.kind === "done" && (
        <div className="mt-2 flex items-center gap-3 text-xs text-green-300">
          <span>
            Done. {state.sizeMb} MB downloaded.
          </span>
          <button
            type="button"
            onClick={reset}
            className="rounded border border-neutral-700 px-2 py-0.5 text-neutral-300 hover:bg-neutral-800"
          >
            Reset
          </button>
        </div>
      )}

      {state.kind === "error" && (
        <div className="mt-2 flex items-center gap-3 text-xs text-red-300">
          <span>{state.message}</span>
          <button
            type="button"
            onClick={reset}
            className="rounded border border-neutral-700 px-2 py-0.5 text-neutral-300 hover:bg-neutral-800"
          >
            Reset
          </button>
        </div>
      )}
    </>
  );
}

async function fetchAsBlob(url: string): Promise<Blob> {
  const resp = await fetch(url);
  if (!resp.ok) {
    throw new Error(`HTTP ${resp.status}`);
  }
  return resp.blob();
}

function triggerDownload(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.rel = "noopener noreferrer";
  document.body.appendChild(a);
  a.click();
  // Defer revocation so the browser definitely starts the download.
  setTimeout(() => {
    URL.revokeObjectURL(url);
    a.remove();
  }, 60_000);
}

function buildCaptionsText(
  projectName: string,
  photos: readonly FolderExportManifestPhoto[]
): string {
  const lines: string[] = [];
  lines.push(`# ${projectName} — captions.txt`);
  lines.push(`# Generated ${new Date().toISOString()}`);
  lines.push("");
  for (const p of photos) {
    lines.push(`## #${p.sequenceNumber} — ${p.filename}`);
    lines.push(`Captured: ${p.timestamp}`);
    if (p.userCaption) lines.push(`Caption: ${p.userCaption}`);
    if (p.userObservation) lines.push(`Observation: ${p.userObservation}`);
    if (p.aiSummary) lines.push(`AI summary: ${p.aiSummary}`);
    if (p.tags.length > 0) lines.push(`Tags: ${p.tags.join(", ")}`);
    lines.push("");
  }
  return lines.join("\n");
}

interface PlanForText {
  label: string;
  pixelsPerFoot: number;
  calibrationDistanceFeet: number;
  northDeg: number;
  distressMarkerCount: number;
}

function buildPlansText(
  projectName: string,
  plans: readonly PlanForText[]
): string {
  const lines: string[] = [];
  lines.push(`# ${projectName} — floor plans`);
  lines.push(`# Generated ${new Date().toISOString()}`);
  lines.push("");
  for (const [idx, p] of plans.entries()) {
    lines.push(`## Plan ${idx + 1} — ${p.label}`);
    lines.push(`pixelsPerFoot: ${p.pixelsPerFoot}`);
    lines.push(`calibrationDistanceFeet: ${p.calibrationDistanceFeet}`);
    lines.push(`northDeg: ${p.northDeg}`);
    lines.push(`distress markers: ${p.distressMarkerCount}`);
    lines.push("");
  }
  return lines.join("\n");
}
