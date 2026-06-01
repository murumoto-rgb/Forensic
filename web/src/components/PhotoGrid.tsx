import { useEffect, useState } from "react";
import type { Photo } from "@forensic/shared";
import { api } from "../lib/api";
import { PhotoThumbnail } from "./PhotoThumbnail";

/**
 * Responsive grid of photo thumbnails. Two columns on phone, more
 * as the viewport widens. Each cell is square (object-cover crops
 * to fit). Clicking a thumbnail invokes `onSelect(index)` so the
 * parent can open the lightbox at that position.
 *
 * URL fetching is batched: the grid does ONE `POST /photo-urls`
 * call up front and feeds the resulting `photoId → url` map down
 * to each child. Replaces the previous N-parallel-GETs pattern
 * that 502'd Render's free tier on projects with 100s of photos
 * (Build #5.19.1).
 */
interface Props {
  projectId: string;
  photos: Photo[];
  onSelect: (index: number) => void;
}

type UrlsState =
  | { kind: "loading" }
  | { kind: "ready"; urls: Record<string, string> }
  | { kind: "error"; message: string };

export function PhotoGrid({ projectId, photos, onSelect }: Props) {
  const [urlsState, setUrlsState] = useState<UrlsState>({ kind: "loading" });

  // Re-fetch the URL map whenever the project changes or the set of
  // visible photos changes (e.g. trashed-toggle, search filter).
  // We key on a stable concatenation of IDs so reordering alone
  // doesn't trigger a refetch.
  const idsKey = photos.map((p) => p.id).join(",");

  useEffect(() => {
    if (photos.length === 0) {
      setUrlsState({ kind: "ready", urls: {} });
      return;
    }
    let cancelled = false;
    setUrlsState({ kind: "loading" });
    api
      .getPhotoUrlsBatch(
        projectId,
        photos.map((p) => p.id),
        "thumb"
      )
      .then((res) => {
        if (cancelled) return;
        setUrlsState({ kind: "ready", urls: res.urls });
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        const msg =
          e instanceof Error ? `${e.name}: ${e.message}` : String(e);
        setUrlsState({ kind: "error", message: msg });
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId, idsKey]);

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
      <div className="rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
        Couldn't load thumbnails — {urlsState.message}
      </div>
    );
  }

  const urls = urlsState.kind === "ready" ? urlsState.urls : {};

  return (
    <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
      {photos.map((photo, idx) => (
        <PhotoThumbnail
          key={photo.id}
          projectId={projectId}
          photoId={photo.id}
          url={urls[photo.id] ?? null}
          batchLoading={urlsState.kind === "loading"}
          alt={photo.userCaption ?? `Photo ${photo.sequenceNumber}`}
          onClick={() => onSelect(idx)}
        />
      ))}
    </div>
  );
}
