import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { BatchRetagControl } from "../BatchRetagControl";
import { ProjectAIConfig } from "../ProjectAIConfig";

/**
 * AI tab — config + batch run (Build #5.81.1 — Path P #6/8).
 *
 * Two sections:
 *
 *   1. Project AI config (`ProjectAIConfig`)
 *      - AI notes (`aiInstructions`)
 *      - Job-specific vocabulary (`aiExtraVocabulary`)
 *      - Tag selection summary + clear
 *      - Clear AI tags (project-wide)
 *
 *   2. Batch re-tag (`BatchRetagControl`)
 *      - "Re-tag all" with skip-already-tagged toggle (the
 *        existing "untagged vs every" semantics)
 *      - Model, concurrency, progress panel
 *
 * Both consume the shared manifest hook so config writes and
 * batch-result writes share one save loop and revision.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

export function AITab({ projectId, manifest, canEdit }: Props) {
  const project = manifest.project;
  if (!project) return null;

  return (
    <section className="flex flex-col gap-6">
      <ProjectAIConfig
        project={project}
        canEdit={canEdit}
        onProjectChanged={(next) => manifest.save(next)}
      />

      <section className="flex flex-col gap-2 rounded border border-neutral-800 bg-neutral-900/40 p-3">
        <div className="text-xs uppercase tracking-wide text-neutral-500">
          Batch tagging
        </div>
        <p className="text-xs text-neutral-400">
          Run AI tagging across this project's photos. Results land as
          pending suggestions to review on the photo editor (Photos
          tab → 🏷).
        </p>
        {canEdit ? (
          <BatchRetagControl
            projectId={projectId}
            projectRef={manifest.projectRef}
            revisionRef={manifest.revisionRef}
            setProject={manifest.setProject}
            setRevision={manifest.setRevision}
            save={manifest.save}
            saveAndWait={manifest.saveAndWait}
            photoCount={project.photos.length}
          />
        ) : (
          <div className="text-sm text-neutral-500">
            Take the edit lock to run batch AI tagging.
          </div>
        )}
      </section>
    </section>
  );
}
