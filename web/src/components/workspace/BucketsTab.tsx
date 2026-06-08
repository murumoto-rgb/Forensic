import type { ProjectManifestHook } from "../../lib/useProjectManifest";
import { BucketManager } from "../BucketManager";

/**
 * Buckets tab — full CRUD as of Build #5.80.1 (Path P #5/8).
 *
 * Create / rename / recolor / reorder / delete with confirm and
 * affected-photo count. Per-bucket photo count is live against
 * the manifest. Deleting a bucket nulls `bucketID` on every
 * affected photo so the project never has dangling assignments.
 *
 * Library load/save (cross-project bucket library) is a follow-on
 * — the per-project CRUD is the parity-critical part.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

export function BucketsTab({ manifest, canEdit }: Props) {
  const project = manifest.project;
  if (!project) return null;
  return (
    <section className="flex flex-col gap-4">
      <header className="text-sm text-neutral-400">
        Buckets — user-defined categories for grouping photos in
        exports. Create / rename / recolor / reorder / delete below.
        Per-photo bucket assignment is done from the photo editor
        (Photos tab → 🏷).
      </header>
      <BucketManager
        project={project}
        canEdit={canEdit}
        onProjectChanged={(next) => manifest.save(next)}
      />
    </section>
  );
}
