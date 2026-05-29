import { useEffect, useState } from "react";
import { useParams, Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import type { Project } from "@forensic/shared";
import { signOutLocal } from "../lib/supabase";
import { api, ApiError } from "../lib/api";
import { PhotoGrid } from "../components/PhotoGrid";
import { PhotoLightbox } from "../components/PhotoLightbox";

/**
 * Project detail page at `/projects/:id`. Loads the full manifest,
 * renders a header with project metadata, and shows the photo grid
 * below. Clicking a thumbnail opens the lightbox.
 */
interface Props {
  session: Session;
}

export function ProjectDetailPage({ session }: Props) {
  const { id } = useParams<{ id: string }>();
  const [project, setProject] = useState<Project | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    setProject(null);
    setError(null);
    api
      .getProject(id)
      .then((res) => {
        if (!cancelled) setProject(res.project);
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        if (e instanceof ApiError) setError(`${e.errorCode}: ${e.message}`);
        else setError("Failed to load project");
      });
    return () => {
      cancelled = true;
    };
  }, [id]);

  return (
    <div className="mx-auto max-w-6xl px-6 py-10">
      <header className="mb-8 flex items-start justify-between gap-4">
        <div className="flex flex-col gap-1">
          <Link
            to="/projects"
            className="text-xs text-neutral-500 hover:text-neutral-300"
          >
            ← All projects
          </Link>
          <h1 className="text-2xl font-semibold">
            {project?.name ?? "Loading…"}
          </h1>
          {project?.projectAddress && (
            <div className="text-sm text-neutral-400">
              {project.projectAddress}
            </div>
          )}
          {project && (
            <div className="text-xs text-neutral-500">
              {project.photos.length} photo
              {project.photos.length === 1 ? "" : "s"}
              {" · "}
              Created {new Date(project.createdAt).toLocaleDateString()}
            </div>
          )}
        </div>
        <div className="flex flex-col items-end gap-1 text-right">
          <span className="text-xs text-neutral-500">{session.user.email}</span>
          <button
            type="button"
            onClick={() => signOutLocal()}
            className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
          >
            Sign out
          </button>
        </div>
      </header>

      {error && (
        <div className="mb-6 rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
          {error}
        </div>
      )}

      {project === null && !error && (
        <div className="text-sm text-neutral-500">Loading…</div>
      )}

      {project && id && (
        <PhotoGrid
          projectId={id}
          photos={project.photos}
          onSelect={(idx) => setLightboxIndex(idx)}
        />
      )}

      {project && id && lightboxIndex !== null && (
        <PhotoLightbox
          projectId={id}
          photos={project.photos}
          startIndex={lightboxIndex}
          onClose={() => setLightboxIndex(null)}
        />
      )}
    </div>
  );
}
