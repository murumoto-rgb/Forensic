import { useCallback, useRef, useState } from "react";
import type {
  AITagPhotoModel,
  Photo,
  Project,
  ValidationVocabulary,
} from "@forensic/shared";
import {
  aiAnalysisToSuggestions,
  compilePrompt,
  PromptCompileError,
  resolveValidationVocabulary,
} from "@forensic/shared";
import { api, ApiError } from "./api";
import { tagPhotoWithValidation } from "./tagPhotoFlow";

/**
 * Per-photo outcome of a batch tagging run.
 */
export type BatchPhotoOutcome =
  | { kind: "queued"; photoId: string }
  | { kind: "running"; photoId: string }
  | { kind: "done"; photoId: string; parseFailed: boolean }
  | { kind: "failed"; photoId: string; message: string }
  | { kind: "skipped"; photoId: string };

export interface BatchOptions {
  model: AITagPhotoModel;
  /** Skip photos that already have at least one tag (`tags.length > 0`). */
  skipAlreadyTagged: boolean;
  /** Max concurrent in-flight requests. Anthropic rate-limit-aware. */
  concurrency: number;
}

export interface BatchRunState {
  kind:
    | "idle"
    | "preparing"
    | "running"
    | "saving"
    | "done"
    | "cancelled"
    | "error";
  /** Total photos to process this run. */
  total: number;
  /** Per-photo outcomes, keyed by photoId. */
  outcomes: Record<string, BatchPhotoOutcome>;
  /** Top-level error message when `kind === "error"`. */
  errorMessage?: string;
  /** Counts surfaced in the progress UI. */
  doneCount: number;
  skippedCount: number;
  failedCount: number;
}

const INITIAL: BatchRunState = {
  kind: "idle",
  total: 0,
  outcomes: {},
  doneCount: 0,
  skippedCount: 0,
  failedCount: 0,
};

/**
 * Drive a "Re-tag all photos with AI" run for a single project on web.
 * Mirrors iOS's `ProjectStore.batchAITag(...)` task-group runner:
 * fetches the team config once at the top, walks the project's
 * photos with bounded concurrency, drops each result through the
 * `aiAnalysisToSuggestions` pipeline (Build #5.41.1) into
 * `Photo.pendingSuggestions`, and PUTs the manifest at a 25-photo
 * checkpoint interval so an interrupted run never loses more than
 * that many photos' worth of work.
 *
 * Cancellation: `cancel()` flips an internal flag the scheduler
 * polls between launches. In-flight requests aren't aborted (no
 * AbortController on the proxy endpoint today); the run finishes
 * the in-flight set then saves whatever it has and transitions to
 * `cancelled`.
 *
 * The hook receives the LATEST project + revision via refs so a
 * pin drag (or any other concurrent mutation) doesn't race the
 * batch's PUT cadence. Caller passes a `setProject` to apply each
 * checkpoint's updated photo array back to UI state.
 */
export function useBatchRetag(args: {
  projectId: string;
  /** Always-current pointer to the project state. The hook reads
   *  `.current` on every checkpoint so a pin drag mid-batch doesn't
   *  get clobbered. */
  projectRef: React.MutableRefObject<Project | null>;
  revisionRef: React.MutableRefObject<string | null>;
  /** Push a freshly-mutated project into the page's state so the UI
   *  re-renders with the new pending-suggestion counts. */
  setProject: (next: Project) => void;
  /** Update the page-level revision after each successful PUT. */
  setRevision: (next: string) => void;
  /** Shared manifest coordinator used by the workspace shell. */
  save?: (next: Project) => void;
  saveAndWait?: (next: Project) => Promise<void>;
}) {
  const { projectId, projectRef, revisionRef, setProject, setRevision, save, saveAndWait } = args;
  const [state, setState] = useState<BatchRunState>(INITIAL);
  const cancelledRef = useRef(false);

  const reset = useCallback(() => {
    cancelledRef.current = false;
    setState(INITIAL);
  }, []);

  const cancel = useCallback(() => {
    cancelledRef.current = true;
  }, []);

  const start = useCallback(
    /**
     * Run a batch.
     *
     * When `photoIds` is provided, the batch is restricted to those
     * photos only — used by the Photos-tab selection action bar.
     * Order of iteration follows the project's existing `photos[]`
     * order (not the order of `photoIds`), so check-pointing still
     * stamps photos in stable manifest order.
     */
    async (opts: BatchOptions, photoIds?: readonly string[]) => {
      const project = projectRef.current;
      if (!project) {
        setState({
          ...INITIAL,
          kind: "error",
          errorMessage: "Project not loaded yet.",
        });
        return;
      }
      cancelledRef.current = false;

      // Pre-flight: fetch app_config + compile the system prompt
      // once. Doing this BEFORE looping the photos means we fail
      // fast on "no tag selection" / "no library on server" without
      // burning any Anthropic budget.
      setState({ ...INITIAL, kind: "preparing" });
      let systemPrompt: string;
      let vocabulary: ValidationVocabulary | null = null;
      try {
        const [tagLibResp, rulesResp] = await Promise.all([
          api.getTagLibraryConfig(),
          api.getAIRulesTemplateConfig(),
        ]);
        if (!tagLibResp) {
          setState({
            ...INITIAL,
            kind: "error",
            errorMessage:
              "No tag library on the server yet. Push one from iOS first.",
          });
          return;
        }
        const compiled = compilePrompt({
          rulesTemplate: rulesResp?.value.text ?? "",
          tagLibrary: tagLibResp.value,
          project,
        });
        systemPrompt = compiled.joinedSystemPrompt;
        // Same vocabulary used by every photo's repair retry —
        // resolve once at prep, reuse for the whole batch.
        if (project.tagSelection) {
          vocabulary = resolveValidationVocabulary({
            library: tagLibResp.value,
            selection: project.tagSelection,
            extras: project.aiExtraVocabulary,
          });
        }
      } catch (e: unknown) {
        if (e instanceof PromptCompileError) {
          setState({
            ...INITIAL,
            kind: "error",
            errorMessage:
              "This project has no AI tag selection yet. Pick contexts on iOS first.",
          });
        } else if (e instanceof ApiError) {
          setState({
            ...INITIAL,
            kind: "error",
            errorMessage: `${e.status} ${e.errorCode}: ${e.message}`,
          });
        } else {
          setState({
            ...INITIAL,
            kind: "error",
            errorMessage:
              e instanceof Error ? e.message : "Preparing batch failed.",
          });
        }
        return;
      }

      // Build the candidate list. Skip-already-tagged matches iOS's
      // `skipAlreadyTagged` semantics: photos with at least one tag
      // are passed over.
      //
      // `photoIds`, when provided, restricts the scan to that subset.
      // Photos not in the set are completely absent from the outcomes
      // map (rather than marked "skipped" — the user didn't ask the
      // batch to consider them, so reporting them as skipped would
      // bloat the progress UI for big projects).
      const restrictTo: Set<string> | null = photoIds
        ? new Set(photoIds)
        : null;
      const candidates: Photo[] = [];
      const initialOutcomes: Record<string, BatchPhotoOutcome> = {};
      let initialSkipped = 0;
      for (const photo of project.photos) {
        if (restrictTo && !restrictTo.has(photo.id)) continue;
        if (opts.skipAlreadyTagged && photo.tags.length > 0) {
          initialOutcomes[photo.id] = { kind: "skipped", photoId: photo.id };
          initialSkipped += 1;
          continue;
        }
        candidates.push(photo);
        initialOutcomes[photo.id] = { kind: "queued", photoId: photo.id };
      }

      if (candidates.length === 0) {
        setState({
          ...INITIAL,
          kind: "done",
          total: 0,
          outcomes: initialOutcomes,
          skippedCount: initialSkipped,
        });
        return;
      }

      setState({
        kind: "running",
        total: candidates.length,
        outcomes: initialOutcomes,
        doneCount: 0,
        skippedCount: initialSkipped,
        failedCount: 0,
      });

      // Working photo map keyed by id — updated as each task lands
      // so a checkpoint save can rebuild the project's photos array
      // by walking the original order against this map.
      const workingPhotos = new Map<string, Photo>();
      for (const p of project.photos) workingPhotos.set(p.id, p);

      let processedSinceCheckpoint = 0;
      const CHECKPOINT_INTERVAL = 25;

      async function checkpointSave() {
        const live = projectRef.current;
        const rev = revisionRef.current;
        if (!live || !rev) return;
        const nextPhotos = live.photos.map((p) => {
          const aiPhoto = workingPhotos.get(p.id);
          return aiPhoto
            ? { ...p, aiAnalysis: aiPhoto.aiAnalysis, pendingSuggestions: aiPhoto.pendingSuggestions }
            : p;
        });
        const next: Project = { ...live, photos: nextPhotos };
        try {
          setState((s) => ({ ...s, kind: "saving" }));
          if (saveAndWait) {
            await saveAndWait(next);
          } else if (save) {
            // The workspace save coordinator owns revision/base handling and
            // rebases this checkpoint with unrelated edits from other tabs.
            save(next);
          } else {
            const resp = await api.putProject(projectId, next, rev);
            setRevision(resp.revision);
            setProject(next);
          }
          setState((s) => ({ ...s, kind: "running" }));
        } catch (e: unknown) {
          // Server rejected our write. Bail with the message; the
          // user can re-run once the conflict is sorted.
          const message =
            e instanceof ApiError
              ? `${e.status} ${e.errorCode}: ${e.message}`
              : e instanceof Error
                ? e.message
                : "Checkpoint save failed.";
          setState((s) => ({
            ...s,
            kind: "error",
            errorMessage: message,
          }));
          // Stop the batch.
          cancelledRef.current = true;
          throw e;
        }
      }

      async function tagOne(photo: Photo) {
        if (cancelledRef.current) return;
        setState((s) => ({
          ...s,
          outcomes: {
            ...s.outcomes,
            [photo.id]: { kind: "running", photoId: photo.id },
          },
        }));
        try {
          const { analysis } = await tagPhotoWithValidation({
            projectId,
            photoId: photo.id,
            imageFilename: photo.imageFilename,
            model: opts.model,
            systemPrompt,
            vocabulary,
          });
          const newSuggestions = aiAnalysisToSuggestions(analysis);
          // Merge with whatever pending suggestions the photo already
          // had — same discipline as the single-photo Re-tag.
          const latest = projectRef.current?.photos.find((p) => p.id === photo.id) ?? photo;
          const next: Photo = {
            ...latest,
            aiAnalysis: analysis,
            pendingSuggestions: dedupSuggestions(latest.pendingSuggestions, newSuggestions),
          };
          workingPhotos.set(photo.id, next);
          processedSinceCheckpoint += 1;
          setState((s) => ({
            ...s,
            outcomes: {
              ...s.outcomes,
              [photo.id]: {
                kind: "done",
                photoId: photo.id,
                parseFailed: analysis.parseFailed,
              },
            },
            doneCount: s.doneCount + 1,
          }));
        } catch (e: unknown) {
          const message =
            e instanceof ApiError
              ? `${e.status} ${e.errorCode}: ${e.message}`
              : e instanceof Error
                ? e.message
                : "Tag failed.";
          setState((s) => ({
            ...s,
            outcomes: {
              ...s.outcomes,
              [photo.id]: {
                kind: "failed",
                photoId: photo.id,
                message,
              },
            },
            failedCount: s.failedCount + 1,
          }));
        }
      }

      // Bounded-concurrency scheduler. Pull items from a shared
      // iterator across N worker promises so each worker grabs the
      // next available item as soon as it finishes the previous.
      const iter = candidates[Symbol.iterator]();
      async function worker() {
        while (true) {
          if (cancelledRef.current) return;
          const next = iter.next();
          if (next.done) return;
          await tagOne(next.value);
          if (
            processedSinceCheckpoint >= CHECKPOINT_INTERVAL &&
            !cancelledRef.current
          ) {
            processedSinceCheckpoint = 0;
            try {
              await checkpointSave();
            } catch {
              return; // checkpointSave already set the state
            }
          }
        }
      }

      const workers: Promise<void>[] = [];
      const n = Math.max(1, Math.min(10, opts.concurrency));
      for (let i = 0; i < n; i++) workers.push(worker());
      await Promise.all(workers);

      // Final save — flush any tail since the last checkpoint.
      if (processedSinceCheckpoint > 0) {
        try {
          await checkpointSave();
        } catch {
          return;
        }
      }

      setState((s) => ({
        ...s,
        kind: cancelledRef.current ? "cancelled" : "done",
      }));
    },
    [projectId, projectRef, revisionRef, setProject, setRevision, save, saveAndWait]
  );

  return { state, start, cancel, reset };
}

function dedupSuggestions<
  T extends { label: string; parentTag: string | null },
>(existing: T[], incoming: T[]): T[] {
  const seen = new Set<string>();
  const out: T[] = [];
  function key(s: T): string {
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
