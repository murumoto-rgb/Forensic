import { useEffect, useRef, useState } from "react";
import type { Photo, Project } from "@forensic/shared";
import { api } from "../lib/api";
import { useTagConfidenceThreshold } from "../lib/useTagConfidenceThreshold";
import { PhotoListRow } from "./PhotoListRow";

/**
 * Rich photo list — replaces `PhotoGrid` for the Photos tab as of
 * Build #5.77.1 (Path P #2/8). Renders a responsive grid of
 * `PhotoListRow` cards that auto-fills as many columns as the
 * viewport allows (`minmax(380px, 1fr)`): 1 col on phones,
 * 2 on tablets, 3 on laptops, 4+ on wide monitors.
 *
 * Thumbnail URLs are cached **per-photo-id across renders**
 * (Build #5.113.1). When the user toggles filters, the visible
 * `photos` array changes, but the URL map is keyed by photo ID
 * and we only fetch IDs that don't already have a URL. Toggling
 * filters no longer re-fetches and re-mounts the entire grid.
 *
 * Cache scope: per `PhotoList` mount. Project switches discard
 * the cache via the `projectId` reset effect.
 *
 * Edits flow through the parent — `onPhotoUpdated(updated)` is
 * called with the new photo struct and the parent merges it into
 * the project's `photos` array. The list itself is pure render.
 */
interface Props {
  projectId: string;
  project: Project;
  photos: Photo[];
  canEdit: boolean;
  /** Select-mode controls — passed straight to each row. The list
   *  doesn't own the selection state (it lives one level up in the
   *  Photos tab so the action bar can read it). */
  selectMode: boolean;
  selectedIds: Set<string>;
  onOpen: (index: number) => void;
  onOpenEditor: (photo: Photo) => void;
  onPhotoUpdated: (next: Photo) => void;
  onToggleSelected: (photoId: string) => void;
}

type UrlsState =
  | { kind: "loading" }
  | { kind: "ready"; urls: Record<string, string> }
  | { kind: "error"; message: string };

export function PhotoList({
  projectId,
  project,
  photos,
  canEdit,
  selectMode,
  selectedIds,
  onOpen,
  onOpenEditor,
  onPhotoUpdated,
  onToggleSelected,
}: Props) {
  const [urlsState, setUrlsState] = useState<UrlsState>({ kind: "loading" });
  const [threshold] = useTagConfidenceThreshold();

  // Cumulative URL cache across renders. `urls` is the live map
  // we hand down to rows; `attempted` records IDs we've already
  // requested (succeeded or not) so a 404'd photo doesn't keep
  // triggering re-fetches every filter toggle.
  const cacheRef = useRef<{ urls: Map<string, string>; attempted: Set<string> }>({
    urls: new Map(),
    attempted: new Set(),
  });

  // Reset the cache when the project changes — different presigned
  // URLs live under different project IDs, and there's no point
  // hanging on to URLs for a project the user has left.
  const lastProjectIdRef = useRef<string>(projectId);
  if (lastProjectIdRef.current !== projectId) {
    cacheRef.current = { urls: new Map(), attempted: new Set() };
    lastProjectIdRef.current = projectId;
  }
  // Build #6.17.1: bump to retry the URL fetch from the error UI
  // without dropping the rest of the component's state.
  const [retryNonce, setRetryNonce] = useState(0);

  useEffect(() => {
    if (photos.length === 0) {
      setUrlsState({ kind: "ready", urls: snapshotUrls(cacheRef.current.urls) });
      return;
    }
    // Anything we haven't seen before? Only fetch those.
    const missing = photos.filter(
      (p) => !cacheRef.current.attempted.has(p.id)
    );
    if (missing.length === 0) {
      // Pure filter change — every visible photo's URL is already
      // cached. Render synchronously with what we have; never blank
      // the grid.
      setUrlsState({ kind: "ready", urls: snapshotUrls(cacheRef.current.urls) });
      return;
    }
    // First load OR new photos appeared (e.g. user uploaded some).
    // Surface "loading" only on the FIRST batch where we have nothing
    // at all — otherwise leave the existing thumbnails up while the
    // new IDs resolve in the background.
    if (cacheRef.current.urls.size === 0) {
      setUrlsState({ kind: "loading" });
    }
    let cancelled = false;
    const requestedIds = missing.map((p) => p.id);
    // Mark as attempted immediately so a re-render mid-flight doesn't
    // re-request the same IDs.
    for (const id of requestedIds) cacheRef.current.attempted.add(id);
    api
      .getPhotoUrlsBatch(projectId, requestedIds, "thumb")
      .then((res) => {
        if (cancelled) return;
        for (const [id, url] of Object.entries(res.urls)) {
          cacheRef.current.urls.set(id, url);
        }
        setUrlsState({ kind: "ready", urls: snapshotUrls(cacheRef.current.urls) });
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        // Roll back the attempted flag on these IDs so a retry is
        // possible (e.g. transient network error).
        for (const id of requestedIds) cacheRef.current.attempted.delete(id);
        if (cacheRef.current.urls.size === 0) {
          const msg = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
          setUrlsState({ kind: "error", message: msg });
        }
        // If we already had some URLs cached, swallow the error —
        // the user keeps seeing what they have. A second filter
        // toggle will try again for the missing IDs.
      });
    return () => {
      cancelled = true;
      for (const id of requestedIds) cacheRef.current.attempted.delete(id);
    };
    // The effect re-fires when the visible photo set changes; the
    // cache check short-circuits when there's nothing new.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId, photos.map((p) => p.id).join(","), retryNonce]);

  if (photos.length === 0) {
    return (
      <div className="rounded border border-dashed border-neutral-800 p-10 text-center text-sm text-neutral-500">
        No photos in this project yet. Capture some on iOS and they will
        appear here within a few seconds.
      </div>
    );
  }

  if (urlsState.kind === "error") {
    return (
      <div className="flex flex-col gap-2 rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
        <div>Couldn't load thumbnails — {urlsState.message}</div>
        <button
          type="button"
          onClick={() => {
            // Build #6.17.1: re-trigger the fetch effect with the
            // same project + photo set.
            cacheRef.current.attempted.clear();
            setRetryNonce((n) => n + 1);
          }}
          className="self-start rounded border border-red-700 bg-red-900/40 px-3 py-1 text-xs text-red-100 hover:bg-red-900/70"
        >
          Retry
        </button>
      </div>
    );
  }

  const urls = urlsState.kind === "ready" ? urlsState.urls : {};

  return (
    <div
      className="grid gap-2"
      style={{
        gridTemplateColumns: "repeat(auto-fill, minmax(min(100%, 380px), 1fr))",
      }}
    >
      {photos.map((photo, idx) => (
        // Build #6.31.1: native lazy rendering. `content-visibility:
        // auto` lets the browser skip layout + paint for off-screen
        // cards entirely — on a 300-photo project that's ~95% of the
        // grid at any scroll position. The intrinsic-size hint keeps
        // the scrollbar stable before first render ("auto" makes the
        // browser remember the real size afterwards). Chosen over
        // react-window-style virtualization deliberately: same
        // render-cost win, zero scroll-container rework, and it
        // degrades to today's behavior where unsupported.
        <div
          key={photo.id}
          style={{
            contentVisibility: "auto",
            containIntrinsicSize: "auto 360px",
          }}
        >
        <PhotoListRow
          projectId={projectId}
          project={project}
          photo={photo}
          url={urls[photo.id] ?? null}
          batchLoading={urlsState.kind === "loading"}
          threshold={threshold}
          canEdit={canEdit}
          selectMode={selectMode}
          selected={selectedIds.has(photo.id)}
          onOpen={() => onOpen(idx)}
          onOpenEditor={() => onOpenEditor(photo)}
          onToggleFavorite={() =>
            onPhotoUpdated({ ...photo, isFavorite: !photo.isFavorite })
          }
          onToggleSelected={() => onToggleSelected(photo.id)}
          onThumbnailError={() => {
            cacheRef.current.urls.delete(photo.id);
            cacheRef.current.attempted.delete(photo.id);
            setRetryNonce((n) => n + 1);
          }}
        />
        </div>
      ))}
    </div>
  );
}

/** Snapshot the live URL Map into a plain object for the
 *  PhotoListRow consumers, which take a `Record<string, string>`.
 *  Cheap — the map size is bounded by project.photos.length. */
function snapshotUrls(m: Map<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [id, url] of m) out[id] = url;
  return out;
}
