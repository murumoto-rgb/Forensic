import { useEffect, useRef, useState } from "react";
import { useParams, Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import type { Project, FloorPlan } from "@forensic/shared";
import { signOutLocal } from "../lib/supabase";
import { api, ApiError } from "../lib/api";
import { FloorPlanCanvas } from "../components/FloorPlanCanvas";
import { PhotoLightbox } from "../components/PhotoLightbox";

/**
 * Project floor plan viewer page. Route: `/projects/:id/plan`.
 *
 * Loads the project manifest, lets the user pick which floor plan
 * to view if there are multiple, and renders the canvas with all
 * pins + distress marks for the active plan.
 *
 * Pin drag → reposition: when the user drags a pin to a new spot,
 * we optimistically update the React state so the new position
 * renders immediately, then PUT the mutated manifest with the
 * current revision. The server returns the new revision; we echo
 * it on the next PUT. On 409 (someone else wrote in between), we
 * surface a conflict banner asking the user to reload. Only one
 * PUT in flight at a time; rapid successive drags coalesce — the
 * most-recent local state is saved when the current PUT finishes.
 */
interface Props {
  session: Session;
}

type SaveStatus =
  | { kind: "idle" }
  | { kind: "saving" }
  | { kind: "saved" }
  | { kind: "error"; message: string };

export function ProjectPlanPage({ session }: Props) {
  const { id } = useParams<{ id: string }>();
  const [project, setProject] = useState<Project | null>(null);
  const [revision, setRevision] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [activePlanId, setActivePlanId] = useState<string | null>(null);
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);
  const [saveStatus, setSaveStatus] = useState<SaveStatus>({ kind: "idle" });

  // Pins are NOT draggable by default — the user must explicitly
  // "Unlock pins" first. This prevents accidental repositioning
  // while panning / browsing. Even when unlocked, a completed drag
  // shows a confirm dialog before the move is committed + saved.
  const [pinsUnlocked, setPinsUnlocked] = useState(false);
  const [pendingMove, setPendingMove] = useState<{
    photoIndex: number;
    photoLabel: number;
    oldX: number;
    oldY: number;
    project: Project;
  } | null>(null);

  // Save-queue refs. We never have more than one PUT in flight; if
  // a second drag arrives while a save is running, we stash the
  // newest project state in `pendingRef` and the running save
  // picks it up after the current PUT returns.
  const savingRef = useRef<boolean>(false);
  const pendingRef = useRef<Project | null>(null);
  // Mirror of the latest revision so the save loop reads the
  // up-to-date value without depending on React's render cycle.
  const revisionRef = useRef<string | null>(null);
  useEffect(() => {
    revisionRef.current = revision;
  }, [revision]);

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    setProject(null);
    setRevision(null);
    setError(null);
    api
      .getProject(id)
      .then((res) => {
        if (cancelled) return;
        setProject(res.project);
        setRevision(res.revision);
        revisionRef.current = res.revision;
        const candidate =
          res.project.activeFloorPlanID ?? res.project.floorPlans[0]?.id ?? null;
        setActivePlanId(candidate);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        if (e instanceof ApiError) setError(`${e.errorCode}: ${e.message}`);
        else setError("Failed to load project");
      });
    return () => {
      cancelled = true;
    };
  }, [id]);

  // PUT with one automatic retry on a network-level failure (no
  // HTTP response). Render's free tier spins the server down after
  // ~15 min idle; the first request after that hits a cold-start
  // window where the connection can drop. A single retry after a
  // short backoff converts most of those transient blips into a
  // successful save without the user noticing. HTTP errors (4xx/5xx,
  // including 409) are NOT retried — they're deterministic and the
  // caller handles them.
  async function putWithRetry(
    projectId: string,
    project: Project,
    expectedRevision: string
  ) {
    try {
      return await api.putProject(projectId, project, expectedRevision);
    } catch (e: unknown) {
      if (e instanceof ApiError) throw e; // deterministic — don't retry
      // Network-level failure: wait for a possible cold-start, retry once.
      await new Promise((r) => setTimeout(r, 2000));
      return await api.putProject(projectId, project, expectedRevision);
    }
  }

  // Background save loop. Caller pre-populates `pendingRef` with
  // the latest project state, then calls this. If already running,
  // returns immediately — the running loop will see the new
  // pendingRef after its current PUT completes.
  async function runSaveLoop() {
    if (savingRef.current) return;
    if (!id) return;
    savingRef.current = true;
    setSaveStatus({ kind: "saving" });

    while (pendingRef.current && revisionRef.current) {
      const toSave = pendingRef.current;
      pendingRef.current = null;
      try {
        const resp = await putWithRetry(id, toSave, revisionRef.current);
        revisionRef.current = resp.revision;
        setRevision(resp.revision);
      } catch (e: unknown) {
        if (e instanceof ApiError && e.status === 409) {
          setSaveStatus({
            kind: "error",
            message: "Project was modified elsewhere — reload to sync.",
          });
        } else if (e instanceof ApiError) {
          setSaveStatus({
            kind: "error",
            message: `${e.status} ${e.errorCode}: ${e.message}`,
          });
        } else {
          // Network-level failure (no HTTP response) — e.g. a Render
          // free-tier cold-start window or a dropped connection.
          // Safari reports this as "Load failed", Chrome as "Failed
          // to fetch". putWithRetry already retried; surface a
          // human message and re-stash so the user can retry by
          // dragging again (or it'll flush on the next drag).
          pendingRef.current = toSave;
          setSaveStatus({
            kind: "error",
            message:
              "Couldn't reach the server (network or server waking up). " +
              "Your change isn't saved yet — drag again to retry.",
          });
        }
        savingRef.current = false;
        return; // bail; user retries via another drag or reload
      }
    }

    savingRef.current = false;
    setSaveStatus({ kind: "saved" });
    // Auto-clear the "Saved" pill after a couple of seconds.
    setTimeout(() => {
      // Don't clobber a status that changed in the meantime
      // (e.g. another save started).
      setSaveStatus((s) => (s.kind === "saved" ? { kind: "idle" } : s));
    }, 2000);
  }

  // Drag end → stage the move + show a confirm dialog. We
  // optimistically render the pin at the new spot (so the user sees
  // where it'll land) but DON'T save until they confirm. The pre-
  // drag coords are stashed so Cancel can snap the pin back.
  function handlePinDrag(
    photoIndex: number,
    newPlanPixelX: number,
    newPlanPixelY: number
  ) {
    if (!project || !revisionRef.current) return;
    const existing = project.photos[photoIndex];
    if (!existing) return; // bounds guard
    const oldX = existing.planPixelX ?? newPlanPixelX;
    const oldY = existing.planPixelY ?? newPlanPixelY;
    const updatedPhotos = [...project.photos];
    updatedPhotos[photoIndex] = {
      ...existing,
      planPixelX: newPlanPixelX,
      planPixelY: newPlanPixelY,
    };
    const updated: Project = { ...project, photos: updatedPhotos };
    setProject(updated); // optimistic preview under the dialog
    setPendingMove({
      photoIndex,
      photoLabel: existing.sequenceNumber,
      oldX,
      oldY,
      project: updated,
    });
  }

  // Confirm → commit the staged move to the save queue.
  function confirmMove() {
    if (!pendingMove) return;
    pendingRef.current = pendingMove.project;
    setPendingMove(null);
    void runSaveLoop();
  }

  // Cancel → revert the pin to its pre-drag coords. Setting the
  // photo's planPixelX/Y back to the old values re-renders the
  // Konva Group at the original position, snapping the pin back.
  function cancelMove() {
    if (!pendingMove || !project) return;
    const { photoIndex, oldX, oldY } = pendingMove;
    const existing = project.photos[photoIndex];
    if (existing) {
      const reverted = [...project.photos];
      reverted[photoIndex] = { ...existing, planPixelX: oldX, planPixelY: oldY };
      setProject({ ...project, photos: reverted });
    }
    setPendingMove(null);
  }

  const activePlan: FloorPlan | null =
    project?.floorPlans.find((p) => p.id === activePlanId) ?? null;

  return (
    <div className="mx-auto max-w-6xl px-6 py-10">
      <header className="mb-6 flex items-start justify-between gap-4">
        <div className="flex flex-col gap-1">
          <Link
            to={id ? `/projects/${id}` : "/projects"}
            className="text-xs text-neutral-500 hover:text-neutral-300"
          >
            ← Back to project
          </Link>
          <h1 className="text-2xl font-semibold">
            {project?.name ?? "Loading…"}{" "}
            <span className="text-neutral-500">/ Floor plans</span>
          </h1>
        </div>
        <div className="flex flex-col items-end gap-1 text-right">
          <span className="text-xs text-neutral-500">{session.user.email}</span>
          <button
            type="button"
            onClick={() => signOutLocal()}
            className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
          >
            Sign out
          </button>
        </div>
      </header>

      {error && (
        <div className="mb-6 rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
          {error}
        </div>
      )}

      {saveStatus.kind === "error" && (
        <div className="mb-4 rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
          Save failed: {saveStatus.message}
        </div>
      )}

      {project === null && !error && (
        <div className="text-sm text-neutral-500">Loading…</div>
      )}

      {project && project.floorPlans.length === 0 && (
        <div className="rounded border border-dashed border-neutral-800 p-10 text-center text-sm text-neutral-500">
          This project has no floor plans yet. Add one from the iPhone
          and it'll appear here.
        </div>
      )}

      {project && project.floorPlans.length > 0 && (
        <>
          <div className="mb-4 flex items-center justify-between gap-4">
            {project.floorPlans.length > 1 ? (
              <div className="flex flex-wrap gap-2">
                {project.floorPlans.map((p) => (
                  <button
                    key={p.id}
                    type="button"
                    onClick={() => setActivePlanId(p.id)}
                    className={
                      p.id === activePlanId
                        ? "rounded border border-blue-500 bg-blue-950/40 px-3 py-1 text-sm text-blue-200"
                        : "rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
                    }
                  >
                    {p.label}
                  </button>
                ))}
              </div>
            ) : (
              <div />
            )}
            <div className="flex items-center gap-3">
              {saveStatus.kind !== "idle" && saveStatus.kind !== "error" && (
                <span
                  className={
                    saveStatus.kind === "saving"
                      ? "text-xs text-neutral-400"
                      : "text-xs text-green-400"
                  }
                >
                  {saveStatus.kind === "saving" ? "Saving…" : "Saved ✓"}
                </span>
              )}
              <button
                type="button"
                onClick={() => setPinsUnlocked((v) => !v)}
                className={
                  pinsUnlocked
                    ? "rounded border border-amber-500 bg-amber-950/40 px-3 py-1 text-xs text-amber-200 hover:bg-amber-900/40"
                    : "rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
                }
                title={
                  pinsUnlocked
                    ? "Pins are unlocked — drag to reposition. Click to lock."
                    : "Pins are locked. Click to unlock and reposition."
                }
              >
                {pinsUnlocked ? "🔓 Pins unlocked" : "🔒 Unlock pins"}
              </button>
            </div>
          </div>

          {pinsUnlocked && (
            <div className="mb-3 rounded border border-amber-800 bg-amber-950/30 p-2 text-xs text-amber-200">
              Pins are unlocked — drag a pin to reposition it. You'll be
              asked to confirm each move before it saves.
            </div>
          )}

          {activePlan && id && (
            <FloorPlanCanvas
              projectId={id}
              plan={activePlan}
              photos={project.photos}
              onSelectPhoto={(idx) => setLightboxIndex(idx)}
              onPinDrag={pinsUnlocked ? handlePinDrag : undefined}
            />
          )}
        </>
      )}

      {pendingMove && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-200">
              Move photo{" "}
              <span className="font-semibold">#{pendingMove.photoLabel}</span>{" "}
              to the new position?
            </div>
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={cancelMove}
                className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={confirmMove}
                className="rounded border border-blue-500 bg-blue-600/80 px-4 py-1.5 text-sm font-medium text-white hover:bg-blue-600"
              >
                Move it
              </button>
            </div>
          </div>
        </div>
      )}

      {project && id && lightboxIndex !== null && (
        <PhotoLightbox
          projectId={id}
          photos={project.photos}
          startIndex={lightboxIndex}
          onClose={() => setLightboxIndex(null)}
        />
      )}
    </div>
  );
}
