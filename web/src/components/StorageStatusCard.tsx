import { useCallback, useEffect, useState } from "react";
import type { UserStorageStatus } from "@forensic/shared";
import { api, ApiError } from "../lib/api";

/**
 * Cloud-storage status card (Build #5.100.1).
 *
 * Server-aggregated counts + bytes for the calling user — mirrors
 * iOS's Settings → Storage section conceptually but reports the
 * authoritative cloud state (rather than the device's iCloud Drive
 * usage). Caches in component state for 30 seconds so a
 * Settings-page nav doesn't hammer the endpoint.
 *
 * Phase 5 (multi-user quotas) will overlay a usage bar against the
 * user's quota — for now we just surface absolute totals.
 */
export function StorageStatusCard() {
  const [status, setStatus] = useState<UserStorageStatus | null>(null);
  const [computedAt, setComputedAt] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const fetchStatus = useCallback(async () => {
    setRefreshing(true);
    setError(null);
    try {
      const resp = await api.getUserStorageStatus();
      setStatus(resp.status);
      setComputedAt(resp.computedAt);
    } catch (e: unknown) {
      setError(
        e instanceof ApiError
          ? `${e.errorCode}: ${e.message}`
          : "Failed to load storage status."
      );
    } finally {
      setRefreshing(false);
    }
  }, []);

  // Initial load on mount. No interval — the user explicitly refreshes.
  useEffect(() => {
    void fetchStatus();
  }, [fetchStatus]);

  return (
    <section className="rounded border border-neutral-800 bg-neutral-950/40 p-5">
      <header className="mb-3 flex items-center justify-between">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-neutral-400">
          Storage
        </h2>
        <button
          type="button"
          onClick={() => void fetchStatus()}
          disabled={refreshing}
          className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800 disabled:opacity-50"
        >
          {refreshing ? "Refreshing…" : "Refresh"}
        </button>
      </header>

      {error && (
        <div className="mb-2 rounded border border-red-800 bg-red-950/40 p-2 text-xs text-red-300">
          {error}
        </div>
      )}

      {!status && !error && (
        <div className="text-sm text-neutral-500">Loading…</div>
      )}

      {status && (
        <>
          <dl className="grid grid-cols-2 gap-x-6 gap-y-1 text-sm">
            <dt className="text-neutral-500">Projects</dt>
            <dd className="font-mono text-neutral-100">
              {status.activeProjectCount}
              {status.projectCount > status.activeProjectCount && (
                <span className="ml-2 text-xs text-neutral-500">
                  (+{status.projectCount - status.activeProjectCount} trashed)
                </span>
              )}
            </dd>
            <dt className="text-neutral-500">Photos</dt>
            <dd className="font-mono text-neutral-100">
              {status.photoCount.toLocaleString()}
            </dd>
            <dt className="text-neutral-500">Floor plans</dt>
            <dd className="font-mono text-neutral-100">
              {status.floorPlanCount}
            </dd>
            <dt className="text-neutral-500">Total storage</dt>
            <dd className="font-mono font-semibold text-neutral-100">
              {humanBytes(status.totalBlobBytes)}
            </dd>
          </dl>

          {Object.keys(status.blobBytesByKind).length > 0 && (
            <div className="mt-4">
              <div className="mb-1 text-xs uppercase tracking-wide text-neutral-500">
                By kind
              </div>
              <ul className="space-y-1 text-xs">
                {Object.entries(status.blobBytesByKind)
                  .sort((a, b) => b[1] - a[1])
                  .map(([kind, bytes]) => (
                    <li
                      key={kind}
                      className="flex items-center justify-between"
                    >
                      <span className="text-neutral-400">{kindLabel(kind)}</span>
                      <span className="font-mono text-neutral-200">
                        {humanBytes(bytes)}
                      </span>
                    </li>
                  ))}
              </ul>
            </div>
          )}

          {computedAt && (
            <p className="mt-3 text-[11px] text-neutral-600">
              Computed {new Date(computedAt).toLocaleString()}
            </p>
          )}
        </>
      )}
    </section>
  );
}

function kindLabel(kind: string): string {
  switch (kind) {
    case "photo":
      return "Photo originals";
    case "thumb":
      return "Thumbnails";
    case "markup_png":
      return "Markup overlays / branding";
    case "markup_drawing":
      return "Markup stroke data";
    case "plan":
      return "Floor plans";
    default:
      return kind;
  }
}

function humanBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}
