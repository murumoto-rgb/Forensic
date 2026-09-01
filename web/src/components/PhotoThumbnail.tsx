import { useEffect, useState } from "react";
import { api, ApiError } from "../lib/api";

/**
 * Single photo thumbnail. Two modes of operation:
 *
 *  1. **Batch mode (preferred, from PhotoGrid).** Parent does ONE
 *     `getPhotoUrlsBatch` call and passes the resolved URL in via
 *     the `url` prop. While the batch is in flight `batchLoading`
 *     is true and we render a skeleton; when it resolves, `url`
 *     is either a string (render the `<img>`) or `null` (no file
 *     in storage — render the "pending upload" placeholder).
 *
 *  2. **Standalone mode (legacy fallback).** If the parent doesn't
 *     pass `url` or `batchLoading`, we fetch our own URL via the
 *     per-photo endpoint. This keeps any future single-thumbnail
 *     usage working without refactoring; the photo grid does NOT
 *     use this path anymore (would re-introduce the N+1 storm).
 *
 * Server's thumb endpoint falls back to the full image when no
 * separate `thumb` object exists in R2; this component is agnostic
 * to which kind of object the URL points at.
 */
interface Props {
  projectId: string;
  photoId: string;
  /** Pre-fetched presigned URL from a batch call. `null` = batch
   *  finished and this photo has no file (treat as "pending upload").
   *  `undefined` = no batch happening; component fetches on its own. */
  url?: string | null;
  /** True while the parent's batch is in flight. */
  batchLoading?: boolean;
  alt: string;
  onClick?: () => void;
  onError?: () => void;
}

type LoadState = "loading" | "ready" | "pending" | "error";

export function PhotoThumbnail({
  projectId,
  photoId,
  url: urlProp,
  batchLoading,
  alt,
  onClick,
  onError,
}: Props) {
  // Internal state for standalone-mode fetch. Unused when the
  // parent passes `url` / `batchLoading`.
  const [internalUrl, setInternalUrl] = useState<string | null>(null);
  const [internalState, setInternalState] = useState<LoadState>("loading");

  // Standalone mode only: fire a per-photo fetch if the parent
  // didn't pre-fetch for us.
  const parentManagedUrl =
    urlProp !== undefined || batchLoading !== undefined;

  useEffect(() => {
    if (parentManagedUrl) return; // skip — parent will tell us what URL to use
    let cancelled = false;
    setInternalState("loading");
    setInternalUrl(null);
    api
      .getPhotoThumbUrl(projectId, photoId)
      .then((res) => {
        if (cancelled) return;
        setInternalUrl(res.url);
        setInternalState("ready");
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        if (e instanceof ApiError && e.status === 404) {
          setInternalState("pending");
        } else {
          setInternalState("error");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [projectId, photoId, parentManagedUrl]);

  // Resolve effective state + URL from whichever mode is active.
  let state: LoadState;
  let url: string | null;
  if (parentManagedUrl) {
    if (batchLoading) {
      state = "loading";
      url = null;
    } else if (urlProp == null) {
      // Batch done; this photo had no file → pending upload.
      state = "pending";
      url = null;
    } else {
      state = "ready";
      url = urlProp;
    }
  } else {
    state = internalState;
    url = internalUrl;
  }

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
    <div
      role={onClick ? "button" : undefined}
      tabIndex={onClick ? 0 : undefined}
      onClick={onClick}
      onKeyDown={(e) => {
        if (onClick && (e.key === "Enter" || e.key === " ")) {
          e.preventDefault();
          onClick();
        }
      }}
      className={`${baseClasses} ${onClick ? "cursor-zoom-in" : ""} p-0 transition hover:border-neutral-600`}
    >
      <img
        src={url}
        alt={alt}
        loading="lazy"
        className="h-full w-full object-cover"
        onError={onError}
      />
    </div>
  );
}
