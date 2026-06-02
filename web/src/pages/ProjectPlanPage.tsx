import { useEffect, useRef, useState } from "react";
import { useParams, Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import type { DistressKind, DistressMark, FloorPlan, Photo, Project } from "@forensic/shared";
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
 *
 * Distress add / edit / delete: Phase 3 PR-C-3. Pins-unlock and
 * distress-add are mutually exclusive modes. When distress mode is
 * on, a kind picker selects the placement target; click (point
 * kinds) or drag (crackFloor stroke) on the canvas stages a new
 * mark in a confirm dialog. Clicking an existing distress glyph
 * opens an editor (change kind / edit note / delete). All
 * mutations flow through the same save loop as pin moves.
 */
interface Props {
  session: Session;
}

type SaveStatus =
  | { kind: "idle" }
  | { kind: "saving" }
  | { kind: "saved" }
  | { kind: "error"; message: string };

// Pretty labels for the kind picker + editor dropdown. Order
// mirrors `DistressKind` declaration order in shared/manifest.ts.
const DISTRESS_KIND_LABELS: Record<DistressKind, string> = {
  outOfPlumbDoor: "Out of plumb door",
  doorNotLatching: "Door not latching",
  crackGradeBeam: "Crack in grade beam",
  crackFloor: "Crack in floor",
};
const DISTRESS_KIND_COLORS: Record<DistressKind, string> = {
  outOfPlumbDoor: "#ef4444",
  doorNotLatching: "#f97316",
  crackGradeBeam: "#a855f7",
  crackFloor: "#fb923c",
};
const DISTRESS_KIND_ORDER: DistressKind[] = [
  "outOfPlumbDoor",
  "doorNotLatching",
  "crackGradeBeam",
  "crackFloor",
];

function newUuid(): string {
  // crypto.randomUUID is available in modern browsers (and the
  // browsers Vercel's bundle targets). Returns lowercase canonical
  // form, which matches Postgres's `uuid` storage; iOS handles
  // either case on decode (`UUID(uuidString:)` is case-insensitive),
  // so a lowercase id round-trips cleanly to either platform.
  return crypto.randomUUID();
}

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

  // Distress add mode. Mutually exclusive with `pinsUnlocked`
  // (toggling one off-the-other). Default kind is the first in the
  // enum so the first click after toggling on has something to do.
  const [distressUnlocked, setDistressUnlocked] = useState(false);
  const [distressKind, setDistressKind] = useState<DistressKind>("outOfPlumbDoor");

  // Bubble size — uniform scale factor for the photo pins on the
  // floor plan canvas. Adjustable via toolbar +/- buttons; session
  // only (no persistence per user choice). Range + step here mirror
  // the iOS PlanViewer's manual bubble-scale slider for consistency.
  const [bubbleScale, setBubbleScale] = useState(1);
  const BUBBLE_SCALE_MIN = 0.5;
  const BUBBLE_SCALE_MAX = 2.5;
  const BUBBLE_SCALE_STEP = 0.1;

  // Spatial cluster popover — when the user clicks a clustered
  // representative pin, list the underlying photos in a small
  // floating panel and let them pick which one to open.
  const [clusterPopover, setClusterPopover] = useState<{
    photoIndices: number[];
    screenX: number;
    screenY: number;
  } | null>(null);

  // Staged add (canvas → confirm dialog → save). `points` carries
  // the proposed geometry in plan-pixel coordinates.
  const [pendingAddDistress, setPendingAddDistress] = useState<{
    kind: DistressKind;
    points: Array<[number, number]>;
    note: string;
    planId: string;
  } | null>(null);

  // Open editor for an existing mark.
  const [editingDistress, setEditingDistress] = useState<{
    mark: DistressMark;
    draftKind: DistressKind;
    draftNote: string;
    planId: string;
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
        const resp = await api.putProject(
          id,
          toSave,
          revisionRef.current
        );
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
          // free-tier cold-start window beyond the central retry
          // schedule, or a dropped connection. Safari reports this
          // as "Load failed", Chrome as "Failed to fetch". The
          // central retry in api.ts already burned through 5
          // attempts (~57 sec total); surface a human message and
          // re-stash so the user can retry by dragging again.
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

  // -----------------------------------------------------------------
  // Pin drag → confirm → save (Build #5.15.1)
  // -----------------------------------------------------------------

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

  // -----------------------------------------------------------------
  // Distress add / edit / delete (Build #5.23.1, Phase 3 PR-C-3)
  //
  // All three mutation paths share the same shape:
  //   1. Compute the new project state with the updated `floorPlans[i].distress`.
  //   2. Stash it in `pendingRef`.
  //   3. Kick `runSaveLoop`.
  // The optimistic React state update happens BEFORE the dialog
  // closes for delete (so the mark disappears immediately), and
  // AFTER confirmation for add/edit.
  // -----------------------------------------------------------------

  // Toggle helpers — pins / distress modes are mutually exclusive so
  // a single canvas gesture isn't ambiguous (a click would otherwise
  // either move a pin or place a mark; making them exclusive removes
  // the ambiguity at the UI level).
  function togglePinsUnlocked() {
    setPinsUnlocked((v) => {
      if (!v) setDistressUnlocked(false);
      return !v;
    });
  }
  function toggleDistressUnlocked() {
    setDistressUnlocked((v) => {
      if (!v) setPinsUnlocked(false);
      return !v;
    });
  }

  // Canvas → "user just placed a new mark". Stage in pendingAddDistress
  // and the confirm dialog opens. Cancel discards, Add commits +
  // saves.
  function handleAddDistressFromCanvas(
    kind: DistressKind,
    points: Array<[number, number]>
  ) {
    if (!project || !activePlanId) return;
    setPendingAddDistress({
      kind,
      points,
      note: "",
      planId: activePlanId,
    });
  }

  function confirmAddDistress() {
    if (!project || !pendingAddDistress) return;
    const { kind, points, note, planId } = pendingAddDistress;
    const planIdx = project.floorPlans.findIndex((p) => p.id === planId);
    const plan = planIdx === -1 ? undefined : project.floorPlans[planIdx];
    if (!plan) {
      setPendingAddDistress(null);
      return;
    }
    const newMark: DistressMark = {
      id: newUuid(),
      kind,
      // [[x, y], ...] matches iOS's CGPoint default Codable encoding,
      // so the mark round-trips through the manifest without iOS
      // having to handle a second shape on decode.
      points: points as unknown as unknown[],
      note: note.trim() === "" ? null : note.trim(),
      createdAt: new Date().toISOString(),
    };
    const updatedPlans = [...project.floorPlans];
    updatedPlans[planIdx] = {
      ...plan,
      distress: [...plan.distress, newMark],
    };
    const updated: Project = { ...project, floorPlans: updatedPlans };
    setProject(updated);
    setPendingAddDistress(null);
    pendingRef.current = updated;
    void runSaveLoop();
  }

  function cancelAddDistress() {
    setPendingAddDistress(null);
  }

  // Canvas → "user clicked an existing mark". Open the editor.
  function handleClickDistress(markId: string) {
    if (!project || !activePlanId) return;
    const plan = project.floorPlans.find((p) => p.id === activePlanId);
    if (!plan) return;
    const mark = plan.distress.find((m) => m.id === markId);
    if (!mark) return;
    setEditingDistress({
      mark,
      draftKind: mark.kind,
      draftNote: mark.note ?? "",
      planId: activePlanId,
    });
  }

  function saveEditDistress() {
    if (!project || !editingDistress) return;
    const { mark, draftKind, draftNote, planId } = editingDistress;
    const planIdx = project.floorPlans.findIndex((p) => p.id === planId);
    const plan = planIdx === -1 ? undefined : project.floorPlans[planIdx];
    if (!plan) {
      setEditingDistress(null);
      return;
    }
    const markIdx = plan.distress.findIndex((m) => m.id === mark.id);
    if (markIdx === -1) {
      setEditingDistress(null);
      return;
    }
    const updatedMark: DistressMark = {
      ...mark,
      kind: draftKind,
      note: draftNote.trim() === "" ? null : draftNote.trim(),
    };
    const updatedDistress = [...plan.distress];
    updatedDistress[markIdx] = updatedMark;
    const updatedPlans = [...project.floorPlans];
    updatedPlans[planIdx] = { ...plan, distress: updatedDistress };
    const updated: Project = { ...project, floorPlans: updatedPlans };
    setProject(updated);
    setEditingDistress(null);
    pendingRef.current = updated;
    void runSaveLoop();
  }

  function deleteEditDistress() {
    if (!project || !editingDistress) return;
    const { mark, planId } = editingDistress;
    const planIdx = project.floorPlans.findIndex((p) => p.id === planId);
    const plan = planIdx === -1 ? undefined : project.floorPlans[planIdx];
    if (!plan) {
      setEditingDistress(null);
      return;
    }
    const updatedDistress = plan.distress.filter((m) => m.id !== mark.id);
    const updatedPlans = [...project.floorPlans];
    updatedPlans[planIdx] = { ...plan, distress: updatedDistress };
    const updated: Project = { ...project, floorPlans: updatedPlans };
    setProject(updated);
    setEditingDistress(null);
    pendingRef.current = updated;
    void runSaveLoop();
  }

  function cancelEditDistress() {
    setEditingDistress(null);
  }

  const activePlan: FloorPlan | null =
    project?.floorPlans.find((p) => p.id === activePlanId) ?? null;

  // What the canvas should be in distress mode about (null = off).
  // Only active when the unlock toggle is on AND we have a plan.
  const canvasDistressKind: DistressKind | null =
    distressUnlocked && activePlan ? distressKind : null;

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
              {/* Bubble size +/- control. Session-only — resets on
                  reload. Mirrors the inline display style used by
                  Zoom on the canvas toolbar (Build #5.26.1). */}
              <div className="flex items-center gap-1 rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300">
                <span className="text-neutral-500">Pin size:</span>
                <button
                  type="button"
                  onClick={() =>
                    setBubbleScale((s) =>
                      Math.max(BUBBLE_SCALE_MIN, +(s - BUBBLE_SCALE_STEP).toFixed(2))
                    )
                  }
                  disabled={bubbleScale <= BUBBLE_SCALE_MIN + 1e-6}
                  className="rounded px-1 text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:text-neutral-600"
                  title="Smaller pins"
                  aria-label="Decrease pin size"
                >
                  −
                </button>
                <span className="w-10 text-center font-mono">
                  {Math.round(bubbleScale * 100)}%
                </span>
                <button
                  type="button"
                  onClick={() =>
                    setBubbleScale((s) =>
                      Math.min(BUBBLE_SCALE_MAX, +(s + BUBBLE_SCALE_STEP).toFixed(2))
                    )
                  }
                  disabled={bubbleScale >= BUBBLE_SCALE_MAX - 1e-6}
                  className="rounded px-1 text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:text-neutral-600"
                  title="Larger pins"
                  aria-label="Increase pin size"
                >
                  +
                </button>
              </div>
              <button
                type="button"
                onClick={togglePinsUnlocked}
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
              <button
                type="button"
                onClick={toggleDistressUnlocked}
                className={
                  distressUnlocked
                    ? "rounded border border-amber-500 bg-amber-950/40 px-3 py-1 text-xs text-amber-200 hover:bg-amber-900/40"
                    : "rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
                }
                title={
                  distressUnlocked
                    ? "Distress mode is on — click or drag the canvas to add. Click to exit."
                    : "Click to enter distress mode (add / edit / delete marks on this plan)."
                }
              >
                {distressUnlocked ? "✚ Adding distress" : "✚ Add distress"}
              </button>
            </div>
          </div>

          {pinsUnlocked && (
            <div className="mb-3 rounded border border-amber-800 bg-amber-950/30 p-2 text-xs text-amber-200">
              Pins are unlocked — drag a pin to reposition it. You'll be
              asked to confirm each move before it saves.
            </div>
          )}

          {distressUnlocked && (
            <div className="mb-3 flex flex-col gap-2 rounded border border-amber-800 bg-amber-950/30 p-2 text-xs text-amber-200">
              <div>
                Distress mode — pick a kind, then{" "}
                {distressKind === "crackFloor"
                  ? "drag on the canvas to draw a stroke"
                  : "click on the canvas to place a point"}
                . Click an existing mark to edit or delete it. Each
                save is confirmed first.
              </div>
              <div className="flex flex-wrap gap-2">
                {DISTRESS_KIND_ORDER.map((kind) => {
                  const selected = kind === distressKind;
                  return (
                    <button
                      key={kind}
                      type="button"
                      onClick={() => setDistressKind(kind)}
                      className={
                        selected
                          ? "flex items-center gap-1 rounded border border-amber-400 bg-amber-900/40 px-2 py-1 text-amber-100"
                          : "flex items-center gap-1 rounded border border-neutral-700 px-2 py-1 text-neutral-300 hover:bg-neutral-800"
                      }
                    >
                      <span
                        className="inline-block h-2.5 w-2.5 rounded-full"
                        style={{ background: DISTRESS_KIND_COLORS[kind] }}
                      />
                      {DISTRESS_KIND_LABELS[kind]}
                    </button>
                  );
                })}
              </div>
            </div>
          )}

          {activePlan && id && (
            <FloorPlanCanvas
              projectId={id}
              plan={activePlan}
              photos={project.photos}
              onSelectPhoto={(idx) => setLightboxIndex(idx)}
              onPinDrag={pinsUnlocked ? handlePinDrag : undefined}
              distressKind={canvasDistressKind}
              onAddDistress={
                distressUnlocked ? handleAddDistressFromCanvas : undefined
              }
              onClickDistress={
                distressUnlocked ? handleClickDistress : undefined
              }
              bubbleScale={bubbleScale}
              onClickCluster={(photoIndices, screenX, screenY) => {
                setClusterPopover({ photoIndices, screenX, screenY });
              }}
            />
          )}
        </>
      )}

      {/* Pin-move confirm */}
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

      {/* Distress-add confirm */}
      {pendingAddDistress && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-200">
              Add{" "}
              <span
                className="inline-block h-2.5 w-2.5 rounded-full align-middle"
                style={{
                  background: DISTRESS_KIND_COLORS[pendingAddDistress.kind],
                }}
              />{" "}
              <span className="font-semibold">
                {DISTRESS_KIND_LABELS[pendingAddDistress.kind]}
              </span>{" "}
              {pendingAddDistress.kind === "crackFloor"
                ? `stroke (${pendingAddDistress.points.length} points)?`
                : "at this location?"}
            </div>
            <label className="flex flex-col gap-1 text-xs text-neutral-400">
              Note (optional)
              <textarea
                value={pendingAddDistress.note}
                onChange={(e) =>
                  setPendingAddDistress(
                    pendingAddDistress
                      ? { ...pendingAddDistress, note: e.target.value }
                      : null
                  )
                }
                rows={2}
                className="rounded border border-neutral-700 bg-neutral-950 p-2 text-sm text-neutral-100 placeholder:text-neutral-600"
                placeholder="e.g. east-facing entry door, ¼″ gap top hinge"
              />
            </label>
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={cancelAddDistress}
                className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={confirmAddDistress}
                className="rounded border border-blue-500 bg-blue-600/80 px-4 py-1.5 text-sm font-medium text-white hover:bg-blue-600"
              >
                Add
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Distress edit / delete */}
      {editingDistress && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-200">
              Edit distress mark
            </div>
            <label className="flex flex-col gap-1 text-xs text-neutral-400">
              Kind
              <select
                value={editingDistress.draftKind}
                onChange={(e) =>
                  setEditingDistress(
                    editingDistress
                      ? {
                          ...editingDistress,
                          draftKind: e.target.value as DistressKind,
                        }
                      : null
                  )
                }
                className="rounded border border-neutral-700 bg-neutral-950 p-2 text-sm text-neutral-100"
              >
                {DISTRESS_KIND_ORDER.map((kind) => (
                  <option key={kind} value={kind}>
                    {DISTRESS_KIND_LABELS[kind]}
                  </option>
                ))}
              </select>
            </label>
            <label className="flex flex-col gap-1 text-xs text-neutral-400">
              Note
              <textarea
                value={editingDistress.draftNote}
                onChange={(e) =>
                  setEditingDistress(
                    editingDistress
                      ? { ...editingDistress, draftNote: e.target.value }
                      : null
                  )
                }
                rows={3}
                className="rounded border border-neutral-700 bg-neutral-950 p-2 text-sm text-neutral-100 placeholder:text-neutral-600"
                placeholder="(no note)"
              />
            </label>
            <div className="flex justify-between gap-3">
              <button
                type="button"
                onClick={deleteEditDistress}
                className="rounded border border-red-600 bg-red-950/40 px-4 py-1.5 text-sm text-red-200 hover:bg-red-900/40"
              >
                Delete
              </button>
              <div className="flex gap-3">
                <button
                  type="button"
                  onClick={cancelEditDistress}
                  className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  onClick={saveEditDistress}
                  className="rounded border border-blue-500 bg-blue-600/80 px-4 py-1.5 text-sm font-medium text-white hover:bg-blue-600"
                >
                  Save
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Spatial cluster popover (Build #5.26.1). When the user
          clicks a cluster representative pin, this floating panel
          opens at the pin's screen position and lists the
          underlying photo sequence numbers as chips. Click a chip
          → opens the lightbox at that photo. Click outside →
          dismisses. Position is `fixed` against the viewport;
          coordinates already include the page's bounding-rect
          offset (the canvas computes that). */}
      {project && clusterPopover && (
        <>
          {/* Invisible scrim catches outside-clicks to dismiss the
              popover. Z-index sits BELOW the popover itself but
              ABOVE the canvas so canvas clicks under it don't
              accidentally place new distress / drag pins. */}
          <div
            role="presentation"
            onClick={() => setClusterPopover(null)}
            className="fixed inset-0 z-40"
          />
          <div
            role="dialog"
            aria-label="Photos at this location"
            className="fixed z-50 flex max-w-xs flex-col gap-2 rounded-lg border border-neutral-700 bg-neutral-900 p-3 shadow-2xl"
            style={{
              left: clusterPopover.screenX,
              top: clusterPopover.screenY + 18,
              transform: "translateX(-50%)",
            }}
          >
            <div className="text-xs text-neutral-400">
              {clusterPopover.photoIndices.length} photos at this
              location — pick one:
            </div>
            <div className="flex flex-wrap gap-1.5">
              {clusterPopover.photoIndices
                .map((idx) => {
                  const photo = project.photos[idx];
                  return photo ? { idx, photo } : null;
                })
                .filter((x): x is { idx: number; photo: Photo } => x !== null)
                .sort(
                  (a, b) => a.photo.sequenceNumber - b.photo.sequenceNumber
                )
                .map(({ idx, photo }) => (
                  <button
                    key={photo.id}
                    type="button"
                    onClick={() => {
                      setClusterPopover(null);
                      setLightboxIndex(idx);
                    }}
                    title={photo.userCaption ?? `Photo #${photo.sequenceNumber}`}
                    className="rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-xs font-mono text-neutral-100 hover:border-blue-500 hover:bg-blue-950/40"
                  >
                    #{photo.sequenceNumber}
                  </button>
                ))}
            </div>
            <button
              type="button"
              onClick={() => setClusterPopover(null)}
              className="self-end text-[10px] text-neutral-500 hover:text-neutral-300"
            >
              Cancel
            </button>
          </div>
        </>
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
