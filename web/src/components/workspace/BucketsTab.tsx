import type { ProjectManifestHook } from "../../lib/useProjectManifest";

/**
 * Buckets tab — placeholder shell for Build #5.76.1 (Path P #1/8).
 * Bucket CRUD + per-photo assignment lands in PR #5 of this series.
 * Showing the existing list of buckets as a read-only summary so
 * users can verify the data is there.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

export function BucketsTab({ manifest }: Props) {
  const project = manifest.project;
  if (!project) return null;
  const buckets = [...project.buckets].sort(
    (a, b) => a.sortOrder - b.sortOrder
  );
  return (
    <section className="flex flex-col gap-4">
      <header className="text-sm text-neutral-400">
        Buckets — user-defined categories for grouping photos in
        exports. Create / rename / recolor / reorder / delete arrives
        in a follow-up PR; this tab currently shows the buckets that
        already exist on the manifest.
      </header>
      {buckets.length === 0 ? (
        <div className="rounded border border-dashed border-neutral-800 p-6 text-center text-sm text-neutral-500">
          No buckets defined for this project yet. iOS can create them
          today; web bucket management ships in PR #5 of this series.
        </div>
      ) : (
        <ul className="flex flex-col gap-2">
          {buckets.map((bucket) => {
            const count = project.photos.filter(
              (p) => p.bucketID === bucket.id
            ).length;
            return (
              <li
                key={bucket.id}
                className="flex items-center gap-3 rounded border border-neutral-800 bg-neutral-900/40 px-3 py-2 text-sm"
              >
                <span
                  className="inline-block h-3 w-3 rounded-full"
                  style={{ background: bucket.colorHex }}
                />
                <span className="text-neutral-100">{bucket.name}</span>
                <span className="ml-auto text-xs text-neutral-500">
                  {count} photo{count === 1 ? "" : "s"}
                </span>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
