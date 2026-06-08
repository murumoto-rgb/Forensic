import { useState } from "react";
import type { Photo, Project, Tag } from "@forensic/shared";
import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { useTagConfidenceThreshold } from "../../lib/useTagConfidenceThreshold";
import { usePhotoFilters } from "../../lib/usePhotoFilters";
import { PhotoList } from "../PhotoList";
import { PhotoLightbox } from "../PhotoLightbox";
import { PhotoFilterBar } from "../PhotoFilterBar";
import { PhotoPreviewPanel } from "../PhotoPreviewPanel";
import { SelectionActionBar } from "../SelectionActionBar";
import { TrashSection } from "../TrashSection";
import { BatchRetagControl } from "../BatchRetagControl";

/**
 * Photos tab — filter bar + rich list + editor + select mode.
 *
 * Build #5.82.1 (Path P #7/8) adds the select / batch-action flow:
 *
 *   - "Select" toggle in the header puts every row into checkbox
 *     mode (thumbnail click toggles selection instead of opening
 *     the lightbox; the right-side per-row action stack hides).
 *   - "All" / "None" shortcuts operate on the currently-FILTERED
 *     set (selecting filters then "All" is the standard iOS-style
 *     way to scope a batch action to a subset).
 *   - Action bar appears above the list with: Move to bucket,
 *     Move to level, Apply tag, Delete (→ trash). Each is one
 *     manifest mutation routed through the shared save loop.
 *
 * Re-tag-with-AI on the selection is deferred — see
 * `SelectionActionBar` for the rationale.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

export function PhotosTab({ projectId, manifest, canEdit }: Props) {
  const project = manifest.project;
  const [threshold] = useTagConfidenceThreshold();
  const filters = usePhotoFilters(
    project?.photos ?? [],
    project ?? ({ photos: [], buckets: [], floorPlans: [] } as never),
    threshold
  );
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);
  const [editorPhotoId, setEditorPhotoId] = useState<string | null>(null);
  const [selectMode, setSelectMode] = useState(false);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(() => new Set());
  // Selection-scoped re-tag flow: clicking "Re-tag with AI" in the
  // SelectionActionBar sets this to a snapshot of the selection,
  // which mounts a BatchRetagControl scoped to those IDs with its
  // modal auto-opened. Snapshotting (instead of streaming
  // selectedIds in) means changing the selection mid-batch doesn't
  // affect the in-flight run.
  const [retagSelection, setRetagSelection] = useState<readonly string[] | null>(
    null
  );

  if (!project) return null;

  function updatePhoto(next: Photo) {
    if (!project) return;
    const idx = project.photos.findIndex((p) => p.id === next.id);
    if (idx < 0) return;
    const nextPhotos = [...project.photos];
    nextPhotos[idx] = next;
    manifest.save({ ...project, photos: nextPhotos });
  }

  function toggleSelected(id: string) {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  function exitSelectMode() {
    setSelectMode(false);
    setSelectedIds(new Set());
  }

  function batchUpdate(mutator: (p: Photo) => Photo) {
    if (!project || selectedIds.size === 0) return;
    const nextPhotos = project.photos.map((p) =>
      selectedIds.has(p.id) ? mutator(p) : p
    );
    manifest.save({ ...project, photos: nextPhotos });
  }

  function moveToBucket(bucketId: string | null) {
    batchUpdate((p) => ({ ...p, bucketID: bucketId }));
  }
  function moveToLevel(floorPlanId: string | null) {
    // Moving to a new plan invalidates the per-pin pixel coords. Set
    // them to null so the photo shows up as "not placed" on the new
    // plan until the engineer drops a pin.
    batchUpdate((p) => ({
      ...p,
      floorPlanID: floorPlanId,
      planPixelX: floorPlanId == null ? null : p.planPixelX,
      planPixelY: floorPlanId == null ? null : p.planPixelY,
    }));
  }
  function applyTag(label: string) {
    batchUpdate((p) => {
      const exists = p.tags.some(
        (t) =>
          t.label.toLowerCase() === label.toLowerCase() && t.parentTag == null
      );
      if (exists) return p;
      const tag: Tag = { label, confidence: 1, parentTag: null };
      return { ...p, tags: [...p.tags, tag] };
    });
  }
  function batchDelete() {
    if (!project || selectedIds.size === 0) return;
    const now = new Date().toISOString();
    const moving: Photo[] = [];
    const remaining: Photo[] = [];
    for (const p of project.photos) {
      if (selectedIds.has(p.id)) moving.push({ ...p, trashedAt: now });
      else remaining.push(p);
    }
    const next: Project = {
      ...project,
      photos: remaining,
      trashedPhotos: [...project.trashedPhotos, ...moving],
    };
    manifest.save(next);
    exitSelectMode();
  }

  function selectAllFiltered() {
    setSelectedIds(new Set(filters.filtered.map((p) => p.id)));
  }

  return (
    <>
      <div className="mb-2 flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          {selectMode ? (
            <>
              <button
                type="button"
                onClick={selectAllFiltered}
                className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800"
              >
                Select all ({filters.filtered.length})
              </button>
              <button
                type="button"
                onClick={() => setSelectedIds(new Set())}
                className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800"
              >
                Select none
              </button>
              <button
                type="button"
                onClick={exitSelectMode}
                className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800"
              >
                Done
              </button>
            </>
          ) : (
            <button
              type="button"
              onClick={() => setSelectMode(true)}
              disabled={!canEdit}
              className="rounded border border-neutral-700 px-2 py-0.5 text-xs text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
              title={
                canEdit
                  ? "Enter select mode to apply actions to multiple photos"
                  : "Take the edit lock to use select mode"
              }
            >
              Select
            </button>
          )}
        </div>
      </div>

      <PhotoFilterBar
        filters={filters}
        project={project}
        total={project.photos.length}
      />

      {selectMode && selectedIds.size > 0 && (
        <SelectionActionBar
          count={selectedIds.size}
          buckets={project.buckets}
          floorPlans={project.floorPlans}
          onMoveToBucket={moveToBucket}
          onMoveToLevel={moveToLevel}
          onApplyTag={applyTag}
          onRetagWithAI={
            canEdit
              ? () => setRetagSelection(Array.from(selectedIds))
              : undefined
          }
          onDelete={batchDelete}
          onClearSelection={() => setSelectedIds(new Set())}
        />
      )}

      {retagSelection && (
        <BatchRetagControl
          projectId={projectId}
          projectRef={manifest.projectRef}
          revisionRef={manifest.revisionRef}
          setProject={manifest.setProject}
          setRevision={manifest.setRevision}
          photoCount={retagSelection.length}
          photoIds={retagSelection}
          hideTriggerButton
          initiallyOpen
          onClose={() => setRetagSelection(null)}
          // Remount whenever the snapshot changes so the next
          // selection-scoped batch starts from a clean state.
          key={retagSelection.join(",")}
        />
      )}

      <PhotoList
        projectId={projectId}
        project={project}
        photos={filters.filtered}
        canEdit={canEdit}
        selectMode={selectMode}
        selectedIds={selectedIds}
        onOpen={(idx) => setLightboxIndex(idx)}
        onOpenEditor={(photo) => setEditorPhotoId(photo.id)}
        onPhotoUpdated={updatePhoto}
        onToggleSelected={toggleSelected}
      />

      <TrashSection
        project={project}
        canEdit={canEdit}
        onProjectChanged={(next) => manifest.save(next)}
      />

      {lightboxIndex !== null && (
        <PhotoLightbox
          projectId={projectId}
          photos={filters.filtered}
          startIndex={lightboxIndex}
          onClose={() => setLightboxIndex(null)}
        />
      )}
      {editorPhotoId && (
        <PhotoPreviewPanel
          projectId={projectId}
          project={project}
          photos={filters.filtered}
          selectedPhotoId={editorPhotoId}
          onSelectPhoto={(id) => setEditorPhotoId(id)}
          onPhotoUpdated={canEdit ? updatePhoto : undefined}
          onClose={() => setEditorPhotoId(null)}
        />
      )}
    </>
  );
}
