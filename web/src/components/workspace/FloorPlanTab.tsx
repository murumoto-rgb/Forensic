import { useEffect, useState } from "react";
import type { DistressKind, DistressMark, FloorPlan, Photo, Project } from "@forensic/shared";
import { FloorPlanCanvas } from "../FloorPlanCanvas";
import { FloorPlanManager } from "../FloorPlanManager";
import { PhotoPreviewPanel } from "../PhotoPreviewPanel";
import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { useUserPrefs } from "../../lib/useUserPrefs";
import { pinColorFor } from "../../lib/planMarkerColors";
import { pixelsToLocalFeet } from "../../lib/planCoords";

/**
 * Floor Plan tab — the canvas viewer + pin drag + distress add/edit
 * + preview panel that used to live in `ProjectPlanPage.tsx`.
 *
 * As of Build #5.76.1 (Path P #1/8) the project manifest is owned by
 * the workspace shell via `useProjectManifest`; this tab consumes it
 * via the `manifest` prop instead of loading its own copy. Save flow:
 *
 *   - Optimistic UI for pin drag + distress add: stage the new
 *     project in local `pendingMove` / `pendingAddDistress`,
 *     `manifest.setProject(optimistic)` so the canvas re-renders
 *     immediately, confirm dialog opens.
 *   - On Confirm: `manifest.save(pending)` queues the PUT.
 *   - On Cancel: `manifest.setProject(reverted)` un-stages locally.
 *
 * `setProject` updates state without queuing a write; `save`
 * updates state AND queues. That distinction is what makes the
 * pin-move confirm flow work without ever uploading the preview.
 */

interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

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
  return crypto.randomUUID();
}

/** Resolve which pin to amber-highlight on the canvas when a photo
 *  is selected in the preview panel — for a non-primary group
 *  member (a reshoot), highlight the group's primary instead since
 *  non-primaries don't render their own pin. */
function resolveHighlightPinId(
  selectedPhotoId: string | null,
  photos: readonly Photo[]
): string | null {
  if (!selectedPhotoId) return null;
  const selected = photos.find((p) => p.id === selectedPhotoId);
  if (!selected) return null;
  if (selected.isPrimary || !selected.groupID) return selected.id;
  const primary = photos.find(
    (p) => p.groupID === selected.groupID && p.isPrimary
  );
  return primary?.id ?? selected.id;
}

export function FloorPlanTab({ projectId, manifest, canEdit }: Props) {
  const project = manifest.project;

  const [activePlanId, setActivePlanId] = useState<string | null>(null);
  const [previewState, setPreviewState] = useState<{
    selectedPhotoId: string;
    scopedPhotoIds?: string[];
  } | null>(null);
  const [pinsUnlocked, setPinsUnlocked] = useState(false);
  const [distressUnlocked, setDistressUnlocked] = useState(false);
  const [distressKind, setDistressKind] = useState<DistressKind>("outOfPlumbDoor");
  // Pin size — cross-device synced via useUserPrefs (Build #6.13.1
  // moved this from a localStorage-only useState to the shared prefs
  // hook so the user's last-chosen size follows them across browsers).
  const userPrefs = useUserPrefs();
  const bubbleScale = userPrefs.bubbleScale;
  const setBubbleScale = (
    next: number | ((cur: number) => number)
  ): void => {
    const value =
      typeof next === "function" ? (next as (v: number) => number)(bubbleScale) : next;
    userPrefs.setBubbleScale(value);
  };
  const BUBBLE_SCALE_MIN = 0.5;
  const BUBBLE_SCALE_MAX = 2.5;
  const BUBBLE_SCALE_STEP = 0.1;

  const [pendingMove, setPendingMove] = useState<{
    photoIndex: number;
    photoLabel: number;
    oldX: number;
    oldY: number;
    project: Project;
  } | null>(null);

  const [pendingAddDistress, setPendingAddDistress] = useState<{
    kind: DistressKind;
    points: Array<[number, number]>;
    note: string;
    planId: string;
  } | null>(null);

  const [editingDistress, setEditingDistress] = useState<{
    mark: DistressMark;
    draftKind: DistressKind;
    draftNote: string;
    planId: string;
  } | null>(null);

  // Initialize active plan once the manifest finishes loading.
  useEffect(() => {
    if (!project) return;
    if (activePlanId) return;
    const candidate =
      project.activeFloorPlanID ?? project.floorPlans[0]?.id ?? null;
    if (candidate) setActivePlanId(candidate);
  }, [project, activePlanId]);

  // Drop both edit modes if the lock evaporates.
  useEffect(() => {
    if (!canEdit) {
      setPinsUnlocked(false);
      setDistressUnlocked(false);
    }
  }, [canEdit]);

  function openPreviewForPhoto(idx: number) {
    const photo = project?.photos[idx];
    if (!photo) return;
    let scopedPhotoIds: string[] | undefined;
    if (photo.groupID) {
      const ids = project?.photos
        .filter((p) => p.groupID === photo.groupID)
        .map((p) => p.id);
      if (ids && ids.length > 1) scopedPhotoIds = ids;
    }
    setPreviewState({ selectedPhotoId: photo.id, scopedPhotoIds });
  }

  function openPreviewForCluster(memberIndices: number[]) {
    if (memberIndices.length === 0 || !project) return;
    const memberPhotos = memberIndices
      .map((i) => project.photos[i])
      .filter((p): p is Photo => p != null);
    const lead = memberPhotos[0];
    if (!lead) return;
    const expanded = new Set<string>();
    for (const m of memberPhotos) {
      if (m.groupID) {
        for (const sib of project.photos) {
          if (sib.groupID === m.groupID) expanded.add(sib.id);
        }
      } else {
        expanded.add(m.id);
      }
    }
    setPreviewState({
      selectedPhotoId: lead.id,
      scopedPhotoIds: Array.from(expanded),
    });
  }

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

  // Pin drag → optimistic preview → confirm dialog. We update the
  // manifest's project state in place (without queuing a PUT) so
  // the canvas renders the new position immediately; the confirm
  // dialog then calls `manifest.save` to actually persist.
  //
  // Build #6.32.1: mirror iOS's `ProjectStore.setPhotoLocation` —
  // a placed pin now sets `floorPlanID` + pixels AND the derived
  // `localXFeet/Y`. Pixels are a per-plan projection; the feet
  // coords are what survive a move-to-level (see PhotosTab's
  // `moveToLevel` for the inverse). Before this fix, web-placed
  // pins had no feet coords, so the PDF exporter and any move
  // between plans lost their real-world position.
  function handlePinDrag(
    photoIndex: number,
    newPlanPixelX: number,
    newPlanPixelY: number
  ) {
    if (!project || !manifest.revisionRef.current) return;
    const existing = project.photos[photoIndex];
    if (!existing) return;
    const oldX = existing.planPixelX ?? newPlanPixelX;
    const oldY = existing.planPixelY ?? newPlanPixelY;
    const plan = activePlanId
      ? project.floorPlans.find((p) => p.id === activePlanId) ?? null
      : null;
    const feet = plan
      ? pixelsToLocalFeet(plan, newPlanPixelX, newPlanPixelY)
      : null;
    const updatedPhotos = [...project.photos];
    updatedPhotos[photoIndex] = {
      ...existing,
      floorPlanID: plan?.id ?? existing.floorPlanID,
      planPixelX: newPlanPixelX,
      planPixelY: newPlanPixelY,
      // Preserve existing feet coords when the plan is uncalibrated
      // (pixelsPerFoot <= 0); otherwise the helper returns the
      // derived pair.
      localXFeet: feet?.lx ?? existing.localXFeet,
      localYFeet: feet?.ly ?? existing.localYFeet,
    };
    const updated: Project = { ...project, photos: updatedPhotos };
    manifest.setProject(updated); // optimistic preview, no PUT
    setPendingMove({
      photoIndex,
      photoLabel: existing.sequenceNumber,
      oldX,
      oldY,
      project: updated,
    });
  }

  function confirmMove() {
    if (!pendingMove) return;
    manifest.save(pendingMove.project);
    setPendingMove(null);
  }

  function cancelMove() {
    if (!pendingMove || !project) return;
    const { photoIndex, oldX, oldY } = pendingMove;
    const existing = project.photos[photoIndex];
    if (existing) {
      const reverted = [...project.photos];
      reverted[photoIndex] = { ...existing, planPixelX: oldX, planPixelY: oldY };
      manifest.setProject({ ...project, photos: reverted });
    }
    setPendingMove(null);
  }

  function handleAddDistressFromCanvas(
    kind: DistressKind,
    points: Array<[number, number]>
  ) {
    if (!project || !activePlanId) return;
    setPendingAddDistress({ kind, points, note: "", planId: activePlanId });
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
      points: points as unknown as unknown[],
      note: note.trim() === "" ? null : note.trim(),
      createdAt: new Date().toISOString(),
    };
    const updatedPlans = [...project.floorPlans];
    updatedPlans[planIdx] = { ...plan, distress: [...plan.distress, newMark] };
    const updated: Project = { ...project, floorPlans: updatedPlans };
    setPendingAddDistress(null);
    manifest.save(updated);
  }
  function cancelAddDistress() {
    setPendingAddDistress(null);
  }

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
    const updatedDistress = [...plan.distress];
    updatedDistress[markIdx] = {
      ...mark,
      kind: draftKind,
      note: draftNote.trim() === "" ? null : draftNote.trim(),
    };
    const updatedPlans = [...project.floorPlans];
    updatedPlans[planIdx] = { ...plan, distress: updatedDistress };
    setEditingDistress(null);
    manifest.save({ ...project, floorPlans: updatedPlans });
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
    setEditingDistress(null);
    manifest.save({ ...project, floorPlans: updatedPlans });
  }
  function cancelEditDistress() {
    setEditingDistress(null);
  }

  if (!project) return null;

  if (project.floorPlans.length === 0) {
    return (
      <FloorPlanManager
        project={project}
        canEdit={canEdit}
        onProjectChanged={(next) => manifest.save(next)}
      />
    );
  }

  const activePlan: FloorPlan | null =
    project.floorPlans.find((p) => p.id === activePlanId) ?? null;
  const canvasDistressKind: DistressKind | null =
    distressUnlocked && activePlan ? distressKind : null;

  return (
    <>
      <FloorPlanManager
        project={project}
        canEdit={canEdit}
        onProjectChanged={(next) => manifest.save(next)}
      />

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
          {/* Build #6.26.1: pin color mode — Default / Bucket /
              Primary tag. Cross-device synced via useUserPrefs,
              same pattern as pin size. */}
          <div className="flex items-center gap-1 rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300">
            <span className="text-neutral-500">Color:</span>
            {([
              ["status", "Default"],
              ["bucket", "Bucket"],
              ["primaryTag", "Tag"],
            ] as const).map(([mode, label]) => (
              <button
                key={mode}
                type="button"
                onClick={() => userPrefs.setPlanColorMode(mode)}
                className={
                  userPrefs.planColorMode === mode
                    ? "rounded bg-blue-900/60 px-1.5 text-blue-100"
                    : "rounded px-1.5 text-neutral-300 hover:bg-neutral-800"
                }
                aria-pressed={userPrefs.planColorMode === mode}
              >
                {label}
              </button>
            ))}
          </div>
          {canEdit && (
            <>
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
            </>
          )}
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
            . Click an existing mark to edit or delete it. Each save
            is confirmed first.
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

      {activePlan && (
        <FloorPlanCanvas
          projectId={projectId}
          plan={activePlan}
          photos={project.photos}
          onSelectPhoto={(idx) => openPreviewForPhoto(idx)}
          onPinDrag={pinsUnlocked ? handlePinDrag : undefined}
          distressKind={canvasDistressKind}
          onAddDistress={
            distressUnlocked ? handleAddDistressFromCanvas : undefined
          }
          onClickDistress={
            distressUnlocked ? handleClickDistress : undefined
          }
          bubbleScale={bubbleScale}
          pinFillFor={
            project
              ? (p) => pinColorFor(p, userPrefs.planColorMode, project)
              : undefined
          }
          onClickCluster={(photoIndices) => {
            openPreviewForCluster(photoIndices);
          }}
          highlightedPhotoId={resolveHighlightPinId(
            previewState?.selectedPhotoId ?? null,
            project?.photos ?? []
          )}
          recenterPhotoId={previewState?.selectedPhotoId ?? null}
        />
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

      {editingDistress && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-200">Edit distress mark</div>
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

      {previewState !== null && (
        <PhotoPreviewPanel
          projectId={projectId}
          project={project}
          photos={project.photos}
          selectedPhotoId={previewState.selectedPhotoId}
          scopedPhotoIds={previewState.scopedPhotoIds}
          onSelectPhoto={(photoId) =>
            setPreviewState((s) =>
              s ? { ...s, selectedPhotoId: photoId } : null
            )
          }
          onPhotoUpdated={
            canEdit
              ? (updated) => {
                  if (!project) return;
                  const idx = project.photos.findIndex(
                    (p) => p.id === updated.id
                  );
                  if (idx < 0) return;
                  const nextPhotos = [...project.photos];
                  nextPhotos[idx] = updated;
                  manifest.save({ ...project, photos: nextPhotos });
                }
              : undefined
          }
          onClose={() => setPreviewState(null)}
        />
      )}
    </>
  );
}
