import type { ProjectManifestHook } from "../../lib/useProjectManifest";

/**
 * Info tab — project metadata at a glance. Currently read-only.
 * Address editing (writes `projectAddress`) and report-branding
 * (via `app_config`) land in PR #8 of the Path-P series.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
}

export function InfoTab({ manifest }: Props) {
  const project = manifest.project;
  if (!project) return null;
  const gps = project.projectGPS;
  return (
    <section className="flex flex-col gap-4">
      <dl className="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm">
        <dt className="text-neutral-500">Name</dt>
        <dd className="text-neutral-100">{project.name}</dd>

        <dt className="text-neutral-500">Created</dt>
        <dd className="text-neutral-200">
          {new Date(project.createdAt).toLocaleString()}
        </dd>

        <dt className="text-neutral-500">Address</dt>
        <dd className="text-neutral-200">
          {project.projectAddress ?? (
            <span className="text-neutral-500">(none set)</span>
          )}
        </dd>

        <dt className="text-neutral-500">GPS</dt>
        <dd className="font-mono text-xs text-neutral-200">
          {gps ? (
            <>
              {gps.latitude.toFixed(5)}, {gps.longitude.toFixed(5)}
              {gps.accuracyFeet != null && (
                <span className="text-neutral-500">
                  {" "}
                  · ±{gps.accuracyFeet.toFixed(0)} ft
                </span>
              )}
            </>
          ) : (
            <span className="font-sans text-neutral-500">(no fix)</span>
          )}
        </dd>

        <dt className="text-neutral-500">Photo count</dt>
        <dd className="text-neutral-200">
          {project.photos.length}{" "}
          <span className="text-neutral-500">
            ({project.trashedPhotos.length} in trash)
          </span>
        </dd>

        <dt className="text-neutral-500">Floor plans</dt>
        <dd className="text-neutral-200">{project.floorPlans.length}</dd>

        <dt className="text-neutral-500">Buckets</dt>
        <dd className="text-neutral-200">{project.buckets.length}</dd>

        <dt className="text-neutral-500">Manifest schema</dt>
        <dd className="text-neutral-500">v{project.manifestSchemaVersion}</dd>
      </dl>
      <p className="text-xs text-neutral-500">
        Address editing + report-branding controls land in a follow-up
        PR of the Path-P parity series.
      </p>
    </section>
  );
}
