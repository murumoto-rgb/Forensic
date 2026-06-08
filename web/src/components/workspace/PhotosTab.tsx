import { useState } from "react";
import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { PhotoGrid } from "../PhotoGrid";
import { PhotoLightbox } from "../PhotoLightbox";

/**
 * Photos tab — thin shell around the existing thumbnail grid +
 * lightbox in Build #5.76.1 (Path P #1/8). The rich list rows, the
 * filter bar, the in-row editing, and select mode all land in
 * subsequent PRs of this series; this PR keeps the existing
 * behaviour intact while it lives inside a tab.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  /** Reserved — will gate inline editing affordances added in
   *  later PRs. The current PR has no editable surface in this
   *  tab; the grid + lightbox are read-only. */
  canEdit: boolean;
}

export function PhotosTab({ projectId, manifest }: Props) {
  const project = manifest.project;
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);
  if (!project) return null;

  return (
    <>
      <PhotoGrid
        projectId={projectId}
        photos={project.photos}
        onSelect={(idx) => setLightboxIndex(idx)}
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
