import { useMemo, useState } from "react";
import type { Photo, Project } from "@forensic/shared";

/**
 * Photo filter state + apply (Build #5.78.1 — Path P #3/8).
 *
 * Client-side filter over the already-loaded project manifest.
 * Mirrors the semantics of iOS `filteredPhotos` in
 * `ProjectDetailView.swift` field-for-field:
 *
 *   - Per-axis: tag AND / bucket OR / use OR
 *   - Cross-axis: AND (every axis must accept the photo)
 *   - Threshold-aware: a tag only counts if its confidence is
 *     at or above the user's current confidence threshold
 *   - Search: substring (case-insensitive) over the photo's seq #,
 *     user/ai caption, user observation, ai observation, location
 *     inferred (AI), and the labels of every tag (regardless of
 *     threshold — so you can search for a low-confidence tag too).
 *
 * The "no bucket" axis is modeled as a sentinel value in the
 * `bucketIds` array — `__none__`. Selecting it OR's "photos with no
 * bucket" into the bucket filter. Selecting it as the ONLY bucket
 * limits to unbucketed photos. iOS uses the same UX shape.
 */

export const UNBUCKETED = "__none__";

export interface PhotoFilterState {
  search: string;
  planFilter: "all" | "unassigned" | string; // floor-plan id when a specific plan picked
  placedFilter: "all" | "placed" | "unplaced";
  dateFilter: "all" | "today" | "7d" | "30d";
  bucketIds: string[]; // empty = no bucket filter; UNBUCKETED is a sentinel
  tagLabels: string[]; // AND
  favoritesOnly: boolean;
  needsReview: boolean;
  hasMeasurement: boolean;
  recommendedUses: string[]; // OR over `aiAnalysis.recommendedUse`
}

export const DEFAULT_FILTER_STATE: PhotoFilterState = {
  search: "",
  planFilter: "all",
  placedFilter: "all",
  dateFilter: "all",
  bucketIds: [],
  tagLabels: [],
  favoritesOnly: false,
  needsReview: false,
  hasMeasurement: false,
  recommendedUses: [],
};

export function isFilterActive(state: PhotoFilterState): boolean {
  return (
    state.search.trim().length > 0 ||
    state.planFilter !== "all" ||
    state.placedFilter !== "all" ||
    state.dateFilter !== "all" ||
    state.bucketIds.length > 0 ||
    state.tagLabels.length > 0 ||
    state.favoritesOnly ||
    state.needsReview ||
    state.hasMeasurement ||
    state.recommendedUses.length > 0
  );
}

function dateAccepted(iso: string, window: PhotoFilterState["dateFilter"]): boolean {
  if (window === "all") return true;
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return false;
  const now = Date.now();
  if (window === "today") {
    const dStart = new Date();
    dStart.setHours(0, 0, 0, 0);
    return t >= dStart.getTime();
  }
  const days = window === "7d" ? 7 : 30;
  return t >= now - days * 24 * 60 * 60 * 1000;
}

function needsReviewMatch(photo: Photo): boolean {
  const a = photo.aiAnalysis;
  if (!a) return false;
  return (
    a.parseFailed ||
    a.validationErrors.length > 0 ||
    a.reviewerFlag.trim().length > 0
  );
}

function searchMatch(photo: Photo, q: string): boolean {
  if (q.length === 0) return true;
  const needle = q.toLowerCase();
  const haystacks: string[] = [
    `#${photo.sequenceNumber}`,
    String(photo.sequenceNumber),
    photo.userCaption ?? "",
    photo.userObservation ?? "",
    photo.aiObservation ?? "",
    photo.aiDescription ?? "",
    photo.aiAnalysis?.captionDraft ?? "",
    photo.aiAnalysis?.locationInferred ?? "",
    photo.aiAnalysis?.summaryObservation ?? "",
    ...photo.tags.map((t) => t.label),
  ];
  return haystacks.some((s) => s.toLowerCase().includes(needle));
}

export function applyFilters(
  photos: readonly Photo[],
  project: Project,
  state: PhotoFilterState,
  threshold: number
): Photo[] {
  return photos.filter((photo) => {
    // Plan
    if (state.planFilter !== "all") {
      if (state.planFilter === "unassigned") {
        if (photo.floorPlanID != null) return false;
      } else if (photo.floorPlanID !== state.planFilter) {
        return false;
      }
    }
    // Placed / unplaced (does the photo have plan pixel coords?)
    if (state.placedFilter !== "all") {
      const placed =
        photo.floorPlanID != null &&
        photo.planPixelX != null &&
        photo.planPixelY != null;
      if (state.placedFilter === "placed" && !placed) return false;
      if (state.placedFilter === "unplaced" && placed) return false;
    }
    // Date
    if (!dateAccepted(photo.timestamp, state.dateFilter)) return false;
    // Bucket (OR within the axis; UNBUCKETED sentinel matches photos
    // with `bucketID == null`).
    if (state.bucketIds.length > 0) {
      const want = new Set(state.bucketIds);
      const matched = photo.bucketID
        ? want.has(photo.bucketID)
        : want.has(UNBUCKETED);
      if (!matched) return false;
    }
    // Tags (AND within the axis; threshold-aware).
    if (state.tagLabels.length > 0) {
      const present = new Set(
        photo.tags
          .filter((t) => t.confidence >= threshold)
          .map((t) => t.label.toLowerCase())
      );
      for (const label of state.tagLabels) {
        if (!present.has(label.toLowerCase())) return false;
      }
    }
    // Favorites
    if (state.favoritesOnly && !photo.isFavorite) return false;
    // Needs review
    if (state.needsReview && !needsReviewMatch(photo)) return false;
    // Has measurement
    if (
      state.hasMeasurement &&
      (!photo.aiAnalysis || photo.aiAnalysis.measurementVisible == null)
    ) {
      return false;
    }
    // Recommended use (OR within the axis)
    if (state.recommendedUses.length > 0) {
      const use = photo.aiAnalysis?.recommendedUse ?? "";
      if (!state.recommendedUses.includes(use)) return false;
    }
    // Search (last — usually the cheapest to short-circuit early
    // against, but ordering here is non-critical since every photo
    // we got this far has passed every other axis).
    if (!searchMatch(photo, state.search.trim())) return false;
    return true;
  });
  // Note: `project` is intentionally unused right now — kept in the
  // signature so future axes that need to resolve plan-id → plan
  // (e.g. "Plans I marked active") don't break callers.
  void project;
}

export interface PhotoFiltersHook {
  state: PhotoFilterState;
  setState: (next: PhotoFilterState) => void;
  patch: (partial: Partial<PhotoFilterState>) => void;
  filtered: Photo[];
  active: boolean;
}

export function usePhotoFilters(
  photos: readonly Photo[],
  project: Project,
  threshold: number
): PhotoFiltersHook {
  const [state, setState] = useState<PhotoFilterState>(DEFAULT_FILTER_STATE);
  const filtered = useMemo(
    () => applyFilters(photos, project, state, threshold),
    [photos, project, state, threshold]
  );
  function patch(partial: Partial<PhotoFilterState>) {
    setState({ ...state, ...partial });
  }
  return { state, setState, patch, filtered, active: isFilterActive(state) };
}
