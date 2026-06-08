import { useState } from "react";
import type { Photo } from "@forensic/shared";
import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { PhotoList } from "../PhotoList";
import { PhotoLightbox } from "../PhotoLightbox";

/**
 * Photos tab — rich list of photo rows (Build #5.77.1 — Path P #2/8).
 *
 * As of this PR the tab shows one `PhotoListRow` card per photo —
 * thumbnail + sequence number + badges + timestamp + location +
 * bucket + tag chips + favorite/tag/locate/overflow action stack.
 * Card layout is a responsive grid that auto-fills as many columns
 * as the viewport allows (`minmax(380px, 1fr)`).
 *
 * Click a thumbnail → opens the lightbox. The favorite-toggle on
 * each row writes through the shared manifest hook so the change
 * is persisted. Tag / relocate / overflow actions are stubbed and
 * land in later PRs of the parity series.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

export function PhotosTab({ projectId, manifest, canEdit }: Props) {
  const project = manifest.project;
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
      <div className="mb-3 text-sm text-neutral-400">
        Photos · {project.photos.length}
      </div>
      <PhotoList
        projectId={projectId}
        project={project}
        photos={project.photos}
        canEdit={canEdit}
        onOpen={(idx) => setLightboxIndex(idx)}
        onPhotoUpdated={updatePhoto}
      />
      {lightboxIndex !== null && (
        <PhotoLightbox
          projectId={projectId}
          photos={project.photos}
          startIndex={lightboxIndex}
          onClose={() => setLightboxIndex(null)}
        />
      )}
    </>
  );
}
