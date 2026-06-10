// Split out of PhotoPreviewPanel.tsx (Build #6.22.1) — the panel had
// grown to 1,614 lines holding four independent sub-features. Each
// file owns one feature plus its private helpers; the panel shell
// imports the exported components. No behavior change.
import { useState } from "react";
import type { AITagPhotoModel, Photo, Project, TagSuggestion } from "@forensic/shared";
import {
  aiAnalysisToSuggestions,
  compilePrompt,
  PromptCompileError,
  resolveValidationVocabulary,
} from "@forensic/shared";
import { api, ApiError } from "../lib/api";
import { tagPhotoWithValidation } from "../lib/tagPhotoFlow";

/**
 * Merge new suggestions with the photo's existing pending list,
 * dropping duplicates (label + parentTag pair). Same dedup
 * discipline iOS's `setPendingSuggestions` applies — without it, a
 * second Re-tag run would double every chip.
 */
function mergeSuggestions(
  existing: TagSuggestion[],
  incoming: TagSuggestion[]
): TagSuggestion[] {
  const seen = new Set<string>();
  const out: TagSuggestion[] = [];
  function key(s: TagSuggestion): string {
    return `${(s.parentTag ?? "").toLowerCase()}::${s.label.toLowerCase()}`;
  }
  for (const s of existing) {
    const k = key(s);
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(s);
  }
  for (const s of incoming) {
    const k = key(s);
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(s);
  }
  return out;
}


/**
 * "Re-tag with AI" button + status banner. Fetches the team's
 * `tagLibrary` + `aiRulesTemplate` from the server, compiles the
 * project-scoped system prompt the same way iOS does (via the
 * shared `compilePrompt`), forwards the photo through the
 * `/v1/ai/tag-photo` proxy, parses the rawText into an
 * `AIPhotoAnalysis`, and hands it back to the parent via
 * `onPhotoUpdated`. The parent persists via the manifest PUT.
 *
 * Scoped as a sibling component (rather than inlined in the panel)
 * so the panel's render path stays small and the local state
 * machine here doesn't bleed into the rest of the file.
 */
export function ReTagWithAIControl({
  projectId,
  project,
  photo,
  onPhotoUpdated,
}: {
  projectId: string;
  project: Project;
  photo: Photo;
  onPhotoUpdated: (photo: Photo) => void;
}) {
  type Status =
    | { kind: "idle" }
    | { kind: "running" }
    | { kind: "error"; message: string }
    | { kind: "done"; parseFailed: boolean; didRepair: boolean; validationErrorCount: number };
  const [status, setStatus] = useState<Status>({ kind: "idle" });
  const [model, setModel] = useState<AITagPhotoModel>("claude-sonnet-4-6");

  async function runReTag() {
    setStatus({ kind: "running" });
    try {
      // Fetch the two config keys we need to assemble the prompt.
      // Parallel because they're independent.
      const [tagLibResp, rulesResp] = await Promise.all([
        api.getTagLibraryConfig(),
        api.getAIRulesTemplateConfig(),
      ]);
      if (!tagLibResp) {
        setStatus({
          kind: "error",
          message:
            "No tag library on the server yet. Push one from iOS first (Settings → Tag Library → make any edit).",
        });
        return;
      }
      const rulesTemplate = rulesResp?.value.text ?? "";

      const compiled = compilePrompt({
        rulesTemplate,
        tagLibrary: tagLibResp.value,
        project,
      });

      // Resolve validation vocabulary in parallel with the prompt —
      // both use the same library + selection. The vocabulary lets
      // the flow do its one-shot repair retry on validator rejections
      // (Build #5.43.1).
      const vocabulary = project.tagSelection
        ? resolveValidationVocabulary({
            library: tagLibResp.value,
            selection: project.tagSelection,
            extras: project.aiExtraVocabulary,
          })
        : null;

      const { analysis, didRepair } = await tagPhotoWithValidation({
        projectId,
        photoId: photo.id,
        imageFilename: photo.imageFilename,
        model,
        systemPrompt: compiled.joinedSystemPrompt,
        vocabulary,
      });

      // Build the suggest/accept/reject pipeline payload the same way
      // iOS does (Build #5.41.1). Merge with the photo's existing
      // pendingSuggestions so a previous batch's review state isn't
      // wiped — same merge iOS's PhotoTagEditorSheet.runClaude uses.
      const newSuggestions = aiAnalysisToSuggestions(analysis);
      const merged = mergeSuggestions(photo.pendingSuggestions, newSuggestions);
      onPhotoUpdated({
        ...photo,
        aiAnalysis: analysis,
        pendingSuggestions: merged,
      });
      setStatus({
        kind: "done",
        parseFailed: analysis.parseFailed,
        didRepair,
        validationErrorCount: analysis.validationErrors.length,
      });
    } catch (e: unknown) {
      if (e instanceof PromptCompileError) {
        // Build #6.12.1: web has its own picker — point users to the
        // AI tab here instead of telling them to switch to iOS.
        setStatus({
          kind: "error",
          message:
            "This project has no AI tag selection yet. Open the AI tab → Tag selection to pick contexts.",
        });
      } else if (e instanceof ApiError) {
        setStatus({
          kind: "error",
          message: `${e.status} ${e.errorCode}: ${e.message}`,
        });
      } else {
        setStatus({
          kind: "error",
          message:
            e instanceof Error ? e.message : "Re-tag request failed.",
        });
      }
    }
  }

  return (
    <div className="mt-2 flex flex-col gap-2 border-t border-neutral-800 pt-2">
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={runReTag}
          disabled={status.kind === "running"}
          className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1 text-xs font-medium text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {status.kind === "running" ? "Tagging…" : "Re-tag with AI"}
        </button>
        <select
          aria-label="AI model"
          value={model}
          onChange={(e) => setModel(e.target.value as AITagPhotoModel)}
          disabled={status.kind === "running"}
          className="rounded border border-neutral-700 bg-neutral-800 px-2 py-1 text-xs text-neutral-200 disabled:opacity-50"
        >
          <option value="claude-sonnet-4-6">Sonnet 4.6</option>
          <option value="claude-haiku-4-5">Haiku 4.5</option>
        </select>
      </div>
      {status.kind === "error" && (
        <div className="rounded border border-red-800 bg-red-950/40 px-2 py-1 text-xs text-red-200">
          {status.message}
        </div>
      )}
      {status.kind === "done" && status.parseFailed && (
        <div className="rounded border border-amber-700 bg-amber-950/40 px-2 py-1 text-xs text-amber-200">
          Model output was unparseable — saved on the photo for review.
        </div>
      )}
      {status.kind === "done" && !status.parseFailed && status.didRepair && status.validationErrorCount === 0 && (
        <div className="rounded border border-emerald-800 bg-emerald-950/40 px-2 py-1 text-xs text-emerald-200">
          Tagged after one-shot repair retry — model fixed its
          vocabulary slip on the second pass.
        </div>
      )}
      {status.kind === "done" && !status.parseFailed && status.didRepair && status.validationErrorCount > 0 && (
        <div className="rounded border border-amber-700 bg-amber-950/40 px-2 py-1 text-xs text-amber-200">
          Tagged with {status.validationErrorCount} remaining
          validation issue{status.validationErrorCount === 1 ? "" : "s"} after
          one-shot repair retry — review the validator notes in the AI analysis viewer.
        </div>
      )}
      {status.kind === "done" && !status.parseFailed && !status.didRepair && status.validationErrorCount > 0 && (
        <div className="rounded border border-amber-700 bg-amber-950/40 px-2 py-1 text-xs text-amber-200">
          Tagged with {status.validationErrorCount} validation issue
          {status.validationErrorCount === 1 ? "" : "s"} — review the validator notes in the AI analysis viewer.
        </div>
      )}
      {status.kind === "done" && !status.parseFailed && !status.didRepair && status.validationErrorCount === 0 && (
        <div className="rounded border border-emerald-800 bg-emerald-950/40 px-2 py-1 text-xs text-emerald-200">
          Tagged. Save status indicator confirms persistence.
        </div>
      )}
    </div>
  );
}

