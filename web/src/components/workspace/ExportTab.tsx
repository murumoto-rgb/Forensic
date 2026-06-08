import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { ExportPdfControl } from "../ExportPdfControl";

/**
 * Export tab — home for `ExportPdfControl` (the PDF-export options
 * modal + progress pill). Previously inline in `ProjectDetailPage`;
 * relocated as part of the workspace shell (Build #5.76.1).
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

export function ExportTab({ projectId, manifest, canEdit }: Props) {
  const project = manifest.project;
  if (!project) return null;
  return (
    <section className="flex flex-col gap-4">
      <header className="text-sm text-neutral-400">
        Export the project as a PDF. The options sheet controls page
        size, photos per page, plan-mode, bucket grouping, annotations,
        and which sections appear — full parity with the iOS PDF
        export.
      </header>
      <ExportPdfControl
        projectId={projectId}
        canExport={canEdit}
        floorPlans={project.floorPlans.map((p) => ({
          id: p.id,
          label: p.label,
        }))}
      />
    </section>
  );
}
