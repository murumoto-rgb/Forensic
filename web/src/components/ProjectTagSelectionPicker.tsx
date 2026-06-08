import { useEffect, useMemo, useState } from "react";
import type {
  InvestigationContext,
  PrimaryTagEntry,
  Project,
  ProjectTagSelection,
  SecondaryTagEntry,
  TagLibrary,
} from "@forensic/shared";
import { api } from "../lib/api";

/**
 * Three-level tag-selection picker (Build #5.86.1).
 *
 * Mirrors iOS `ProjectTagSelectionSheet` — context (multi-select) →
 * primary (multi-select, scoped by selected contexts) → secondary
 * (per-primary, every secondary defaults on; deselecting populates
 * `deselectedSecondariesByPrimary`).
 *
 * Loads the canonical library via `api.getTagLibraryConfig()` at
 * mount; the picker uses local draft state so partial edits don't
 * round-trip the manifest mid-typing. "Save selection" commits the
 * draft to `project.tagSelection`; "Cancel" closes without writes.
 * "Clear" inside the editor zeroes out the draft.
 *
 * Layout: a three-column grid on wide viewports, stacked accordions
 * on narrow. Tailwind's `lg:` breakpoints handle that.
 */
interface Props {
  project: Project;
  canEdit: boolean;
  onClose: () => void;
  onCommit: (next: ProjectTagSelection | null) => void;
}

export function ProjectTagSelectionPicker({
  project,
  canEdit,
  onClose,
  onCommit,
}: Props) {
  const [library, setLibrary] = useState<TagLibrary | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [draft, setDraft] = useState<ProjectTagSelection>(() =>
    cloneSelection(project.tagSelection)
  );
  const [activePrimary, setActivePrimary] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    api
      .getTagLibraryConfig()
      .then((cfg) => {
        if (cancelled) return;
        if (!cfg) {
          setLoadError(
            "Tag library hasn't been seeded yet — open the iOS app once so it can push the default vocabulary."
          );
          return;
        }
        setLibrary(cfg.value);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setLoadError(
          e instanceof Error
            ? `Failed to load tag library: ${e.message}`
            : "Failed to load tag library"
        );
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const contextById = useMemo(() => {
    const map = new Map<string, InvestigationContext>();
    if (library) {
      for (const c of library.contexts) map.set(c.id, c);
    }
    return map;
  }, [library]);

  const primaryById = useMemo(() => {
    const map = new Map<string, PrimaryTagEntry>();
    if (library) {
      for (const c of library.contexts) {
        for (const p of c.primaries) map.set(p.id, p);
      }
    }
    return map;
  }, [library]);

  const selectedContextIDs = new Set(draft.contextIDs);

  // Active primary defaults to the first selected primary across all
  // contexts so the secondary column has something to show when the
  // user first opens the picker on an existing selection.
  useEffect(() => {
    if (activePrimary != null) return;
    for (const ctxID of draft.contextIDs) {
      const primaries = draft.primariesByContext[ctxID] ?? [];
      const first = primaries[0];
      if (first != null) {
        setActivePrimary(first);
        return;
      }
    }
  }, [activePrimary, draft]);

  function toggleContext(ctxID: string) {
    if (!canEdit) return;
    const isOn = selectedContextIDs.has(ctxID);
    if (isOn) {
      // Drop the context AND its primary entries from the selection.
      const nextContextIDs = draft.contextIDs.filter((id) => id !== ctxID);
      const { [ctxID]: _droppedPrimaries, ...rest } = draft.primariesByContext;
      setDraft({
        ...draft,
        contextIDs: nextContextIDs,
        primariesByContext: rest,
      });
    } else {
      setDraft({ ...draft, contextIDs: [...draft.contextIDs, ctxID] });
    }
  }

  function togglePrimary(ctxID: string, primaryID: string) {
    if (!canEdit) return;
    const cur = draft.primariesByContext[ctxID] ?? [];
    const isOn = cur.includes(primaryID);
    const nextPrimaries = isOn
      ? cur.filter((id) => id !== primaryID)
      : [...cur, primaryID];

    // If we're turning a primary OFF, drop its deselections too —
    // they'd be stranded otherwise.
    let nextDeselect = draft.deselectedSecondariesByPrimary;
    if (isOn && primaryID in nextDeselect) {
      const { [primaryID]: _dropped, ...rest } = nextDeselect;
      nextDeselect = rest;
    }

    setDraft({
      ...draft,
      primariesByContext: { ...draft.primariesByContext, [ctxID]: nextPrimaries },
      deselectedSecondariesByPrimary: nextDeselect,
    });

    // If they turned a primary ON, focus it so the secondary column
    // updates without an extra click.
    if (!isOn) setActivePrimary(primaryID);
  }

  function toggleSecondary(primaryID: string, secondaryID: string) {
    if (!canEdit) return;
    const cur = draft.deselectedSecondariesByPrimary[primaryID] ?? [];
    const isDeselected = cur.includes(secondaryID);
    const next = isDeselected
      ? cur.filter((id) => id !== secondaryID)
      : [...cur, secondaryID];
    const map = { ...draft.deselectedSecondariesByPrimary };
    if (next.length === 0) {
      delete map[primaryID];
    } else {
      map[primaryID] = next;
    }
    setDraft({ ...draft, deselectedSecondariesByPrimary: map });
  }

  function clearAll() {
    setDraft({
      contextIDs: [],
      primariesByContext: {},
      deselectedSecondariesByPrimary: {},
    });
    setActivePrimary(null);
  }

  function commit() {
    // Empty draft → null selection (means "use the whole library").
    const isEmpty =
      draft.contextIDs.length === 0 &&
      Object.keys(draft.primariesByContext).length === 0 &&
      Object.keys(draft.deselectedSecondariesByPrimary).length === 0;
    onCommit(isEmpty ? null : draft);
    onClose();
  }

  return (
    <div
      role="dialog"
      aria-modal="true"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
    >
      <div className="flex h-full max-h-[90vh] w-full max-w-5xl flex-col gap-3 rounded-lg border border-neutral-700 bg-neutral-950 p-5 shadow-2xl">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-neutral-100">
            Project tag selection
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
          >
            Cancel
          </button>
        </div>

        <p className="text-xs text-neutral-500">
          Scope which contexts, primaries, and secondaries the AI is
          allowed to use for this project. Empty = use the entire
          library. Mirrors iOS Project → AI → Tag selection.
        </p>

        {loadError && (
          <div className="rounded border border-red-800 bg-red-950/40 p-2 text-xs text-red-300">
            {loadError}
          </div>
        )}

        {!library && !loadError && (
          <div className="text-xs text-neutral-500">Loading tag library…</div>
        )}

        {library && (
          <div className="grid min-h-0 flex-1 grid-cols-1 gap-3 lg:grid-cols-3">
            {/* Column 1: Contexts */}
            <Column title={`Contexts (${draft.contextIDs.length} selected)`}>
              {library.contexts.map((ctx) => {
                const on = selectedContextIDs.has(ctx.id);
                return (
                  <RowCheckbox
                    key={ctx.id}
                    label={ctx.name}
                    checked={on}
                    onToggle={() => toggleContext(ctx.id)}
                    disabled={!canEdit}
                  />
                );
              })}
            </Column>

            {/* Column 2: Primaries */}
            <Column title="Primaries">
              {draft.contextIDs.length === 0 && (
                <div className="text-xs text-neutral-600">
                  Select one or more contexts on the left.
                </div>
              )}
              {draft.contextIDs.map((ctxID) => {
                const ctx = contextById.get(ctxID);
                if (!ctx) return null;
                const selected = new Set(
                  draft.primariesByContext[ctxID] ?? []
                );
                return (
                  <div key={ctxID} className="mb-3">
                    <div className="mb-1 text-[10px] uppercase tracking-wide text-neutral-500">
                      {ctx.name}
                    </div>
                    {ctx.primaries.map((p) => {
                      const on = selected.has(p.id);
                      const focused = activePrimary === p.id;
                      return (
                        <div
                          key={p.id}
                          className={
                            focused
                              ? "rounded bg-blue-950/40 px-1"
                              : ""
                          }
                        >
                          <RowCheckbox
                            label={p.name}
                            checked={on}
                            onToggle={() => togglePrimary(ctxID, p.id)}
                            onFocus={() => on && setActivePrimary(p.id)}
                            disabled={!canEdit}
                          />
                        </div>
                      );
                    })}
                  </div>
                );
              })}
            </Column>

            {/* Column 3: Secondaries for focused primary */}
            <Column title="Secondaries">
              {activePrimary === null && (
                <div className="text-xs text-neutral-600">
                  Click a primary on the left to edit its secondaries.
                </div>
              )}
              {activePrimary !== null &&
                renderSecondaries({
                  primary: primaryById.get(activePrimary) ?? null,
                  deselected: new Set(
                    draft.deselectedSecondariesByPrimary[activePrimary] ?? []
                  ),
                  canEdit,
                  onToggle: (sid) => toggleSecondary(activePrimary, sid),
                })}
            </Column>
          </div>
        )}

        <div className="flex items-center justify-between border-t border-neutral-800 pt-3">
          <button
            type="button"
            onClick={clearAll}
            disabled={!canEdit}
            className="rounded border border-neutral-700 px-3 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800 disabled:opacity-50"
          >
            Clear all
          </button>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded border border-neutral-700 px-3 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
            >
              Cancel
            </button>
            <button
              type="button"
              onClick={commit}
              disabled={!canEdit}
              className="rounded border border-blue-700 bg-blue-900/60 px-3 py-1.5 text-sm text-blue-100 hover:bg-blue-900/80 disabled:opacity-50"
            >
              Save selection
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function Column({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex min-h-0 flex-col rounded border border-neutral-800 bg-neutral-900/40">
      <div className="border-b border-neutral-800 px-3 py-2 text-xs font-semibold text-neutral-300">
        {title}
      </div>
      <div className="flex-1 overflow-y-auto p-2">{children}</div>
    </div>
  );
}

function RowCheckbox({
  label,
  checked,
  onToggle,
  onFocus,
  disabled,
}: {
  label: string;
  checked: boolean;
  onToggle: () => void;
  onFocus?: () => void;
  disabled?: boolean;
}) {
  return (
    <label
      className={
        "flex cursor-pointer items-center gap-2 rounded py-0.5 text-sm text-neutral-200 hover:bg-neutral-800/60" +
        (disabled ? " cursor-not-allowed opacity-50" : "")
      }
      onClick={onFocus}
    >
      <input
        type="checkbox"
        checked={checked}
        onChange={onToggle}
        disabled={disabled}
        className="accent-blue-600"
      />
      <span>{label}</span>
    </label>
  );
}

function renderSecondaries({
  primary,
  deselected,
  canEdit,
  onToggle,
}: {
  primary: PrimaryTagEntry | null;
  deselected: Set<string>;
  canEdit: boolean;
  onToggle: (secondaryID: string) => void;
}) {
  if (!primary) {
    return (
      <div className="text-xs text-neutral-600">
        Primary not in current library — was it deleted?
      </div>
    );
  }
  if (primary.secondaries.length === 0) {
    return (
      <div className="text-xs text-neutral-600">
        This primary has no secondaries.
      </div>
    );
  }
  return (
    <>
      <div className="mb-2 text-[10px] uppercase tracking-wide text-neutral-500">
        {primary.name}
      </div>
      {primary.secondaries.map((s: SecondaryTagEntry) => {
        const isDeselected = deselected.has(s.id);
        return (
          <RowCheckbox
            key={s.id}
            label={s.name}
            // Visual semantic: checked = will be used by AI.
            // `deselectedSecondariesByPrimary` is exclusion list.
            checked={!isDeselected}
            onToggle={() => onToggle(s.id)}
            disabled={!canEdit}
          />
        );
      })}
      <div className="mt-2 text-[11px] text-neutral-600">
        Every secondary defaults on. Uncheck to exclude from AI tagging
        for this project.
      </div>
    </>
  );
}

function cloneSelection(s: ProjectTagSelection | null): ProjectTagSelection {
  if (!s) {
    return {
      contextIDs: [],
      primariesByContext: {},
      deselectedSecondariesByPrimary: {},
    };
  }
  return {
    contextIDs: [...s.contextIDs],
    primariesByContext: Object.fromEntries(
      Object.entries(s.primariesByContext).map(([k, v]) => [k, [...v]])
    ),
    deselectedSecondariesByPrimary: Object.fromEntries(
      Object.entries(s.deselectedSecondariesByPrimary).map(([k, v]) => [
        k,
        [...v],
      ])
    ),
  };
}
