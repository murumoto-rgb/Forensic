import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import type { ProjectManifestHook } from "../../lib/useProjectManifest";

/**
 * Info tab — project metadata + editable name + editable address +
 * trash button.
 *
 * Address editing landed in Build #5.83.1 (Path P #8/8). Name editing
 * + trash landed in the project-management round (PR #1).
 *
 * Name commits on blur (same pattern as address). Trash writes
 * `isDeleted: true` via `manifest.save` and navigates back to the
 * project list — the server's GET endpoint returns 404 for trashed
 * projects, so the workspace becomes unloadable as soon as the save
 * lands. Restore happens from the project list's Trashed section.
 *
 * Forward-geocoding (resolving the typed address into lat/long and
 * stamping `projectGPS`) is iOS-only — web stores the literal string
 * and lets the next iOS sync pick a fix if the user wants one.
 */
interface Props {
  projectId: string;
  manifest: ProjectManifestHook;
  canEdit: boolean;
}

export function InfoTab({ manifest, canEdit }: Props) {
  const project = manifest.project;
  const navigate = useNavigate();
  const [name, setName] = useState(project?.name ?? "");
  const [address, setAddress] = useState(project?.projectAddress ?? "");

  useEffect(() => {
    setName(project?.name ?? "");
  }, [project?.name]);
  useEffect(() => {
    setAddress(project?.projectAddress ?? "");
  }, [project?.projectAddress]);

  if (!project) return null;
  const gps = project.projectGPS;

  function commitName() {
    if (!project) return;
    const next = name.trim();
    if (next === "" || next === project.name) {
      setName(project.name);
      return;
    }
    manifest.save({ ...project, name: next });
  }

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

  function moveToTrash() {
    if (!project) return;
    const confirmed = window.confirm(
      `Move "${project.name}" to trash?\n\n` +
        `You can restore it from the project list's Trashed section. ` +
        `It won't appear in your active projects until you do.`
    );
    if (!confirmed) return;
    manifest.save({ ...project, isDeleted: true });
    navigate("/projects");
  }

  return (
    <section className="flex flex-col gap-4">
      <dl className="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm">
        <dt className="text-neutral-500">Name</dt>
        <dd>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            onBlur={commitName}
            disabled={!canEdit}
            placeholder="Project name"
            className="w-full max-w-md rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-100 placeholder:text-neutral-600 disabled:opacity-50"
          />
        </dd>

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
        Forward-geocoding (resolving the address to GPS coordinates)
        stays on iOS — when you next open the project there, iOS can
        pick a fix and stamp `projectGPS`.
      </p>

      <div className="mt-6 rounded border border-neutral-800 bg-neutral-900/40 p-4">
        <div className="mb-2 text-sm font-medium text-neutral-200">
          Tools
        </div>
        <button
          type="button"
          onClick={renumberByDate}
          disabled={!canEdit || project.photos.length === 0}
          className="rounded border border-neutral-700 px-3 py-1.5 text-sm text-neutral-200 transition hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
        >
          Renumber photos by date
        </button>
        <p className="mt-2 text-xs text-neutral-500">
          Sort all photos by capture timestamp ascending, then
          reassign sequence numbers 1..N. Useful after importing a
          backlog of photos that landed out of order. Mirrors iOS's
          "Renumber by date" action.
        </p>
      </div>

      <div className="mt-3 rounded border border-red-900/40 bg-red-950/20 p-4">
        <div className="mb-2 text-sm font-medium text-red-300">
          Danger zone
        </div>
        <button
          type="button"
          onClick={moveToTrash}
          disabled={!canEdit}
          className="rounded border border-red-800 px-3 py-1.5 text-sm text-red-300 transition hover:bg-red-900/30 disabled:cursor-not-allowed disabled:opacity-50"
        >
          Move to trash
        </button>
        <p className="mt-2 text-xs text-neutral-500">
          Soft-delete — the project disappears from the active list
          but you can restore it from the Trashed section.
          Permanent deletion is a separate action on the trash row.
        </p>
      </div>
    </section>
  );

  function renumberByDate() {
    if (!project) return;
    if (
      !window.confirm(
        `Renumber every photo in this project by capture date?\n\nReassigns sequence numbers 1..${project.photos.length} in ascending timestamp order. This change syncs to iOS on next pull.`
      )
    ) {
      return;
    }
    const sorted = [...project.photos].sort((a, b) => {
      const ta = new Date(a.timestamp).getTime();
      const tb = new Date(b.timestamp).getTime();
      if (Number.isNaN(ta) || Number.isNaN(tb)) return 0;
      return ta - tb;
    });
    const renumbered = sorted.map((p, i) => ({
      ...p,
      sequenceNumber: i + 1,
    }));
    manifest.save({ ...project, photos: renumbered });
  }
}
