import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import { signOutLocal, supabase } from "../lib/supabase";
import { api, ApiError } from "../lib/api";

/**
 * Admin editor for the team's app-wide AI rules / schema template
 * — the prose block at the top of every Claude system prompt that
 * describes the JSON schema + tagging rules. Reads / writes
 * `/v1/config/aiRulesTemplate` (Build #5.44.1; backed by the
 * `app_config` table from #5.35.1).
 *
 * Lives at `/admin/ai-rules`. Same revision-token optimistic-
 * concurrency model as the tag library editor (`/admin/tag-library`);
 * 409 → user is prompted to reload + merge.
 *
 * Editor is intentionally a bare textarea — the template's content
 * is engineer-written prose, no syntax highlighting or templating
 * adds real value over plain text right now. iOS shows a similar
 * unformatted editor.
 */
interface Props {
  session: Session;
}

interface LoadState {
  /** Null = template hasn't been pushed yet (404). User can author
   *  one from scratch and PUT with `expectedRevision: null`. */
  text: string | null;
  revision: string | null;
}

export function AdminAIRulesPage({ session }: Props) {
  const [load, setLoad] = useState<LoadState | "loading" | { error: string }>(
    "loading"
  );
  const [draft, setDraft] = useState<string>("");
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);
  const revisionRef = useRef<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoad("loading");
    api
      .getAIRulesTemplateConfig()
      .then((resp) => {
        if (cancelled) return;
        if (!resp) {
          setLoad({ text: null, revision: null });
          setDraft("");
          revisionRef.current = null;
        } else {
          setLoad({ text: resp.value.text, revision: resp.revision });
          setDraft(resp.value.text);
          revisionRef.current = resp.revision;
        }
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        const message =
          e instanceof ApiError
            ? `${e.status} ${e.errorCode}: ${e.message}`
            : "Failed to load AI rules template";
        setLoad({ error: message });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  function onChange(next: string) {
    setDraft(next);
    setDirty(true);
    setSavedAt(null);
    setSaveError(null);
  }

  async function save() {
    setSaving(true);
    setSaveError(null);
    try {
      const expectedRevision = revisionRef.current;
      const { data: sessionData } = await supabase.auth.getSession();
      const jwt = sessionData.session?.access_token;
      const resp = await fetch(
        `${import.meta.env.VITE_API_URL ?? ""}/v1/config/aiRulesTemplate`,
        {
          method: "PUT",
          headers: {
            "content-type": "application/json",
            ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}),
          },
          body: JSON.stringify({
            value: { text: draft },
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
              "The AI rules template was modified elsewhere. Reload to pick up the latest version."
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
      setLoad({ text: draft, revision: okBody.revision });
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

  function discard() {
    if (load !== "loading" && "text" in load) {
      setDraft(load.text ?? "");
    }
    setDirty(false);
    setSaveError(null);
  }

  /**
   * Replace the editor draft with iOS's bundled default rules
   * template (Build #5.48.1). Same shape as the tag library
   * editor's "Restore default" — fetched live from
   * `/v1/config/aiRulesTemplateDefault`, doesn't persist until
   * the user clicks Save.
   */
  async function restoreDefault() {
    if (
      !window.confirm(
        "Replace your current draft with iOS's bundled default AI rules template?\n\nYou'll still need to click Save to persist the restore."
      )
    ) {
      return;
    }
    setSaveError(null);
    try {
      const resp = await api.getAIRulesTemplateDefaultConfig();
      if (!resp) {
        setSaveError(
          "No bundled default on the server yet. Open the iOS app once (any signed-in session triggers a push) and try again."
        );
        return;
      }
      setDraft(resp.value.text);
      setDirty(true);
      setSavedAt(null);
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
          <h1 className="text-2xl font-semibold">AI rules template</h1>
          <p className="text-xs text-neutral-500">
            Schema + rules block that prepends every Claude system
            prompt. iOS picks up the new template at launch / sign-in
            / "Sync now".
          </p>
        </div>
        <div className="flex flex-col items-end gap-2 text-right">
          <span className="text-xs text-neutral-500">{session.user.email}</span>
          <div className="flex gap-2">
            <Link
              to="/admin/tag-library"
              className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
            >
              Tag library
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
        <div className="text-sm text-neutral-500">Loading template…</div>
      )}
      {load !== "loading" && "error" in load && (
        <div className="rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
          {load.error}
        </div>
      )}

      {load !== "loading" && !("error" in load) && (
        <>
          <div className="sticky top-0 z-10 mb-3 flex items-center justify-between gap-3 rounded border border-neutral-800 bg-neutral-950/95 p-3 shadow-sm backdrop-blur">
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
              <span className="font-mono text-[10px] text-neutral-600">
                {draft.length} chars
              </span>
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
                onClick={discard}
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

          {load.text == null && !dirty && (
            <div className="mb-3 rounded border border-amber-800 bg-amber-950/40 p-3 text-xs text-amber-200">
              No template pushed to the server yet. iOS's bundled
              default will keep applying until you save something
              here. Paste or type the template body below and click
              Save to make it team-wide.
            </div>
          )}

          <textarea
            value={draft}
            onChange={(e) => onChange(e.currentTarget.value)}
            spellCheck={false}
            className="h-[60vh] w-full rounded border border-neutral-800 bg-neutral-950 p-4 font-mono text-xs text-neutral-200 focus:border-neutral-600 focus:outline-none"
            placeholder="Paste or type the AI rules / schema template here…"
          />
        </>
      )}
    </div>
  );
}
