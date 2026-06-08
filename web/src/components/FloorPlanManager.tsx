import { useState } from "react";
import type { FloorPlan, Photo, Project } from "@forensic/shared";

/**
 * Floor plan management (Build #5.89.1).
 *
 * Per-project list of floor plans with three editable affordances:
 *   - **Rename** — text input committing on blur (same pattern as
 *     the project name / address inputs on the Info tab).
 *   - **Set active** — writes `Project.activeFloorPlanID`. The
 *     canvas above auto-rebinds because the picker chips read the
 *     same field.
 *   - **Remove** — drops the plan from `Project.floorPlans` and
 *     nulls `floorPlanID` on every photo that referenced it (so
 *     no photo dangles a stale reference). Confirmed via dialog
 *     that quotes the photo count.
 *
 * Adding a brand-new plan needs image upload — that ships in a
 * separate PR alongside web file-upload "add photos".
 *
 * Defaults collapsed so the canvas keeps its prominence; the
 * disclosure caret reads "Manage plans · N" inline above the
 * existing plan-picker chip row.
 */
interface Props {
  project: Project;
  canEdit: boolean;
  onProjectChanged: (next: Project) => void;
}

export function FloorPlanManager({
  project,
  canEdit,
  onProjectChanged,
}: Props) {
  const [open, setOpen] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<{
    plan: FloorPlan;
    affectedPhotos: number;
  } | null>(null);

  const plans = project.floorPlans;

  function commitLabel(planId: string, nextLabel: string) {
    if (!canEdit) return;
    const trimmed = nextLabel.trim();
    if (trimmed.length === 0) return;
    const idx = plans.findIndex((p) => p.id === planId);
    if (idx === -1) return;
    if (plans[idx]!.label === trimmed) return;
    const updated = [...plans];
    updated[idx] = { ...plans[idx]!, label: trimmed };
    onProjectChanged({ ...project, floorPlans: updated });
  }

  function setActive(planId: string) {
    if (!canEdit) return;
    if (project.activeFloorPlanID === planId) return;
    onProjectChanged({ ...project, activeFloorPlanID: planId });
  }

  function previewRemove(plan: FloorPlan) {
    const affected = project.photos.filter(
      (p) => p.floorPlanID === plan.id
    ).length;
    setConfirmDelete({ plan, affectedPhotos: affected });
  }

  function doRemove() {
    if (!confirmDelete || !canEdit) return;
    const { plan } = confirmDelete;
    const updatedPlans = plans.filter((p) => p.id !== plan.id);
    const updatedPhotos: Photo[] = project.photos.map((ph) =>
      ph.floorPlanID === plan.id
        ? { ...ph, floorPlanID: null, planPixelX: null, planPixelY: null }
        : ph
    );
    // If we just removed the active plan, fall back to the first
    // remaining plan (or null if none remain) so the canvas has
    // somewhere to land.
    const nextActive =
      project.activeFloorPlanID === plan.id
        ? (updatedPlans[0]?.id ?? null)
        : project.activeFloorPlanID;
    onProjectChanged({
      ...project,
      floorPlans: updatedPlans,
      photos: updatedPhotos,
      activeFloorPlanID: nextActive,
    });
    setConfirmDelete(null);
  }

  if (plans.length === 0) return null;

  return (
    <div className="mb-3">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="flex items-center gap-2 text-xs text-neutral-400 hover:text-neutral-200"
      >
        <span>{open ? "▾" : "▸"}</span>
        <span>Manage plans · {plans.length}</span>
      </button>

      {open && (
        <ul className="mt-2 flex flex-col gap-2 rounded border border-neutral-800 bg-neutral-900/30 p-2">
          {plans.map((plan) => {
            const photoCount = project.photos.filter(
              (p) => p.floorPlanID === plan.id
            ).length;
            const isActive = project.activeFloorPlanID === plan.id;
            return (
              <li
                key={plan.id}
                className="flex flex-wrap items-center gap-2 rounded border border-neutral-800 p-2"
              >
                <input
                  type="text"
                  defaultValue={plan.label}
                  onBlur={(e) => commitLabel(plan.id, e.currentTarget.value)}
                  disabled={!canEdit}
                  className="min-w-0 flex-1 rounded border border-transparent bg-transparent px-1 text-sm text-neutral-100 focus:border-neutral-700 focus:bg-neutral-950 disabled:opacity-60"
                />
                <span className="text-xs text-neutral-500">
                  {photoCount} photo{photoCount === 1 ? "" : "s"}
                </span>
                {isActive ? (
                  <span className="rounded border border-blue-700 bg-blue-950/40 px-2 py-0.5 text-[11px] uppercase tracking-wide text-blue-200">
                    Active
                  </span>
                ) : (
                  <button
                    type="button"
                    onClick={() => setActive(plan.id)}
                    disabled={!canEdit}
                    className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    Set active
                  </button>
                )}
                <button
                  type="button"
                  onClick={() => previewRemove(plan)}
                  disabled={!canEdit || plans.length === 1}
                  className="rounded border border-red-700 px-2 py-0.5 text-xs text-red-200 hover:bg-red-950/40 disabled:cursor-not-allowed disabled:opacity-50"
                  title={
                    plans.length === 1
                      ? "Can't remove the last plan — add another first."
                      : "Remove this plan + un-place its photos."
                  }
                >
                  Remove
                </button>
              </li>
            );
          })}
          <p className="px-1 text-[11px] text-neutral-600">
            Adding a brand-new floor plan ships with the web file-upload
            PR. Today plans are uploaded from iOS.
          </p>
        </ul>
      )}

      {confirmDelete && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="flex w-full max-w-sm flex-col gap-4 rounded-lg border border-neutral-700 bg-neutral-900 p-6 shadow-2xl">
            <div className="text-sm text-neutral-200">
              Remove floor plan{" "}
              <span className="font-semibold">{confirmDelete.plan.label}</span>?
            </div>
            <div className="text-xs text-neutral-400">
              {confirmDelete.affectedPhotos > 0
                ? `${confirmDelete.affectedPhotos} photo${confirmDelete.affectedPhotos === 1 ? "" : "s"} placed on this plan will become unplaced (their pixel coordinates clear). Their entries in the manifest stay.`
                : "No photos are placed on this plan."}
              {project.activeFloorPlanID === confirmDelete.plan.id &&
                " The canvas will fall back to the first remaining plan."}
            </div>
            <div className="flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setConfirmDelete(null)}
                className="rounded border border-neutral-700 px-4 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={doRemove}
                className="rounded border border-red-600 bg-red-700/40 px-4 py-1.5 text-sm text-red-100 hover:bg-red-700/60"
              >
                Remove
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
