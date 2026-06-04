import { useEffect, useState } from "react";

/**
 * App-wide confidence threshold for AI-suggested tags. Persists in
 * localStorage so a tweak survives a refresh. Default 0.5 — same
 * default iOS ships under `sitephoto.tagConfidenceThreshold`.
 *
 * Mirrors the iOS `@AppStorage("sitephoto.tagConfidenceThreshold")`
 * semantics. iOS hides tags below the threshold from photo rows,
 * filter chips, the tag-filter screen, and the PDF export. Web
 * currently only shows AI-tag chips inside the floor-plan preview
 * panel's `AITagTree`, so for now this hook drives that one
 * affordance. As web adds new tag surfaces, they should all read
 * this same hook so the filter stays consistent everywhere.
 *
 * Storage key is `sitephoto.tagConfidenceThreshold` — same string
 * iOS uses, even though the two stores don't share state. Keeps the
 * "what does this UserDefault mean?" lookup portable across the
 * codebases.
 */

const STORAGE_KEY = "sitephoto.tagConfidenceThreshold";
const DEFAULT_THRESHOLD = 0.5;

function readStored(): number {
  if (typeof window === "undefined") return DEFAULT_THRESHOLD;
  const raw = window.localStorage.getItem(STORAGE_KEY);
  if (raw == null) return DEFAULT_THRESHOLD;
  const parsed = Number.parseFloat(raw);
  if (!Number.isFinite(parsed)) return DEFAULT_THRESHOLD;
  return Math.max(0, Math.min(1, parsed));
}

export function useTagConfidenceThreshold(): [
  number,
  (next: number) => void
] {
  const [value, setValue] = useState<number>(() => readStored());

  // Keep multiple instances of the hook in the same window in sync —
  // when one slider moves, every other `AITagTree` re-renders with
  // the new threshold without remounting.
  useEffect(() => {
    function onStorage(e: StorageEvent) {
      if (e.key !== STORAGE_KEY) return;
      setValue(readStored());
    }
    function onCustom() {
      setValue(readStored());
    }
    window.addEventListener("storage", onStorage);
    window.addEventListener("sitephoto:thresholdChanged", onCustom);
    return () => {
      window.removeEventListener("storage", onStorage);
      window.removeEventListener("sitephoto:thresholdChanged", onCustom);
    };
  }, []);

  function update(next: number) {
    const clamped = Math.max(0, Math.min(1, next));
    setValue(clamped);
    if (typeof window !== "undefined") {
      window.localStorage.setItem(STORAGE_KEY, String(clamped));
      // Notify other hook instances in the same tab. `storage` event
      // only fires cross-tab, so we hand-roll an in-tab signal.
      window.dispatchEvent(new Event("sitephoto:thresholdChanged"));
    }
  }

  return [value, update];
}
