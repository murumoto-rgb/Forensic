import { useState } from "react";
import type { Photo } from "@forensic/shared";
import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { useTagConfidenceThreshold } from "../../lib/useTagConfidenceThreshold";
import { usePhotoFilters } from "../../lib/usePhotoFilters";
import { PhotoList } from "../PhotoList";
import { PhotoLightbox } from "../PhotoLightbox";
import { PhotoFilterBar } from "../PhotoFilterBar";

/**
 * Photos tab — rich list of rows + filter bar + search.
 *
 * Build #5.78.1 (Path P #3/8) adds the filter chip bar above the
 * list. State lives in `usePhotoFilters`; the list itself remains
 * a pure render of whatever subset the filter accepts. The
 * lightbox opens against the FILTERED set so prev/next stays
 * inside the user's current scope.
 *
 * Tag / relocate / overflow per-row stubs and the editor sheet
 * still land in PR #4.
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
    </>
  );
}
