import { Link } from "react-router-dom";
import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { ExportPdfControl } from "../ExportPdfControl";
import { FolderExportControl } from "../FolderExportControl";
import { CsvExportControl } from "../CsvExportControl";

/**
 * Export tab — home for the three export modes. Each card kicks off
 * its respective backend job; the unified Exports page
 * (`/projects/:id/exports`) is the persistent listing where every
 * past export lives for re-download.
 *
 * Layout: three cards (PDF / Folder by Bucket / AI Analysis CSV
 * link) plus a sticky link to the Exports page.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

export function ExportTab({ projectId, manifest, canEdit }: Props) {
  const project = manifest.project;
  if (!project) return null;
  const photoCount = project.photos.length;

  return (
    <section className="flex flex-col gap-5">
      <header className="flex items-center justify-between">
        <p className="text-sm text-neutral-400">
          Export the project as a PDF report, a per-bucket folder
          bundle (originals + captions.txt, EXIF preserved), or an
          AI-analysis CSV. All exports land on the Exports page for
          re-download.
        </p>
        <Link
          to={`/projects/${projectId}/exports`}
          className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-200 hover:bg-neutral-800"
        >
          View all exports →
        </Link>
      </header>

      <div className="grid grid-cols-1 gap-3 lg:grid-cols-3">
        <Card title="PDF report" emoji="📄">
          <p className="mb-3 text-xs text-neutral-500">
            Bound report with pages per photo. Pick layout density,
            bucket grouping, section order. Matches iOS PDF export.
          </p>
          <ExportPdfControl
            projectId={projectId}
            canExport={canEdit}
            floorPlans={project.floorPlans.map((p) => ({
              id: p.id,
              label: p.label,
            }))}
          />
        </Card>

        <Card title="Folder by Bucket" emoji="📁">
          <p className="mb-3 text-xs text-neutral-500">
            One subfolder per bucket. Photos copied in full
            resolution with EXIF preserved bit-for-bit + a
            captions.txt per folder. Matches iOS.
          </p>
          <FolderExportControl
            projectId={projectId}
            canExport={canEdit}
            photoCount={photoCount}
          />
        </Card>

        <Card title="AI Analysis CSV" emoji="📊">
          <p className="mb-3 text-xs text-neutral-500">
            One row per primary tag with the AI's context,
            observation, caption, measurement, and reviewer flag.
            Opens directly in Excel / Google Sheets.
          </p>
          <CsvExportControl
            projectId={projectId}
            canExport={canEdit}
            photoCount={photoCount}
          />
        </Card>
      </div>
    </section>
  );
}

function Card({
  title,
  emoji,
  children,
}: {
  title: string;
  emoji: string;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded border border-neutral-800 bg-neutral-950/40 p-4">
      <div className="mb-2 flex items-center gap-2 text-sm font-semibold text-neutral-100">
        <span className="text-xl">{emoji}</span>
        <span>{title}</span>
      </div>
      {children}
    </section>
  );
}

