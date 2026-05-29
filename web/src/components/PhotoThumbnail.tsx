import { useEffect, useState } from "react";
import { api, ApiError } from "../lib/api";

/**
 * Single photo thumbnail. Fetches its presigned URL on mount; renders
 * the image with native lazy-loading so the browser handles "don't
 * fetch what isn't on screen yet" automatically. Skeleton box while
 * the URL is in flight; error placeholder if the fetch fails.
 *
 * Server's thumb endpoint falls back to the full image when no
 * separate `thumb` object exists in R2 (which is the current state
 * for everything iOS has uploaded — thumb generation lands later).
 * Large originals load slowly but at least display; we trade some
 * bandwidth for a working UI.
 */
interface Props {
  projectId: string;
  photoId: string;
  alt: string;
  onClick?: () => void;
}

export function PhotoThumbnail({ projectId, photoId, alt, onClick }: Props) {
  const [url, setUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    api
      .getPhotoThumbUrl(projectId, photoId)
      .then((res) => {
        if (!cancelled) setUrl(res.url);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        if (e instanceof ApiError) setError(`${e.status} ${e.errorCode}`);
        else setError("Failed to load");
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, photoId]);

  const baseClasses =
    "aspect-square w-full overflow-hidden rounded border border-neutral-800 bg-neutral-900";

  if (error) {
    return (
      <div
        className={`${baseClasses} flex items-center justify-center text-[10px] text-red-400`}
        title={error}
      >
        {error}
      </div>
    );
  }

  if (!url) {
    return <div className={`${baseClasses} animate-pulse`} />;
  }

  return (
    <button
      type="button"
      onClick={onClick}
      className={`${baseClasses} cursor-zoom-in p-0 transition hover:border-neutral-600`}
    >
      <img
        src={url}
        alt={alt}
        loading="lazy"
        className="h-full w-full object-cover"
      />
    </button>
  );
}
