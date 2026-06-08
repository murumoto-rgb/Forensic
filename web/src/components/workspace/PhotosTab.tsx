import { useState } from "react";
import type { Photo } from "@forensic/shared";
import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { useTagConfidenceThreshold } from "../../lib/useTagConfidenceThreshold";
import { usePhotoFilters } from "../../lib/usePhotoFilters";
import { PhotoList } from "../PhotoList";
import { PhotoLightbox } from "../PhotoLightbox";
import { PhotoFilterBar } from "../PhotoFilterBar";
import { PhotoPreviewPanel } from "../PhotoPreviewPanel";

/**
 * Photos tab — filter bar + rich list + editor sheet.
 *
 * Build #5.79.1 (Path P #4/8) wires the editor: the row's tag /
 * locate / overflow buttons now open the docked `PhotoPreviewPanel`
 * in edit mode against the clicked photo. The panel's inline
 * `PhotoEditorSection` lets you edit caption, observation, bucket,
 * rotation, favorite, and the tag chips directly; the existing
 * AI re-tag / accept-suggestion / AI-viewer machinery is reused.
 *
 * Click-through model:
 *   - thumbnail   → lightbox (full-screen, prev/next)
 *   - 🏷 / 📍 / ⋯  → editor panel (docked, full editing surface)
 *   - ★/☆ row btn  → immediate favorite toggle (no panel)
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
  if (!project) return null;

  function updatePhoto(next: Photo) {
    if (!project) return;
    const idx = project.photos.findIndex((p) => p.id === next.id);
    if (idx < 0) return;
    const nextPhotos = [...project.photos];
    nextPhotos[idx] = next;
    manifest.save({ ...project, photos: nextPhotos });
  }

  return (
    <>
      <PhotoFilterBar
        filters={filters}
        project={project}
        total={project.photos.length}
      />
      <PhotoList
        projectId={projectId}
        project={project}
        photos={filters.filtered}
        canEdit={canEdit}
        onOpen={(idx) => setLightboxIndex(idx)}
        onOpenEditor={(photo) => setEditorPhotoId(photo.id)}
        onPhotoUpdated={updatePhoto}
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
