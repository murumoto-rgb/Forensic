import { useEffect, useState } from "react";
import type { ProjectManifestHook } from "../../lib/useProjectManifest";

/**
 * Info tab — project metadata + editable address.
 *
 * Build #5.83.1 (Path P #8/8) wires the address-edit affordance:
 * a plain text input that writes `projectAddress` on blur.
 * Forward-geocoding (resolving the typed address into lat/long and
 * stamping `projectGPS`) is iOS-only — web stores the literal string
 * and lets the next iOS sync pick a fix if the user wants one.
 *
 * Report-branding (logos, colors, header text) is out of scope for
 * this PR — it lives in `app_config` with a per-team payload, and
 * the upload + edit UI is a separate effort. Captured in the parity
 * matrix as a follow-on.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

export function InfoTab({ manifest, canEdit }: Props) {
  const project = manifest.project;
  const [address, setAddress] = useState(project?.projectAddress ?? "");

  useEffect(() => {
    setAddress(project?.projectAddress ?? "");
  }, [project?.projectAddress]);

  if (!project) return null;
  const gps = project.projectGPS;

  function commitAddress() {
    if (!project) return;
    const next = address.trim();
    const cur = project.projectAddress ?? "";
    if (next === cur.trim()) return;
    manifest.save({
      ...project,
      projectAddress: next === "" ? null : next,
    });
  }

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
        <dd>
          <input
            type="text"
            value={address}
            onChange={(e) => setAddress(e.target.value)}
            onBlur={commitAddress}
            disabled={!canEdit}
            placeholder="(no address set)"
            className="w-full max-w-md rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100 placeholder:text-neutral-600 disabled:opacity-50"
          />
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
        Address edits write `projectAddress` on blur. Forward-geocoding
        (resolving the address to GPS coordinates) stays on iOS — when
        you next open the project there, iOS can pick a fix and stamp
        `projectGPS`. Report-branding (logos / colors / header text)
        is a follow-on PR.
      </p>
    </section>
  );
}
