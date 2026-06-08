import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import type { AIPromptTemplate, AIPromptTemplateLibrary } from "@forensic/shared";
import { signOutLocal, supabase } from "../lib/supabase";
import { api, ApiError } from "../lib/api";

/**
 * Admin editor for the team's named AI prompt templates (Build
 * #5.104.1).
 *
 * Backed by `app_config.aiPromptTemplates`. Web users can save /
 * rename / delete / edit prompt bodies; the project AI-config tab
 * (a follow-on PR) will surface a picker that fills
 * `Project.aiInstructions` from a selected template.
 *
 * Same optimistic-concurrency model as the other `app_config`
 * editors.
 */
interface Props {
  session: Session;
}

const EMPTY: AIPromptTemplateLibrary = { templates: [] };

interface LoadedState {
  library: AIPromptTemplateLibrary;
  revision: string | null;
}

export function AdminAIPromptTemplatesPage({ session }: Props) {
  const [load, setLoad] = useState<LoadedState | "loading" | { error: string }>(
    "loading"
  );
  const [draft, setDraft] = useState<AIPromptTemplateLibrary>(EMPTY);
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);
  const revisionRef = useRef<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoad("loading");
    api
      .getAIPromptTemplatesConfig()
      .then((resp) => {
        if (cancelled) return;
        if (!resp) {
          setLoad({ library: EMPTY, revision: null });
          setDraft(EMPTY);
          revisionRef.current = null;
        } else {
          setLoad({ library: resp.value, revision: resp.revision });
          setDraft(resp.value);
          revisionRef.current = resp.revision;
        }
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setLoad({
          error:
            e instanceof ApiError
              ? `${e.status} ${e.errorCode}: ${e.message}`
              : "Failed to load templates.",
        });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  function setTemplates(next: AIPromptTemplate[]) {
    setDraft({ templates: next });
    setDirty(true);
    setSavedAt(null);
    setSaveError(null);
  }

  function addTemplate() {
    setTemplates([
      ...draft.templates,
      {
        id: crypto.randomUUID(),
        name: `Template ${draft.templates.length + 1}`,
        prompt: "",
      },
    ]);
  }

  function updateTemplate(id: string, patch: Partial<AIPromptTemplate>) {
    setTemplates(
      draft.templates.map((t) => (t.id === id ? { ...t, ...patch } : t))
    );
  }

  function deleteTemplate(id: string) {
    if (!window.confirm("Delete this prompt template?")) return;
    setTemplates(draft.templates.filter((t) => t.id !== id));
  }

  function discard() {
    if (typeof load === "object" && "library" in load) {
      setDraft(load.library);
    } else {
      setDraft(EMPTY);
    }
    setDirty(false);
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
        `${import.meta.env.VITE_API_URL ?? ""}/v1/config/aiPromptTemplates`,
        {
          method: "PUT",
          headers: {
            "content-type": "application/json",
            ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}),
          },
          body: JSON.stringify({ value: draft, expectedRevision }),
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
              "Templates were modified elsewhere — reload to merge."
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
      setLoad({ library: draft, revision: okBody.revision });
      setDirty(false);
      setSavedAt(Date.now());
    } catch (e: unknown) {
      setSaveError(
        e instanceof ApiError
          ? e.message
          : e instanceof Error
            ? e.message
            : "Save failed."
      );
    } finally {
      setSaving(false);
    }
  }

  const loaded = typeof load === "object" && "library" in load ? load : null;
  const loadError = typeof load === "object" && "error" in load ? load.error : null;

  return (
    <div className="mx-auto max-w-3xl px-6 py-10">
      <header className="mb-6 flex items-center justify-between">
        <div>
          <Link
            to="/settings"
            className="text-xs text-neutral-500 hover:text-neutral-300"
          >
            ← Settings
          </Link>
          <h1 className="text-2xl font-semibold">AI Prompt Templates</h1>
          <p className="text-xs text-neutral-500">{session.user.email}</p>
        </div>
        <button
          type="button"
          onClick={() => signOutLocal()}
          className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
        >
          Sign out
        </button>
      </header>

      <p className="mb-4 text-sm text-neutral-400">
        Saved prompt bodies the AI uses when tagging photos. Each
        project can pick one to override its default
        `aiInstructions`. Team-wide. iOS picker integration ships in
        a follow-on PR.
      </p>

      {load === "loading" && <div className="text-sm text-neutral-500">Loading…</div>}
      {loadError && (
        <div className="rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
          {loadError}
        </div>
      )}

      {loaded && (
        <div className="flex flex-col gap-3">
          {draft.templates.length === 0 && (
            <div className="rounded border border-dashed border-neutral-800 p-6 text-center text-sm text-neutral-500">
              No templates yet. Add one below.
            </div>
          )}
          {draft.templates.map((t) => (
            <TemplateRow
              key={t.id}
              template={t}
              onChange={(patch) => updateTemplate(t.id, patch)}
              onDelete={() => deleteTemplate(t.id)}
            />
          ))}
          <button
            type="button"
            onClick={addTemplate}
            className="self-start rounded border border-blue-700 bg-blue-900/40 px-3 py-1.5 text-sm text-blue-100 hover:bg-blue-900/60"
          >
            + Add template
          </button>

          <div className="mt-4 flex items-center gap-3">
            <button
              type="button"
              onClick={save}
              disabled={!dirty || saving}
              className="rounded border border-blue-700 bg-blue-900/40 px-3 py-1.5 text-sm text-blue-100 hover:bg-blue-900/60 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {saving ? "Saving…" : "Save"}
            </button>
            <button
              type="button"
              onClick={discard}
              disabled={!dirty || saving}
              className="rounded border border-neutral-700 px-3 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Discard changes
            </button>
            {savedAt && !dirty && (
              <span className="text-xs text-green-400">
                Saved · {new Date(savedAt).toLocaleTimeString()}
              </span>
            )}
            {saveError && <span className="text-xs text-red-400">{saveError}</span>}
          </div>
        </div>
      )}
    </div>
  );
}

function TemplateRow({
  template,
  onChange,
  onDelete,
}: {
  template: AIPromptTemplate;
  onChange: (patch: Partial<AIPromptTemplate>) => void;
  onDelete: () => void;
}) {
  return (
    <div className="rounded border border-neutral-800 bg-neutral-900/40 p-3">
      <div className="mb-2 flex items-center justify-between gap-2">
        <input
          type="text"
          value={template.name}
          onChange={(e) => onChange({ name: e.target.value })}
          placeholder="Template name"
          className="flex-1 rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100 placeholder:text-neutral-600 focus:border-blue-600 focus:outline-none"
        />
        <button
          type="button"
          onClick={onDelete}
          className="rounded border border-red-800 px-2 py-1 text-xs text-red-300 hover:bg-red-950/40"
        >
          Delete
        </button>
      </div>
      <textarea
        value={template.prompt}
        onChange={(e) => onChange({ prompt: e.target.value })}
        rows={6}
        placeholder="Prompt body — same shape Project.aiInstructions takes."
        className="w-full rounded border border-neutral-700 bg-neutral-950 p-2 font-mono text-xs text-neutral-100 placeholder:text-neutral-600 focus:border-blue-600 focus:outline-none"
      />
    </div>
  );
}
