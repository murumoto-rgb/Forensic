import { useEffect, useState } from "react";
import type {
  AIPromptTemplate,
  Project,
  ProjectExtraVocabulary,
  ProjectTagSelection,
} from "@forensic/shared";
import { api, ApiError } from "../lib/api";
import { useEscapeKey } from "../lib/useEscapeKey";
import { ProjectTagSelectionPicker } from "./ProjectTagSelectionPicker";

/**
 * Project AI configuration (Build #5.81.1 — Path P #6/8).
 *
 * Three editable surfaces, all writing into the project manifest:
 *
 *   - **AI notes** (`aiInstructions`)            — free-text
 *     prompt instructions, prepended to the AI tag prompt.
 *   - **Job vocabulary** (`aiExtraVocabulary`)   — opaque records
 *     (the inner `PrimaryTagEntry` / `SecondaryTagEntry` shapes
 *     are not part of the manifest contract yet; we expose a JSON
 *     editor with parse-on-blur so the user can paste in or hand-
 *     edit a list of primaries).
 *   - **Tag selection** (`tagSelection`)         — three-level
 *     context → primary → secondary scope. The 3-level picker is
 *     wired against the shared tag library in a follow-on; for
 *     now we render a counts-only summary plus a Clear button so
 *     a stale selection can be wiped without going to the admin
 *     pages.
 *
 * Plus a destructive utility:
 *
 *   - **Clear AI tags** — strip every tag whose confidence < 1.0
 *     (the convention iOS uses for "AI-attributed") from every
 *     photo; optionally also clears `aiAnalysis` on each photo.
 *     Runs project-wide; the confirm dialog quotes the affected
 *     photo count first.
 */
interface Props {
  project: Project;
  canEdit: boolean;
  onProjectChanged: (next: Project) => void;
}

const AI_TAGS_THRESHOLD = 1.0;

export function ProjectAIConfig({ project, canEdit, onProjectChanged }: Props) {
  const [notes, setNotes] = useState(project.aiInstructions ?? "");
  const [vocabDraft, setVocabDraft] = useState(() =>
    formatVocab(project.aiExtraVocabulary)
  );
  const [vocabError, setVocabError] = useState<string | null>(null);
  const [confirmClear, setConfirmClear] = useState<{
    affected: number;
    alsoAnalysis: boolean;
  } | null>(null);
  const [pickerOpen, setPickerOpen] = useState(false);
  // Build #6.12.1: team-wide AI prompt templates ("Load template…"
  // dropdown on the AI notes section). Fetched once on mount; they
  // change rarely. If the admin edits one, a page reload picks it up.
  const [templates, setTemplates] = useState<AIPromptTemplate[] | null>(null);
  const [templatesError, setTemplatesError] = useState<string | null>(null);
  const [templatePickerOpen, setTemplatePickerOpen] = useState(false);
  const [confirmTemplate, setConfirmTemplate] =
    useState<AIPromptTemplate | null>(null);

  // Build #6.17.1: Escape closes any open modal/popover. Sites that
  // share a parent (e.g. the template dropdown is nested inside the
  // notes section) handle Escape one-by-one so closing the inner
  // doesn't surprise the user with the outer also closing.
  useEscapeKey(confirmClear !== null, () => setConfirmClear(null));
  useEscapeKey(confirmTemplate !== null, () => setConfirmTemplate(null));
  useEscapeKey(templatePickerOpen, () => setTemplatePickerOpen(false));

  // Reset local drafts if the project changes underneath us (e.g.
  // another tab edits the manifest and the shared hook re-renders).
  useEffect(() => {
    setNotes(project.aiInstructions ?? "");
  }, [project.aiInstructions]);
  useEffect(() => {
    setVocabDraft(formatVocab(project.aiExtraVocabulary));
    setVocabError(null);
  }, [project.aiExtraVocabulary]);

  useEffect(() => {
    let cancelled = false;
    api
      .getAIPromptTemplatesConfig()
      .then((resp) => {
        if (cancelled) return;
        setTemplates(resp?.value.templates ?? []);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setTemplatesError(
          e instanceof ApiError ? e.message : "Couldn't load templates"
        );
      });
    return () => {
      cancelled = true;
    };
  }, []);

  function applyTemplate(t: AIPromptTemplate) {
    const trimmedNew = t.prompt.trim();
    setNotes(trimmedNew);
    // Mirror commitNotes' empty→null normalisation so a template load
    // looks the same on disk as a manual edit.
    onProjectChanged({
      ...project,
      aiInstructions: trimmedNew === "" ? null : trimmedNew,
    });
    setTemplatePickerOpen(false);
    setConfirmTemplate(null);
  }

  function handleTemplatePick(t: AIPromptTemplate) {
    const existing = (project.aiInstructions ?? "").trim();
    if (existing.length > 0) {
      // Confirm before overwriting an in-flight note — loading a
      // template replaces the entire AI notes field, it doesn't
      // append. iOS's loader has the same two-step behavior.
      setConfirmTemplate(t);
    } else {
      applyTemplate(t);
    }
  }

  function commitNotes() {
    const next = notes.trim();
    const cur = project.aiInstructions ?? "";
    if (next === cur.trim()) return;
    onProjectChanged({
      ...project,
      aiInstructions: next === "" ? null : next,
    });
  }

  function commitVocab() {
    const trimmed = vocabDraft.trim();
    if (trimmed === "") {
      onProjectChanged({ ...project, aiExtraVocabulary: null });
      setVocabError(null);
      return;
    }
    try {
      const parsed = JSON.parse(trimmed);
      if (!Array.isArray(parsed)) {
        setVocabError("Top-level value must be a JSON array of primary tag objects.");
        return;
      }
      const sanitized = parsed.filter(
        (v): v is Record<string, unknown> =>
          v != null && typeof v === "object" && !Array.isArray(v)
      );
      const next: ProjectExtraVocabulary = { primaries: sanitized };
      setVocabError(null);
      onProjectChanged({ ...project, aiExtraVocabulary: next });
    } catch (e: unknown) {
      setVocabError(e instanceof Error ? e.message : "Invalid JSON");
    }
  }

  function clearTagSelection() {
    onProjectChanged({ ...project, tagSelection: null });
  }

  function clearAITags(alsoAnalysis: boolean) {
    const nextPhotos = project.photos.map((p) => {
      const tagsKept = p.tags.filter((t) => t.confidence >= AI_TAGS_THRESHOLD);
      const changedTags = tagsKept.length !== p.tags.length;
      const nextAnalysis = alsoAnalysis ? null : p.aiAnalysis;
      const changedAnalysis = alsoAnalysis && p.aiAnalysis !== null;
      if (!changedTags && !changedAnalysis) return p;
      return { ...p, tags: tagsKept, aiAnalysis: nextAnalysis };
    });
    onProjectChanged({ ...project, photos: nextPhotos });
    setConfirmClear(null);
  }

  function previewClearAITags(alsoAnalysis: boolean) {
    const affected = project.photos.filter(
      (p) =>
        p.tags.some((t) => t.confidence < AI_TAGS_THRESHOLD) ||
        (alsoAnalysis && p.aiAnalysis != null)
    ).length;
    setConfirmClear({ affected, alsoAnalysis });
  }

  const selectionSummary = summarizeSelection(project.tagSelection);

  return (
    <div className="flex flex-col gap-4">
      {/* AI notes */}
      <section className="rounded border border-neutral-800 bg-neutral-900/40 p-3">
        <div className="mb-2 flex items-center justify-between">
          <div className="text-xs uppercase tracking-wide text-neutral-500">
            AI notes
          </div>
          {/* Build #6.12.1: load from a team-wide AI prompt template. */}
          {canEdit && templates !== null && templates.length > 0 && (
            <div className="relative">
              <button
                type="button"
                onClick={() => setTemplatePickerOpen((o) => !o)}
                className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800"
                aria-haspopup="menu"
                aria-expanded={templatePickerOpen}
              >
                Load template…
              </button>
              {templatePickerOpen && (
                <>
                  <div
                    className="fixed inset-0 z-40"
                    onClick={() => setTemplatePickerOpen(false)}
                  />
                  <div
                    role="menu"
                    className="absolute right-0 z-50 mt-1 max-h-72 w-72 overflow-y-auto rounded border border-neutral-700 bg-neutral-900 p-1 shadow-2xl"
                  >
                    {templates.map((t) => (
                      <button
                        key={t.id}
                        type="button"
                        role="menuitem"
                        onClick={() => handleTemplatePick(t)}
                        className="block w-full rounded px-2 py-1.5 text-left text-xs text-neutral-200 hover:bg-neutral-800"
                      >
                        <div className="font-medium">{t.name}</div>
                        <div className="line-clamp-2 text-neutral-500">
                          {t.prompt.slice(0, 140)}
                        </div>
                      </button>
                    ))}
                  </div>
                </>
              )}
            </div>
          )}
          {templatesError && (
            <span className="text-xs text-amber-300" title={templatesError}>
              templates unavailable
            </span>
          )}
        </div>
        <p className="mb-2 text-xs text-neutral-400">
          Free-text instructions prepended to the AI tag prompt. Use
          this to give the model project-specific context — building
          age, climate, materials, what to focus on.
        </p>
        <textarea
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          onBlur={commitNotes}
          disabled={!canEdit}
          rows={4}
          placeholder="e.g. Two-story stucco residence built in 1968. Pay special attention to foundation cracking and door alignment."
          className="w-full rounded border border-neutral-700 bg-neutral-950 p-2 text-sm text-neutral-100 placeholder:text-neutral-600 disabled:opacity-50"
        />
      </section>

      {/* Job vocabulary */}
      <section className="rounded border border-neutral-800 bg-neutral-900/40 p-3">
        <div className="mb-2 text-xs uppercase tracking-wide text-neutral-500">
          Job-specific vocabulary
        </div>
        <p className="mb-2 text-xs text-neutral-400">
          JSON array of additional primary-tag entries layered on top
          of the global vocabulary for this project only. The exact
          object shape mirrors iOS's `PrimaryTagEntry` and is round-
          tripped to iOS as-is.
        </p>
        <textarea
          value={vocabDraft}
          onChange={(e) => setVocabDraft(e.target.value)}
          onBlur={commitVocab}
          disabled={!canEdit}
          rows={6}
          spellCheck={false}
          placeholder='[{"name": "foundation crack", "secondaries": ["hairline", "step"]}]'
          className="w-full rounded border border-neutral-700 bg-neutral-950 p-2 font-mono text-xs text-neutral-100 placeholder:text-neutral-600 disabled:opacity-50"
        />
        {vocabError && (
          <div className="mt-1 text-xs text-red-300">{vocabError}</div>
        )}
      </section>

      {/* Tag selection summary + picker */}
      <section className="rounded border border-neutral-800 bg-neutral-900/40 p-3">
        <div className="mb-2 flex items-center justify-between">
          <span className="text-xs uppercase tracking-wide text-neutral-500">
            Tag selection
          </span>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => setPickerOpen(true)}
              disabled={!canEdit}
              className="rounded border border-blue-700 bg-blue-900/40 px-2 py-0.5 text-xs text-blue-100 hover:bg-blue-900/60 disabled:opacity-50"
            >
              {project.tagSelection ? "Edit selection…" : "Set selection…"}
            </button>
            {project.tagSelection && (
              <button
                type="button"
                onClick={clearTagSelection}
                disabled={!canEdit}
                className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800 disabled:opacity-50"
              >
                Clear
              </button>
            )}
          </div>
        </div>
        <p className="text-xs text-neutral-400">
          Three-level context → primary → secondary scope for AI
          tagging. {selectionSummary}
        </p>
      </section>

      {pickerOpen && (
        <ProjectTagSelectionPicker
          project={project}
          canEdit={canEdit}
          onClose={() => setPickerOpen(false)}
          onCommit={(next) =>
            onProjectChanged({ ...project, tagSelection: next })
          }
        />
      )}

      {/* Clear AI tags */}
      <section className="rounded border border-neutral-800 bg-neutral-900/40 p-3">
        <div className="mb-2 text-xs uppercase tracking-wide text-neutral-500">
          Clear AI tags
        </div>
        <p className="mb-2 text-xs text-neutral-400">
          Remove every tag whose confidence is below 1.0 from every
          photo in this project (the convention iOS uses for "AI-
          attributed"). User-added tags are confidence 1.0 and are
          preserved. Optionally also clear `aiAnalysis` so the next
          re-tag starts from a clean slate.
        </p>
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            onClick={() => previewClearAITags(false)}
            disabled={!canEdit}
            className="rounded border border-amber-700 px-2 py-1 text-xs text-amber-200 hover:bg-amber-950/40 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Clear AI tags
          </button>
          <button
            type="button"
            onClick={() => previewClearAITags(true)}
            disabled={!canEdit}
            className="rounded border border-amber-700 px-2 py-1 text-xs text-amber-200 hover:bg-amber-950/40 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Clear AI tags + analysis
          </button>
        </div>
      </section>

      {confirmClear && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-200">
              Clear AI tags
              {confirmClear.alsoAnalysis ? " + analysis" : ""} from{" "}
              <span className="font-semibold">{confirmClear.affected}</span>{" "}
              photo{confirmClear.affected === 1 ? "" : "s"}?
              <div className="mt-2 text-xs text-neutral-400">
                User-added tags (confidence 1.0) are preserved.
                {confirmClear.alsoAnalysis &&
                  " The structured aiAnalysis on each photo will be removed."}
              </div>
            </div>
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmClear(null)}
                className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => clearAITags(confirmClear.alsoAnalysis)}
                className="rounded border border-amber-600 bg-amber-700/40 px-4 py-1.5 text-sm text-amber-100 hover:bg-amber-700/60"
              >
                Clear
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Build #6.12.1: overwrite-existing-notes confirm. */}
      {confirmTemplate && (
        <div
          role="dialog"
          aria-modal="true"
          aria-label="Replace AI notes with template"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-3 rounded-lg border border-neutral-700 bg-neutral-900 p-5 shadow-2xl">
            <h3 className="text-sm font-semibold text-neutral-100">
              Replace AI notes?
            </h3>
            <p className="text-xs text-neutral-300">
              This project already has AI notes. Loading{" "}
              <span className="font-medium">{confirmTemplate.name}</span>{" "}
              will overwrite them.
            </p>
            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setConfirmTemplate(null)}
                className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-200 hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => applyTemplate(confirmTemplate)}
                className="rounded border border-blue-700 bg-blue-900/40 px-3 py-1 text-xs text-blue-100 hover:bg-blue-900/70"
              >
                Replace
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function formatVocab(v: ProjectExtraVocabulary | null): string {
  if (!v || v.primaries.length === 0) return "";
  return JSON.stringify(v.primaries, null, 2);
}

function summarizeSelection(s: ProjectTagSelection | null): string {
  if (!s) return "None set — AI tagging uses the entire vocabulary.";
  const ctxCount = s.contextIDs.length;
  let primCount = 0;
  for (const arr of Object.values(s.primariesByContext)) primCount += arr.length;
  let deselCount = 0;
  for (const arr of Object.values(s.deselectedSecondariesByPrimary))
    deselCount += arr.length;
  return `${ctxCount} context${ctxCount === 1 ? "" : "s"} · ${primCount} primary${primCount === 1 ? "" : "ies"} · ${deselCount} secondary deselection${deselCount === 1 ? "" : "s"}.`;
}
