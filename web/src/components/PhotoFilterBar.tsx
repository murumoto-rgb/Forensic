import { useMemo } from "react";
import type { Project } from "@forensic/shared";
import {
  DEFAULT_FILTER_STATE,
  UNBUCKETED,
  type PhotoFiltersHook,
  type PhotoFilterState,
} from "../lib/usePhotoFilters";

/**
 * Photo filter chip bar (Build #5.78.1 — Path P #3/8).
 *
 * One control surface for every per-photo filter axis: plan,
 * placed, date, bucket, tag, favorites, needs-review, has-
 * measurement, recommended-use, plus a search box and a Clear All
 * chip. Mirrors iOS `tagFilterBar` shape — chips with quick toggles
 * and dropdowns for multi-select axes.
 *
 * The bar is presentational; all state lives in `usePhotoFilters`
 * and is passed in via `filters`. The bar dispatches via
 * `filters.setState` / `filters.patch`.
 */
interface Props {
  filters: PhotoFiltersHook;
  project: Project;
  /** Total / shown counts surfaced inline so the header reads
   *  "Photos · N · M shown" like iOS. */
  total: number;
}

export function PhotoFilterBar({ filters, project, total }: Props) {
  const { state, patch, setState, filtered, active } = filters;

  // Distinct tag labels (above threshold) across all photos. Used
  // as the menu of available chips for the Tag-AND axis.
  const tagOptions = useMemo(() => {
    const m = new Set<string>();
    for (const photo of project.photos) {
      for (const tag of photo.tags) m.add(tag.label);
    }
    return Array.from(m).sort();
  }, [project.photos]);

  // Distinct recommended-uses across all photos.
  const useOptions = useMemo(() => {
    const m = new Set<string>();
    for (const photo of project.photos) {
      const u = photo.aiAnalysis?.recommendedUse;
      if (u && u.length > 0) m.add(u);
    }
    return Array.from(m).sort();
  }, [project.photos]);

  function toggleArrayMember<T extends string>(
    key: "bucketIds" | "tagLabels" | "recommendedUses",
    value: T
  ) {
    const arr = state[key];
    const next = arr.includes(value)
      ? arr.filter((v) => v !== value)
      : [...arr, value];
    patch({ [key]: next } as Partial<PhotoFilterState>);
  }

  return (
    <div className="mb-3 flex flex-col gap-2">
      {/* Top row: header + search + clear */}
      <div className="flex flex-wrap items-center gap-2">
        <div className="text-sm text-neutral-300">
          Photos · {total}
          {active && (
            <span className="ml-2 text-neutral-400">· {filtered.length} shown</span>
          )}
        </div>
        <input
          type="search"
          value={state.search}
          onChange={(e) => patch({ search: e.target.value })}
          placeholder="Search caption, tag, or #"
          className="ml-auto w-60 rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-xs text-neutral-100 placeholder:text-neutral-500"
        />
        {active && (
          <button
            type="button"
            onClick={() => setState(DEFAULT_FILTER_STATE)}
            className="rounded border border-neutral-700 px-2 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
          >
            Clear all
          </button>
        )}
      </div>

      {/* Chip row */}
      <div className="flex flex-wrap items-center gap-2">
        <SelectChip
          label="Plan"
          value={state.planFilter}
          onChange={(v) => patch({ planFilter: v })}
          options={[
            { value: "all", label: "All plans" },
            { value: "unassigned", label: "No plan" },
            ...project.floorPlans.map((p) => ({ value: p.id, label: p.label })),
          ]}
        />
        <SelectChip
          label="Placed"
          value={state.placedFilter}
          onChange={(v) =>
            patch({ placedFilter: v as PhotoFilterState["placedFilter"] })
          }
          options={[
            { value: "all", label: "All" },
            { value: "placed", label: "Placed" },
            { value: "unplaced", label: "Not placed" },
          ]}
        />
        <SelectChip
          label="Date"
          value={state.dateFilter}
          onChange={(v) =>
            patch({ dateFilter: v as PhotoFilterState["dateFilter"] })
          }
          options={[
            { value: "all", label: "Any time" },
            { value: "today", label: "Today" },
            { value: "7d", label: "Last 7 days" },
            { value: "30d", label: "Last 30 days" },
          ]}
        />
        <ToggleChip
          label="★ Favorites"
          on={state.favoritesOnly}
          onToggle={() => patch({ favoritesOnly: !state.favoritesOnly })}
        />
        <ToggleChip
          label="⚠ Needs review"
          on={state.needsReview}
          onToggle={() => patch({ needsReview: !state.needsReview })}
        />
        <ToggleChip
          label="📏 Measurement"
          on={state.hasMeasurement}
          onToggle={() => patch({ hasMeasurement: !state.hasMeasurement })}
        />
      </div>

      {/* Bucket multi-select (OR) */}
      {(project.buckets.length > 0 || true) && (
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-[10px] uppercase tracking-wide text-neutral-500">
            Bucket (OR):
          </span>
          <MultiChip
            label="No bucket"
            on={state.bucketIds.includes(UNBUCKETED)}
            onToggle={() => toggleArrayMember("bucketIds", UNBUCKETED)}
          />
          {project.buckets.map((b) => (
            <MultiChip
              key={b.id}
              label={b.name}
              colorHex={b.colorHex}
              on={state.bucketIds.includes(b.id)}
              onToggle={() => toggleArrayMember("bucketIds", b.id)}
            />
          ))}
        </div>
      )}

      {/* Tag multi-select (AND) — only show when there are tags
          to pick from to avoid an empty row of nothing. */}
      {tagOptions.length > 0 && (
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-[10px] uppercase tracking-wide text-neutral-500">
            Tag (AND):
          </span>
          {tagOptions.map((label) => (
            <MultiChip
              key={label}
              label={label}
              on={state.tagLabels.includes(label)}
              onToggle={() => toggleArrayMember("tagLabels", label)}
            />
          ))}
        </div>
      )}

      {/* Recommended-use multi-select (OR) — only when data has any */}
      {useOptions.length > 0 && (
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-[10px] uppercase tracking-wide text-neutral-500">
            Use (OR):
          </span>
          {useOptions.map((u) => (
            <MultiChip
              key={u}
              label={u}
              on={state.recommendedUses.includes(u)}
              onToggle={() => toggleArrayMember("recommendedUses", u)}
            />
          ))}
        </div>
      )}
    </div>
  );
}

interface SelectChipProps {
  label: string;
  value: string;
  onChange: (next: string) => void;
  options: Array<{ value: string; label: string }>;
}
function SelectChip({ label, value, onChange, options }: SelectChipProps) {
  return (
    <label className="flex items-center gap-1 rounded border border-neutral-700 bg-neutral-900/40 px-2 py-1 text-xs text-neutral-300">
      <span className="text-neutral-500">{label}:</span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="bg-transparent text-neutral-100 outline-none"
      >
        {options.map((o) => (
          <option key={o.value} value={o.value} className="bg-neutral-950">
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );
}

interface ToggleChipProps {
  label: string;
  on: boolean;
  onToggle: () => void;
}
function ToggleChip({ label, on, onToggle }: ToggleChipProps) {
  return (
    <button
      type="button"
      onClick={onToggle}
      className={
        on
          ? "rounded border border-blue-500 bg-blue-950/40 px-2 py-1 text-xs text-blue-200"
          : "rounded border border-neutral-700 px-2 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
      }
    >
      {label}
    </button>
  );
}

interface MultiChipProps {
  label: string;
  on: boolean;
  onToggle: () => void;
  colorHex?: string;
}
function MultiChip({ label, on, onToggle, colorHex }: MultiChipProps) {
  return (
    <button
      type="button"
      onClick={onToggle}
      className={
        on
          ? "flex items-center gap-1 rounded border border-blue-500 bg-blue-950/40 px-2 py-1 text-xs text-blue-200"
          : "flex items-center gap-1 rounded border border-neutral-700 px-2 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
      }
    >
      {colorHex && (
        <span
          className="inline-block h-2.5 w-2.5 rounded-full"
          style={{ background: colorHex }}
        />
      )}
      {label}
    </button>
  );
}
