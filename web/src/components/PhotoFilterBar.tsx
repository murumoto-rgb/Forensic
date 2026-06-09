import { useEffect, useMemo, useRef, useState } from "react";
import type { Project } from "@forensic/shared";
import {
  DEFAULT_FILTER_STATE,
  UNBUCKETED,
  type PhotoFiltersHook,
  type PhotoFilterState,
} from "../lib/usePhotoFilters";

/**
 * Photo filter chip bar (Build #5.78.1 — Path P #3/8;
 * consolidated #5.112.1).
 *
 * One control surface for every per-photo filter axis. Layout
 * after #5.112.1:
 *
 *   row 1: header + search + clear
 *   row 2: single-select dropdowns (plan / placed / date) +
 *          toggle chips (favorites / needs-review / validation /
 *          measurement) + multi-select popovers (bucket / tag /
 *          use) — each popover trigger shows a count badge and
 *          opens a search-+-checkboxes overlay.
 *
 * The popovers eliminate the previous wall-of-chips behaviour for
 * projects with many distinct tags. Selected items show as small
 * removable pills next to each popover trigger so the active
 * state stays visible without expanding the panel.
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

  // Tag labels across all photos, grouped by their primary
  // (`parentTag === null`). Secondaries hang off the primary they
  // were tagged under. A label that's tagged primary anywhere wins
  // the primary role; orphan secondaries (parent never tagged) get
  // their own group keyed on the parent label so the user still
  // sees the hierarchy.
  const tagGroups = useMemo(() => buildTagGroups(project.photos), [project.photos]);
  const tagOptionsCount = useMemo(
    () => tagGroups.reduce((n, g) => n + 1 + g.secondaries.length, 0),
    [tagGroups]
  );

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

  // Bucket options include the UNBUCKETED sentinel + each project
  // bucket. Render with the bucket's colour swatch when present.
  const bucketPopoverOptions = useMemo(() => {
    const out: Array<{ value: string; label: string; colorHex?: string }> = [];
    out.push({ value: UNBUCKETED, label: "No bucket" });
    for (const b of project.buckets) {
      out.push({ value: b.id, label: b.name, colorHex: b.colorHex });
    }
    return out;
  }, [project.buckets]);

  function bucketLabelFromValue(value: string): string {
    if (value === UNBUCKETED) return "No bucket";
    return project.buckets.find((b) => b.id === value)?.name ?? value;
  }
  function bucketColor(value: string): string | undefined {
    if (value === UNBUCKETED) return undefined;
    return project.buckets.find((b) => b.id === value)?.colorHex;
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

      {/* Single chip row — all dropdowns, toggles, and popovers
          collapse into one wrapping line. */}
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
          label="✗ Validation issues"
          on={state.validationIssuesOnly}
          onToggle={() =>
            patch({ validationIssuesOnly: !state.validationIssuesOnly })
          }
          title="Photos where the AI's output failed to parse or violated the vocabulary — stricter than Needs review."
        />
        <ToggleChip
          label="📏 Measurement"
          on={state.hasMeasurement}
          onToggle={() => patch({ hasMeasurement: !state.hasMeasurement })}
        />

        {/* Bucket multi-select (OR). Inline popover trigger + active
            pills shown as removable chips. */}
        <MultiSelectChip
          label="Bucket"
          modeLabel="OR"
          options={bucketPopoverOptions}
          selected={state.bucketIds}
          onToggle={(v) => toggleArrayMember("bucketIds", v)}
          onClear={() => patch({ bucketIds: [] })}
        />
        {state.bucketIds.map((v) => (
          <RemovablePill
            key={v}
            label={bucketLabelFromValue(v)}
            colorHex={bucketColor(v)}
            onRemove={() => toggleArrayMember("bucketIds", v)}
          />
        ))}

        {/* Tag multi-select (AND). Grouped by primary so a project
            with many distinct secondaries doesn't render a wall of
            flat checkboxes. */}
        {tagOptionsCount > 0 && (
          <MultiSelectChipGrouped
            label="Tag"
            modeLabel="AND"
            groups={tagGroups}
            selected={state.tagLabels}
            onToggle={(v) => toggleArrayMember("tagLabels", v)}
            onClear={() => patch({ tagLabels: [] })}
          />
        )}
        {state.tagLabels.map((v) => (
          <RemovablePill
            key={v}
            label={v}
            onRemove={() => toggleArrayMember("tagLabels", v)}
          />
        ))}

        {/* Recommended-use multi-select (OR). */}
        {useOptions.length > 0 && (
          <MultiSelectChip
            label="Use"
            modeLabel="OR"
            options={useOptions.map((u) => ({ value: u, label: u }))}
            selected={state.recommendedUses}
            onToggle={(v) => toggleArrayMember("recommendedUses", v)}
            onClear={() => patch({ recommendedUses: [] })}
          />
        )}
        {state.recommendedUses.map((v) => (
          <RemovablePill
            key={v}
            label={v}
            onRemove={() => toggleArrayMember("recommendedUses", v)}
          />
        ))}
      </div>
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
  title?: string;
}
function ToggleChip({ label, on, onToggle, title }: ToggleChipProps) {
  return (
    <button
      type="button"
      onClick={onToggle}
      title={title}
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

interface MultiSelectChipProps {
  label: string;
  /** Tiny suffix shown after the label, e.g. "AND" / "OR". */
  modeLabel: string;
  options: Array<{ value: string; label: string; colorHex?: string }>;
  selected: string[];
  onToggle: (value: string) => void;
  onClear: () => void;
}

/**
 * Multi-select popover trigger. Renders as a single chip-sized
 * button; clicking opens an absolute-positioned panel with a
 * search box and checkbox list. Click-outside closes.
 */
function MultiSelectChip({
  label,
  modeLabel,
  options,
  selected,
  onToggle,
  onClear,
}: MultiSelectChipProps) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const wrapperRef = useRef<HTMLDivElement | null>(null);

  // Click outside to close.
  useEffect(() => {
    if (!open) return;
    function onClick(e: MouseEvent) {
      const w = wrapperRef.current;
      if (w && !w.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    window.addEventListener("mousedown", onClick);
    return () => window.removeEventListener("mousedown", onClick);
  }, [open]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (q.length === 0) return options;
    return options.filter((o) => o.label.toLowerCase().includes(q));
  }, [options, query]);

  const hasSelection = selected.length > 0;

  return (
    <div ref={wrapperRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className={
          hasSelection
            ? "flex items-center gap-1 rounded border border-blue-500 bg-blue-950/40 px-2 py-1 text-xs text-blue-200"
            : "flex items-center gap-1 rounded border border-neutral-700 bg-neutral-900/40 px-2 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
        }
      >
        <span className="text-neutral-500">{label}</span>
        <span className="text-[10px] text-neutral-500">({modeLabel})</span>
        {hasSelection && (
          <span className="rounded bg-blue-600/70 px-1.5 text-[10px] font-medium text-white">
            {selected.length}
          </span>
        )}
        <span className="text-neutral-500">▾</span>
      </button>

      {open && (
        <div
          className="absolute left-0 top-full z-30 mt-1 w-64 rounded border border-neutral-700 bg-neutral-950 p-2 shadow-xl"
          role="dialog"
        >
          <input
            type="search"
            autoFocus
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={`Filter ${label.toLowerCase()}s…`}
            className="mb-2 w-full rounded border border-neutral-700 bg-neutral-900 px-2 py-1 text-xs text-neutral-100 placeholder:text-neutral-500"
          />
          <ul className="max-h-64 overflow-y-auto">
            {filtered.length === 0 && (
              <li className="px-2 py-1 text-xs text-neutral-500">No matches.</li>
            )}
            {filtered.map((o) => {
              const on = selected.includes(o.value);
              return (
                <li key={o.value}>
                  <button
                    type="button"
                    onClick={() => onToggle(o.value)}
                    className={
                      "flex w-full items-center gap-2 rounded px-2 py-1 text-left text-xs hover:bg-neutral-800 " +
                      (on ? "text-blue-200" : "text-neutral-300")
                    }
                  >
                    <span
                      className={
                        on
                          ? "inline-block h-3 w-3 rounded border border-blue-500 bg-blue-500 text-[10px] leading-3 text-white"
                          : "inline-block h-3 w-3 rounded border border-neutral-600"
                      }
                      aria-hidden
                    >
                      {on ? "✓" : ""}
                    </span>
                    {o.colorHex && (
                      <span
                        className="inline-block h-2.5 w-2.5 rounded-full"
                        style={{ background: o.colorHex }}
                      />
                    )}
                    <span className="flex-1">{o.label}</span>
                  </button>
                </li>
              );
            })}
          </ul>
          <div className="mt-2 flex items-center justify-between border-t border-neutral-800 pt-2 text-[11px]">
            <button
              type="button"
              onClick={onClear}
              disabled={selected.length === 0}
              className="text-neutral-400 hover:text-neutral-200 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Clear ({selected.length})
            </button>
            <button
              type="button"
              onClick={() => setOpen(false)}
              className="text-neutral-400 hover:text-neutral-200"
            >
              Done
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Tag grouping (Build #5.114.1)
// ---------------------------------------------------------------------------

export interface TagGroup {
  primary: string;
  secondaries: string[];
}

/**
 * Walks `photos[].tags[]` and partitions the distinct label set into
 * primary→secondaries groups. A label is treated as a primary if any
 * photo carries it with `parentTag === null`; otherwise it's a
 * secondary placed under the parent it's most frequently attributed
 * to. Orphan parents (labels that only appear as another tag's
 * `parentTag`) become primary headers even if no photo tags them
 * directly — preserves the hierarchy view.
 */
function buildTagGroups(photos: Project["photos"]): TagGroup[] {
  const isPrimary = new Set<string>();
  const parentVotesByLabel = new Map<string, Map<string, number>>();
  const allLabels = new Set<string>();
  for (const photo of photos) {
    for (const tag of photo.tags) {
      allLabels.add(tag.label);
      if (tag.parentTag === null) {
        isPrimary.add(tag.label);
      } else {
        allLabels.add(tag.parentTag);
        let votes = parentVotesByLabel.get(tag.label);
        if (!votes) {
          votes = new Map();
          parentVotesByLabel.set(tag.label, votes);
        }
        votes.set(tag.parentTag, (votes.get(tag.parentTag) ?? 0) + 1);
      }
    }
  }
  const groups = new Map<string, Set<string>>();
  for (const label of allLabels) {
    if (isPrimary.has(label)) {
      if (!groups.has(label)) groups.set(label, new Set());
      continue;
    }
    const votes = parentVotesByLabel.get(label);
    if (votes && votes.size > 0) {
      let best = "";
      let bestN = -1;
      for (const [p, n] of votes) {
        if (n > bestN) {
          best = p;
          bestN = n;
        }
      }
      if (!groups.has(best)) groups.set(best, new Set());
      groups.get(best)!.add(label);
    } else {
      // Orphan with no parent occurrences — treat as its own primary.
      if (!groups.has(label)) groups.set(label, new Set());
    }
  }
  const out: TagGroup[] = [];
  for (const [primary, secondaries] of groups) {
    out.push({
      primary,
      secondaries: Array.from(secondaries).sort((a, b) => a.localeCompare(b)),
    });
  }
  out.sort((a, b) => a.primary.localeCompare(b.primary));
  return out;
}

interface MultiSelectChipGroupedProps {
  label: string;
  modeLabel: string;
  groups: TagGroup[];
  selected: string[];
  onToggle: (value: string) => void;
  onClear: () => void;
}

/**
 * Grouped variant of `MultiSelectChip` — same chip-button + popover
 * shell, but the option list is rendered as primary sections with
 * indented secondaries. Search matches against both levels; a group
 * with a matching primary OR any matching secondary stays visible
 * (when the primary matches, all of its secondaries are shown so
 * the structure stays intact).
 */
function MultiSelectChipGrouped({
  label,
  modeLabel,
  groups,
  selected,
  onToggle,
  onClear,
}: MultiSelectChipGroupedProps) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const wrapperRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) return;
    function onClick(e: MouseEvent) {
      const w = wrapperRef.current;
      if (w && !w.contains(e.target as Node)) setOpen(false);
    }
    window.addEventListener("mousedown", onClick);
    return () => window.removeEventListener("mousedown", onClick);
  }, [open]);

  const selectedSet = useMemo(() => new Set(selected), [selected]);

  const filteredGroups = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (q.length === 0) return groups;
    const out: TagGroup[] = [];
    for (const g of groups) {
      const primaryMatch = g.primary.toLowerCase().includes(q);
      if (primaryMatch) {
        out.push(g);
        continue;
      }
      const matched = g.secondaries.filter((s) => s.toLowerCase().includes(q));
      if (matched.length > 0) {
        out.push({ primary: g.primary, secondaries: matched });
      }
    }
    return out;
  }, [groups, query]);

  const hasSelection = selected.length > 0;

  return (
    <div ref={wrapperRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className={
          hasSelection
            ? "flex items-center gap-1 rounded border border-blue-500 bg-blue-950/40 px-2 py-1 text-xs text-blue-200"
            : "flex items-center gap-1 rounded border border-neutral-700 bg-neutral-900/40 px-2 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
        }
      >
        <span className="text-neutral-500">{label}</span>
        <span className="text-[10px] text-neutral-500">({modeLabel})</span>
        {hasSelection && (
          <span className="rounded bg-blue-600/70 px-1.5 text-[10px] font-medium text-white">
            {selected.length}
          </span>
        )}
        <span className="text-neutral-500">▾</span>
      </button>

      {open && (
        <div
          className="absolute left-0 top-full z-30 mt-1 w-72 rounded border border-neutral-700 bg-neutral-950 p-2 shadow-xl"
          role="dialog"
        >
          <input
            type="search"
            autoFocus
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={`Filter ${label.toLowerCase()}s…`}
            className="mb-2 w-full rounded border border-neutral-700 bg-neutral-900 px-2 py-1 text-xs text-neutral-100 placeholder:text-neutral-500"
          />
          <div className="max-h-72 overflow-y-auto">
            {filteredGroups.length === 0 && (
              <div className="px-2 py-1 text-xs text-neutral-500">No matches.</div>
            )}
            {filteredGroups.map((g) => {
              const primaryOn = selectedSet.has(g.primary);
              const selectedSecondaries = g.secondaries.filter((s) =>
                selectedSet.has(s)
              ).length;
              return (
                <div key={g.primary} className="mb-1 last:mb-0">
                  <button
                    type="button"
                    onClick={() => onToggle(g.primary)}
                    className={
                      "flex w-full items-center gap-2 rounded px-2 py-1 text-left text-xs font-semibold hover:bg-neutral-800 " +
                      (primaryOn ? "text-blue-200" : "text-neutral-200")
                    }
                  >
                    <Checkbox on={primaryOn} />
                    <span className="flex-1 uppercase tracking-wide">
                      {g.primary}
                    </span>
                    {selectedSecondaries > 0 && (
                      <span className="rounded bg-blue-600/70 px-1.5 text-[10px] font-medium text-white">
                        {selectedSecondaries}
                      </span>
                    )}
                  </button>
                  {g.secondaries.length > 0 && (
                    <ul className="ml-4 border-l border-neutral-800 pl-2">
                      {g.secondaries.map((s) => {
                        const on = selectedSet.has(s);
                        return (
                          <li key={s}>
                            <button
                              type="button"
                              onClick={() => onToggle(s)}
                              className={
                                "flex w-full items-center gap-2 rounded px-2 py-1 text-left text-xs hover:bg-neutral-800 " +
                                (on ? "text-blue-200" : "text-neutral-400")
                              }
                            >
                              <Checkbox on={on} />
                              <span className="flex-1">{s}</span>
                            </button>
                          </li>
                        );
                      })}
                    </ul>
                  )}
                </div>
              );
            })}
          </div>
          <div className="mt-2 flex items-center justify-between border-t border-neutral-800 pt-2 text-[11px]">
            <button
              type="button"
              onClick={onClear}
              disabled={selected.length === 0}
              className="text-neutral-400 hover:text-neutral-200 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Clear ({selected.length})
            </button>
            <button
              type="button"
              onClick={() => setOpen(false)}
              className="text-neutral-400 hover:text-neutral-200"
            >
              Done
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

function Checkbox({ on }: { on: boolean }) {
  return (
    <span
      className={
        on
          ? "inline-block h-3 w-3 shrink-0 rounded border border-blue-500 bg-blue-500 text-center text-[10px] leading-3 text-white"
          : "inline-block h-3 w-3 shrink-0 rounded border border-neutral-600"
      }
      aria-hidden
    >
      {on ? "✓" : ""}
    </span>
  );
}

interface RemovablePillProps {
  label: string;
  colorHex?: string;
  onRemove: () => void;
}
function RemovablePill({ label, colorHex, onRemove }: RemovablePillProps) {
  return (
    <button
      type="button"
      onClick={onRemove}
      className="flex items-center gap-1 rounded border border-blue-500/60 bg-blue-950/30 px-2 py-1 text-xs text-blue-200 hover:bg-blue-950/60"
      title={`Remove "${label}" filter`}
    >
      {colorHex && (
        <span
          className="inline-block h-2.5 w-2.5 rounded-full"
          style={{ background: colorHex }}
        />
      )}
      <span>{label}</span>
      <span className="text-blue-300/80">×</span>
    </button>
  );
}
