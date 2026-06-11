import { useEffect, useState } from "react";
import type {
  InvestigationContext,
  PrimaryTagEntry,
  SecondaryTagEntry,
  TagLibrary,
} from "@forensic/shared";
import { api } from "../lib/api";
import { useEscapeKey } from "../lib/useEscapeKey";

/**
 * Bulk tag picker (Build #6.36.1).
 *
 * Replaces the free-text "Apply tag" input in `SelectionActionBar`
 * with a controlled-vocabulary picker. Mirrors iOS's
 * `BulkTagPickerSheet`: tap a primary to apply (`parentTag: null`),
 * tap a secondary to apply with its primary as the parent. The
 * modal stays open after each apply so the user can stack tags;
 * a transient "Applied X" banner confirms each tap.
 *
 * Vocabulary source: `app_config.tagLibrary` (`api.getTagLibrary
 * Config()`) — the team-shared library the AI pipeline already uses,
 * synced between iOS and web since #5.36.1. iOS's bulk picker
 * currently reads its own hardcoded `ControlledVocabulary` seed
 * (separate file); aligning that to the synced library is a small
 * follow-on tracked in `docs/deferred-work.md`.
 *
 * Empty / unloaded library: falls back to the existing free-text
 * input so the picker is never useless. The label tells the user
 * to seed the library on iOS / the admin page if they're tagging
 * with strings.
 */
interface Props {
  count: number;
  /** Apply a tag to every selected photo. `parentTag` is null for
   *  primary picks, the primary's name for secondary picks (matching
   *  iOS `store.addTag(..., parentTag:)`). */
  onApplyTag: (label: string, parentTag: string | null) => void;
  onClose: () => void;
}

export function BulkTagPickerModal({ count, onApplyTag, onClose }: Props) {
  useEscapeKey(true, onClose);
  const [library, setLibrary] = useState<TagLibrary | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [lastApplied, setLastApplied] = useState<{
    label: string;
    parent: string | null;
    at: number;
  } | null>(null);
  const [customTag, setCustomTag] = useState("");

  useEffect(() => {
    let cancelled = false;
    api
      .getTagLibraryConfig()
      .then((cfg) => {
        if (cancelled) return;
        if (!cfg) {
          setLoadError(
            "Tag library hasn't been seeded yet — open the iOS app once so it can push the default vocabulary, or set one up at Admin → Tag library. Use the custom-tag input below in the meantime."
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

  // Auto-clear the "applied" banner after 4 s so it doesn't pile up
  // across rapid taps. iOS uses the same 4-second window.
  useEffect(() => {
    if (!lastApplied) return;
    const id = window.setTimeout(() => {
      setLastApplied((cur) =>
        cur && cur.at === lastApplied.at ? null : cur
      );
    }, 4000);
    return () => window.clearTimeout(id);
  }, [lastApplied]);

  function apply(label: string, parent: string | null) {
    const trimmed = label.trim();
    if (trimmed.length === 0) return;
    onApplyTag(trimmed, parent);
    setLastApplied({ label: trimmed, parent, at: Date.now() });
  }

  function applyCustom() {
    apply(customTag, null);
    setCustomTag("");
  }

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`Apply tag to ${count} photo${count === 1 ? "" : "s"}`}
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
    >
      <div className="flex h-full max-h-[85vh] w-full max-w-3xl flex-col gap-3 rounded-lg border border-neutral-700 bg-neutral-950 p-5 shadow-2xl">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-neutral-100">
            Apply tag · {count} photo{count === 1 ? "" : "s"}
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
          >
            Done
          </button>
        </div>

        <p className="text-xs text-neutral-500">
          Tap a primary to apply it. Tap a secondary to apply it under
          its primary. Modal stays open — stack tags as needed. Custom
          (free-text) tags via the input at the bottom.
        </p>

        {lastApplied && (
          <div className="rounded border border-emerald-700 bg-emerald-950/40 px-3 py-1.5 text-xs text-emerald-200">
            Applied{" "}
            <span className="font-medium">{lastApplied.label}</span>
            {lastApplied.parent && (
              <span className="text-emerald-400">
                {" "}
                (under {lastApplied.parent})
              </span>
            )}
          </div>
        )}

        {loadError && (
          <div className="rounded border border-amber-800 bg-amber-950/30 p-2 text-xs text-amber-200">
            {loadError}
          </div>
        )}

        {!library && !loadError && (
          <div className="text-xs text-neutral-500">Loading tag library…</div>
        )}

        {library && (
          <div className="flex-1 overflow-y-auto rounded border border-neutral-800 bg-neutral-900/40 p-3">
            {library.contexts.length === 0 ? (
              <div className="text-xs text-neutral-500">
                Tag library is empty. Use the custom-tag input below or
                seed the library in Admin → Tag library.
              </div>
            ) : (
              library.contexts.map((ctx) => (
                <ContextGroup
                  key={ctx.id}
                  ctx={ctx}
                  onApplyPrimary={(p) => apply(p.name, null)}
                  onApplySecondary={(p, s) => apply(s.name, p.name)}
                />
              ))
            )}
          </div>
        )}

        <div className="flex items-center gap-2 border-t border-neutral-800 pt-3">
          <label className="flex flex-1 items-center gap-2 text-xs text-neutral-300">
            <span className="text-neutral-500">Custom tag:</span>
            <input
              type="text"
              value={customTag}
              onChange={(e) => setCustomTag(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  applyCustom();
                }
              }}
              placeholder="label, then Enter"
              className="flex-1 rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100 placeholder:text-neutral-500"
            />
          </label>
          <button
            type="button"
            onClick={applyCustom}
            disabled={customTag.trim().length === 0}
            className="rounded border border-neutral-700 px-3 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Apply
          </button>
        </div>
      </div>
    </div>
  );
}

function ContextGroup({
  ctx,
  onApplyPrimary,
  onApplySecondary,
}: {
  ctx: InvestigationContext;
  onApplyPrimary: (p: PrimaryTagEntry) => void;
  onApplySecondary: (p: PrimaryTagEntry, s: SecondaryTagEntry) => void;
}) {
  if (ctx.primaries.length === 0) return null;
  return (
    <section className="mb-4 last:mb-0">
      <div className="mb-2 text-[10px] uppercase tracking-wide text-neutral-500">
        {ctx.name}
      </div>
      <div className="flex flex-col gap-2">
        {ctx.primaries.map((p) => (
          <PrimaryGroup
            key={p.id}
            primary={p}
            onApplyPrimary={() => onApplyPrimary(p)}
            onApplySecondary={(s) => onApplySecondary(p, s)}
          />
        ))}
      </div>
    </section>
  );
}

function PrimaryGroup({
  primary,
  onApplyPrimary,
  onApplySecondary,
}: {
  primary: PrimaryTagEntry;
  onApplyPrimary: () => void;
  onApplySecondary: (s: SecondaryTagEntry) => void;
}) {
  return (
    <div className="rounded border border-neutral-800 bg-neutral-950/60 p-2">
      <button
        type="button"
        onClick={onApplyPrimary}
        className="mb-2 rounded border border-teal-700 bg-teal-900/40 px-2 py-1 text-xs font-medium text-teal-100 hover:bg-teal-900/60"
        title={`Apply "${primary.name}" to the selection`}
      >
        {primary.name}
      </button>
      {primary.secondaries.length > 0 && (
        <div className="ml-3 flex flex-wrap gap-1">
          {primary.secondaries.map((s) => (
            <button
              key={s.id}
              type="button"
              onClick={() => onApplySecondary(s)}
              className="rounded border border-violet-700 bg-violet-950/40 px-2 py-0.5 text-xs text-violet-200 hover:bg-violet-900/40"
              title={`Apply "${s.name}" under ${primary.name}`}
            >
              {s.name}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
