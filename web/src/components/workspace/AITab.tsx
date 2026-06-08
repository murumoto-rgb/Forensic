import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { BatchRetagControl } from "../BatchRetagControl";

/**
 * AI tab — currently hosts the project-level batch-retag control
 * (the only AI feature surface that was previously on the project
 * detail page). PR #6 of the Path-P series will add:
 *
 *   - Project tag selection (3-level context → primary → secondary)
 *   - Job-specific vocabulary
 *   - AI notes (project-scoped prompt instructions)
 *   - Auto-tag untagged / Auto-tag every-photo modes
 *   - Clear AI tags
 *   - Model + confidence + concurrency controls
 *   - Preview-prompt
 *
 * This shell just gives those sections a home. The legacy batch-
 * retag control is wired up to the shared manifest so it lives
 * inside the tabbed workspace.
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
    <section className="flex flex-col gap-4">
      <header className="text-sm text-neutral-400">
        AI tagging — automate the controlled-vocabulary pass on the
        project's photos. Project-level tag selection, job vocabulary,
        and clear-AI-tags land in a follow-up PR.
      </header>
      {canEdit ? (
        <BatchRetagControl
          projectId={projectId}
          projectRef={manifest.projectRef}
          revisionRef={manifest.revisionRef}
          setProject={manifest.setProject}
          setRevision={manifest.setRevision}
          photoCount={project.photos.length}
        />
      ) : (
        <div className="rounded border border-neutral-800 bg-neutral-900/40 px-3 py-2 text-sm text-neutral-500">
          Take the edit lock to run batch AI tagging.
        </div>
      )}
    </section>
  );
}
