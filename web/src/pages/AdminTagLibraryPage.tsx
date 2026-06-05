import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import type {
  InvestigationContext,
  PrimaryTagEntry,
  SecondaryTagEntry,
  TagLibrary,
} from "@forensic/shared";
import { signOutLocal } from "../lib/supabase";
import { api, ApiError } from "../lib/api";

/**
 * Admin editor for the team's app-wide tag library — the three-level
 * catalog (Investigation Context → Primary Tag → Secondary Tag) that
 * scopes the AI tagging prompt. Reads / writes `/v1/config/tagLibrary`
 * (Build #5.44.1; backed by the `app_config` table from #5.35.1).
 *
 * Office staff can edit the library straight from a browser — no iPad
 * needed. The editor stays optimistically-concurrent against iOS edits
 * via the standard revision token; mismatch → 409 → page surfaces a
 * "tag library was updated elsewhere; reload to merge" banner.
 *
 * UI mirrors iOS's Tag Library Manager: collapsible context sections,
 * inline rename, add/delete at every level. Reorder + drag-and-drop
 * are intentionally deferred — they're a Phase 5+ polish item and
 * the library shape is order-preserving (each tag has a stable UUID
 * so reorder can be added without breaking existing selections).
 */
interface Props {
  session: Session;
}

interface LoadState {
  /** Null = library hasn't been pushed to server yet (404). The user
   *  can still create one from scratch and PUT it with
   *  `expectedRevision: null`. */
  library: TagLibrary | null;
  revision: string | null;
}

export function AdminTagLibraryPage({ session }: Props) {
  const [load, setLoad] = useState<LoadState | "loading" | { error: string }>(
    "loading"
  );
  // Local edit copy — separate from `load` so a save error doesn't
  // wipe in-progress edits.
  const [draft, setDraft] = useState<TagLibrary | null>(null);
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);

  // Track which contexts are expanded — purely UI state; doesn't
  // persist across reloads.
  const [expandedContexts, setExpandedContexts] = useState<Set<string>>(
    new Set()
  );

  // Mirror ref for the latest revision so the save handler reads the
  // freshest value (same discipline as ProjectDetailPage).
  const revisionRef = useRef<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoad("loading");
    api
      .getTagLibraryConfig()
      .then((resp) => {
        if (cancelled) return;
        if (!resp) {
          setLoad({ library: null, revision: null });
          setDraft({ contexts: [], seedVersion: 1 });
          revisionRef.current = null;
        } else {
          setLoad({ library: resp.value, revision: resp.revision });
          setDraft(structuredClone(resp.value));
          revisionRef.current = resp.revision;
          // Auto-expand all contexts on a fresh load so the editor
          // doesn't open with a blank wall of headers.
          setExpandedContexts(new Set(resp.value.contexts.map((c) => c.id)));
        }
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        const message =
          e instanceof ApiError
            ? `${e.status} ${e.errorCode}: ${e.message}`
            : "Failed to load tag library";
        setLoad({ error: message });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  function markDirty(next: TagLibrary) {
    setDraft(next);
    setDirty(true);
    setSavedAt(null);
    setSaveError(null);
  }

  async function save() {
    if (!draft) return;
    setSaving(true);
    setSaveError(null);
    try {
      const expectedRevision = revisionRef.current;
      const resp = await fetch(
        `${import.meta.env.VITE_API_URL ?? ""}/v1/config/tagLibrary`,
        {
          method: "PUT",
          headers: {
            "content-type": "application/json",
            ...(await authHeader()),
          },
          body: JSON.stringify({
            value: draft,
            expectedRevision,
          }),
        }
      );
      if (!resp.ok) {
        const body = (await resp.json().catch(() => ({}))) as {
          error?: string;
          message?: string;
        };
        if (resp.status === 409) {
          throw new ApiError(
            409,
            body.error ?? "revision_mismatch",
            body.message ??
              "The tag library was modified elsewhere. Reload to pick up the latest version, then re-apply your edits."
          );
        }
        throw new ApiError(
          resp.status,
          body.error ?? "unknown",
          body.message ?? `Save failed (${resp.status})`
        );
      }
      const okBody = (await resp.json()) as { revision: string };
      revisionRef.current = okBody.revision;
      setLoad({ library: structuredClone(draft), revision: okBody.revision });
      setDirty(false);
      setSavedAt(Date.now());
    } catch (e: unknown) {
      const message =
        e instanceof ApiError
          ? e.message
          : e instanceof Error
            ? e.message
            : "Save failed.";
      setSaveError(message);
    } finally {
      setSaving(false);
    }
  }

  function reloadFromServer() {
    setDirty(false);
    setSaveError(null);
    setDraft(load !== "loading" && "library" in load ? structuredClone(load.library ?? { contexts: [], seedVersion: 1 }) : null);
  }

  /**
   * Replace the editor draft with iOS's bundled default (Build
   * #5.48.1). Fetched live from `/v1/config/tagLibraryDefault` so
   * we always show whatever the latest iOS build pushed. Doesn't
   * persist — user still has to click Save to overwrite the
   * editable `tagLibrary` row.
   *
   * If iOS has never connected since #5.48.1 shipped (404 on
   * fetch), surfaces a friendly hint asking the user to open the
   * iOS app once.
   */
  async function restoreDefault() {
    if (
      !window.confirm(
        "Replace your current draft with iOS's bundled default tag library?\n\nYou'll still need to click Save to persist the restore."
      )
    ) {
      return;
    }
    setSaveError(null);
    try {
      const resp = await api.getTagLibraryDefaultConfig();
      if (!resp) {
        setSaveError(
          "No bundled default on the server yet. Open the iOS app once (any signed-in session triggers a push) and try again."
        );
        return;
      }
      setDraft(structuredClone(resp.value));
      setDirty(true);
      setSavedAt(null);
      setExpandedContexts(new Set(resp.value.contexts.map((c) => c.id)));
    } catch (e: unknown) {
      const message =
        e instanceof ApiError
          ? e.message
          : e instanceof Error
            ? e.message
            : "Failed to fetch bundled default.";
      setSaveError(message);
    }
  }

  // ---------------------------------------------------------------
  // Editor helpers — all return a new TagLibrary value (immutable
  // updates) so React diffing sees a fresh reference each time.
  // ---------------------------------------------------------------

  function addContext() {
    if (!draft) return;
    const ctx: InvestigationContext = {
      id: crypto.randomUUID(),
      name: "New context",
      primaries: [],
    };
    const next: TagLibrary = {
      ...draft,
      contexts: [...draft.contexts, ctx],
    };
    setExpandedContexts((s) => new Set([...s, ctx.id]));
    markDirty(next);
  }

  function renameContext(contextId: string, name: string) {
    if (!draft) return;
    markDirty({
      ...draft,
      contexts: draft.contexts.map((c) =>
        c.id === contextId ? { ...c, name } : c
      ),
    });
  }

  function deleteContext(contextId: string) {
    if (!draft) return;
    if (
      !window.confirm(
        "Delete this entire context AND every primary / secondary under it? Projects that referenced these IDs will silently drop them on next load."
      )
    ) {
      return;
    }
    markDirty({
      ...draft,
      contexts: draft.contexts.filter((c) => c.id !== contextId),
    });
  }

  function addPrimary(contextId: string) {
    if (!draft) return;
    const primary: PrimaryTagEntry = {
      id: crypto.randomUUID(),
      name: "New primary tag",
      secondaries: [],
    };
    markDirty({
      ...draft,
      contexts: draft.contexts.map((c) =>
        c.id === contextId
          ? { ...c, primaries: [...c.primaries, primary] }
          : c
      ),
    });
  }

  function renamePrimary(
    contextId: string,
    primaryId: string,
    name: string
  ) {
    if (!draft) return;
    markDirty({
      ...draft,
      contexts: draft.contexts.map((c) =>
        c.id === contextId
          ? {
              ...c,
              primaries: c.primaries.map((p) =>
                p.id === primaryId ? { ...p, name } : p
              ),
            }
          : c
      ),
    });
  }

  function deletePrimary(contextId: string, primaryId: string) {
    if (!draft) return;
    if (!window.confirm("Delete this primary and its secondaries?")) return;
    markDirty({
      ...draft,
      contexts: draft.contexts.map((c) =>
        c.id === contextId
          ? { ...c, primaries: c.primaries.filter((p) => p.id !== primaryId) }
          : c
      ),
    });
  }

  function addSecondary(contextId: string, primaryId: string) {
    if (!draft) return;
    const sec: SecondaryTagEntry = {
      id: crypto.randomUUID(),
      name: "New secondary tag",
    };
    markDirty({
      ...draft,
      contexts: draft.contexts.map((c) =>
        c.id === contextId
          ? {
              ...c,
              primaries: c.primaries.map((p) =>
                p.id === primaryId
                  ? { ...p, secondaries: [...p.secondaries, sec] }
                  : p
              ),
            }
          : c
      ),
    });
  }

  function renameSecondary(
    contextId: string,
    primaryId: string,
    secondaryId: string,
    name: string
  ) {
    if (!draft) return;
    markDirty({
      ...draft,
      contexts: draft.contexts.map((c) =>
        c.id === contextId
          ? {
              ...c,
              primaries: c.primaries.map((p) =>
                p.id === primaryId
                  ? {
                      ...p,
                      secondaries: p.secondaries.map((s) =>
                        s.id === secondaryId ? { ...s, name } : s
                      ),
                    }
                  : p
              ),
            }
          : c
      ),
    });
  }

  function deleteSecondary(
    contextId: string,
    primaryId: string,
    secondaryId: string
  ) {
    if (!draft) return;
    markDirty({
      ...draft,
      contexts: draft.contexts.map((c) =>
        c.id === contextId
          ? {
              ...c,
              primaries: c.primaries.map((p) =>
                p.id === primaryId
                  ? {
                      ...p,
                      secondaries: p.secondaries.filter(
                        (s) => s.id !== secondaryId
                      ),
                    }
                  : p
              ),
            }
          : c
      ),
    });
  }

  function toggleExpanded(contextId: string) {
    setExpandedContexts((s) => {
      const next = new Set(s);
      if (next.has(contextId)) next.delete(contextId);
      else next.add(contextId);
      return next;
    });
  }

  // ---------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------

  return (
    <div className="mx-auto max-w-4xl px-6 py-10">
      <header className="mb-8 flex items-start justify-between gap-4">
        <div className="flex flex-col gap-1">
          <Link
            to="/projects"
            className="text-xs text-neutral-500 hover:text-neutral-300"
          >
            ← All projects
          </Link>
          <h1 className="text-2xl font-semibold">Tag library</h1>
          <p className="text-xs text-neutral-500">
            Three-level catalog the AI tagging prompt scopes against.
            Edits land team-wide on save; iOS pulls the new library at
            launch / sign-in / "Sync now".
          </p>
        </div>
        <div className="flex flex-col items-end gap-2 text-right">
          <span className="text-xs text-neutral-500">{session.user.email}</span>
          <div className="flex gap-2">
            <Link
              to="/admin/ai-rules"
              className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
            >
              AI rules
            </Link>
            <button
              type="button"
              onClick={() => signOutLocal()}
              className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
            >
              Sign out
            </button>
          </div>
        </div>
      </header>

      {load === "loading" && (
        <div className="text-sm text-neutral-500">Loading tag library…</div>
      )}
      {load !== "loading" && "error" in load && (
        <div className="rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
          {load.error}
        </div>
      )}

      {draft && load !== "loading" && !("error" in load) && (
        <>
          {/* Sticky save bar */}
          <div className="sticky top-0 z-10 mb-4 flex items-center justify-between gap-3 rounded border border-neutral-800 bg-neutral-950/95 p-3 shadow-sm backdrop-blur">
            <div className="flex items-center gap-3 text-xs">
              {dirty && (
                <span className="rounded bg-amber-900/40 px-2 py-0.5 text-amber-200">
                  Unsaved edits
                </span>
              )}
              {!dirty && savedAt && Date.now() - savedAt < 5000 && (
                <span className="rounded bg-emerald-900/40 px-2 py-0.5 text-emerald-200">
                  Saved
                </span>
              )}
              {!dirty && (!savedAt || Date.now() - savedAt >= 5000) && (
                <span className="text-neutral-500">No pending changes</span>
              )}
              {load.revision != null && (
                <span className="font-mono text-[10px] text-neutral-600">
                  rev {load.revision.slice(0, 8)}
                </span>
              )}
            </div>
            <div className="flex gap-2">
              <button
                type="button"
                onClick={restoreDefault}
                disabled={saving}
                className="rounded border border-amber-700 px-3 py-1 text-xs text-amber-200 hover:bg-amber-950/40 disabled:cursor-not-allowed disabled:opacity-50"
                title="Replace the current draft with iOS's bundled default. You still need to click Save to persist the restore."
              >
                Restore default
              </button>
              <button
                type="button"
                onClick={reloadFromServer}
                disabled={!dirty || saving}
                className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
              >
                Discard
              </button>
              <button
                type="button"
                onClick={save}
                disabled={!dirty || saving}
                className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1 text-xs font-medium text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {saving ? "Saving…" : "Save"}
              </button>
            </div>
          </div>

          {saveError && (
            <div className="mb-3 rounded border border-red-800 bg-red-950/40 p-3 text-xs text-red-300">
              {saveError}
            </div>
          )}

          <div className="flex flex-col gap-3">
            {draft.contexts.map((ctx) => (
              <ContextEditor
                key={ctx.id}
                context={ctx}
                expanded={expandedContexts.has(ctx.id)}
                onToggle={() => toggleExpanded(ctx.id)}
                onRename={(name) => renameContext(ctx.id, name)}
                onDelete={() => deleteContext(ctx.id)}
                onAddPrimary={() => addPrimary(ctx.id)}
                onRenamePrimary={(pid, name) => renamePrimary(ctx.id, pid, name)}
                onDeletePrimary={(pid) => deletePrimary(ctx.id, pid)}
                onAddSecondary={(pid) => addSecondary(ctx.id, pid)}
                onRenameSecondary={(pid, sid, name) =>
                  renameSecondary(ctx.id, pid, sid, name)
                }
                onDeleteSecondary={(pid, sid) =>
                  deleteSecondary(ctx.id, pid, sid)
                }
              />
            ))}

            <button
              type="button"
              onClick={addContext}
              className="self-start rounded border border-dashed border-neutral-700 px-3 py-2 text-xs text-neutral-400 hover:bg-neutral-800 hover:text-neutral-200"
            >
              + Add context
            </button>

            {draft.contexts.length === 0 && (
              <div className="mt-4 rounded border border-neutral-800 bg-neutral-900/40 p-4 text-xs text-neutral-400">
                Tag library is empty. Add at least one context, then at
                least one primary tag under it, before AI tagging will
                work on any project that picks this context.
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}

function ContextEditor({
  context,
  expanded,
  onToggle,
  onRename,
  onDelete,
  onAddPrimary,
  onRenamePrimary,
  onDeletePrimary,
  onAddSecondary,
  onRenameSecondary,
  onDeleteSecondary,
}: {
  context: InvestigationContext;
  expanded: boolean;
  onToggle: () => void;
  onRename: (name: string) => void;
  onDelete: () => void;
  onAddPrimary: () => void;
  onRenamePrimary: (primaryId: string, name: string) => void;
  onDeletePrimary: (primaryId: string) => void;
  onAddSecondary: (primaryId: string) => void;
  onRenameSecondary: (
    primaryId: string,
    secondaryId: string,
    name: string
  ) => void;
  onDeleteSecondary: (primaryId: string, secondaryId: string) => void;
}) {
  return (
    <div className="rounded border border-neutral-800 bg-neutral-950">
      <div className="flex items-center gap-2 border-b border-neutral-800 px-3 py-2">
        <button
          type="button"
          onClick={onToggle}
          className="text-xs text-neutral-400 hover:text-neutral-200"
          aria-label={expanded ? "Collapse context" : "Expand context"}
        >
          {expanded ? "▾" : "▸"}
        </button>
        <input
          type="text"
          value={context.name}
          onChange={(e) => onRename(e.currentTarget.value)}
          className="flex-1 rounded border border-transparent bg-transparent px-1 py-0.5 text-sm font-medium text-neutral-100 hover:border-neutral-700 focus:border-neutral-600 focus:outline-none"
        />
        <span className="font-mono text-[10px] text-neutral-600">
          {context.primaries.length} primary
          {context.primaries.length === 1 ? "" : "s"}
        </span>
        <button
          type="button"
          onClick={onDelete}
          className="rounded border border-neutral-800 px-2 py-0.5 text-[10px] text-neutral-500 hover:border-red-700 hover:text-red-300"
          title="Delete context"
        >
          Delete
        </button>
      </div>
      {expanded && (
        <div className="flex flex-col gap-2 px-3 py-2">
          {context.primaries.map((primary) => (
            <PrimaryEditor
              key={primary.id}
              primary={primary}
              onRename={(name) => onRenamePrimary(primary.id, name)}
              onDelete={() => onDeletePrimary(primary.id)}
              onAddSecondary={() => onAddSecondary(primary.id)}
              onRenameSecondary={(sid, name) =>
                onRenameSecondary(primary.id, sid, name)
              }
              onDeleteSecondary={(sid) => onDeleteSecondary(primary.id, sid)}
            />
          ))}
          <button
            type="button"
            onClick={onAddPrimary}
            className="self-start rounded border border-dashed border-neutral-700 px-2 py-1 text-[11px] text-neutral-500 hover:bg-neutral-800 hover:text-neutral-200"
          >
            + Add primary tag
          </button>
        </div>
      )}
    </div>
  );
}

function PrimaryEditor({
  primary,
  onRename,
  onDelete,
  onAddSecondary,
  onRenameSecondary,
  onDeleteSecondary,
}: {
  primary: PrimaryTagEntry;
  onRename: (name: string) => void;
  onDelete: () => void;
  onAddSecondary: () => void;
  onRenameSecondary: (secondaryId: string, name: string) => void;
  onDeleteSecondary: (secondaryId: string) => void;
}) {
  return (
    <div className="rounded border border-neutral-800 bg-neutral-900/40">
      <div className="flex items-center gap-2 px-3 py-1.5">
        <input
          type="text"
          value={primary.name}
          onChange={(e) => onRename(e.currentTarget.value)}
          className="flex-1 rounded border border-transparent bg-transparent px-1 py-0.5 text-xs font-medium text-neutral-200 hover:border-neutral-700 focus:border-neutral-600 focus:outline-none"
        />
        <span className="font-mono text-[10px] text-neutral-600">
          {primary.secondaries.length} sec
          {primary.secondaries.length === 1 ? "" : "s"}
        </span>
        <button
          type="button"
          onClick={onDelete}
          className="rounded border border-neutral-800 px-1.5 py-0.5 text-[10px] text-neutral-500 hover:border-red-700 hover:text-red-300"
          title="Delete primary"
        >
          ✕
        </button>
      </div>
      <div className="flex flex-col gap-1 px-3 pb-2">
        {primary.secondaries.map((sec) => (
          <div key={sec.id} className="flex items-center gap-2">
            <span className="font-mono text-[10px] text-neutral-600">·</span>
            <input
              type="text"
              value={sec.name}
              onChange={(e) => onRenameSecondary(sec.id, e.currentTarget.value)}
              className="flex-1 rounded border border-transparent bg-transparent px-1 py-0.5 text-xs text-neutral-300 hover:border-neutral-700 focus:border-neutral-600 focus:outline-none"
            />
            <button
              type="button"
              onClick={() => onDeleteSecondary(sec.id)}
              className="rounded border border-neutral-800 px-1.5 py-0.5 text-[10px] text-neutral-600 hover:border-red-700 hover:text-red-300"
              title="Delete secondary"
            >
              ✕
            </button>
          </div>
        ))}
        <button
          type="button"
          onClick={onAddSecondary}
          className="ml-3 self-start rounded border border-dashed border-neutral-800 px-2 py-0.5 text-[10px] text-neutral-500 hover:bg-neutral-800 hover:text-neutral-300"
        >
          + Add secondary
        </button>
      </div>
    </div>
  );
}

// Local helper — the api.ts client owns auth-header injection, but
// this file uses raw fetch for the PUT/GET pair against /v1/config
// because the response shape needs custom 404 / 409 handling. We
// duplicate the JWT lookup here rather than reach into api.ts.
async function authHeader(): Promise<Record<string, string>> {
  // Import lazily to avoid pulling supabase into the initial bundle
  // for unauthenticated visitors.
  const { supabase } = await import("../lib/supabase");
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  return jwt ? { Authorization: `Bearer ${jwt}` } : {};
}
