import { useEffect, useState } from "react";
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
 * Thumbnail URLs are fetched in one batch (same pattern as
 * `PhotoGrid`); the URL map is then handed down to every row, so
 * we never fire N parallel GETs for a 100-photo project.
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
  onOpen: (index: number) => void;
  onOpenEditor: (photo: Photo) => void;
  onPhotoUpdated: (next: Photo) => void;
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
  onOpen,
  onOpenEditor,
  onPhotoUpdated,
}: Props) {
  const [urlsState, setUrlsState] = useState<UrlsState>({ kind: "loading" });
  const [threshold] = useTagConfidenceThreshold();

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
        const msg = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
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
    <div
      className="grid gap-2"
      style={{
        gridTemplateColumns: "repeat(auto-fill, minmax(380px, 1fr))",
      }}
    >
      {photos.map((photo, idx) => (
        <PhotoListRow
          key={photo.id}
          projectId={projectId}
          project={project}
          photo={photo}
          url={urls[photo.id] ?? null}
          batchLoading={urlsState.kind === "loading"}
          threshold={threshold}
          canEdit={canEdit}
          onOpen={() => onOpen(idx)}
          onOpenEditor={() => onOpenEditor(photo)}
          onToggleFavorite={() =>
            onPhotoUpdated({ ...photo, isFavorite: !photo.isFavorite })
          }
        />
      ))}
    </div>
  );
}
