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

type LoadState = "loading" | "ready" | "pending" | "error";

export function PhotoThumbnail({ projectId, photoId, alt, onClick }: Props) {
  const [url, setUrl] = useState<string | null>(null);
  const [state, setState] = useState<LoadState>("loading");

  useEffect(() => {
    let cancelled = false;
    setState("loading");
    setUrl(null);
    api
      .getPhotoThumbUrl(projectId, photoId)
      .then((res) => {
        if (cancelled) return;
        setUrl(res.url);
        setState("ready");
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        // A 404 means the photo's binary hasn't been uploaded to R2
        // yet — the iPhone has the manifest synced but the file is
        // still pending (often because it lives in iCloud and hasn't
        // been pulled to the device + uploaded). This is a normal,
        // transient state, not an error: show a friendly "pending"
        // placeholder. Everything else is a real error.
        if (e instanceof ApiError && e.status === 404) {
          setState("pending");
        } else {
          setState("error");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, photoId]);

  const baseClasses =
    "aspect-square w-full overflow-hidden rounded border border-neutral-800 bg-neutral-900";

  if (state === "pending") {
    return (
      <div
        className={`${baseClasses} flex flex-col items-center justify-center gap-1 text-center text-[10px] text-neutral-500`}
        title="This photo hasn't finished uploading from the iPhone yet."
      >
        <span className="text-base">⏳</span>
        <span>Uploading…</span>
      </div>
    );
  }

  if (state === "error") {
    return (
      <div
        className={`${baseClasses} flex items-center justify-center text-[10px] text-red-400`}
      >
        Failed to load
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
