import { useEffect, useState } from "react";
import { useParams, Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import type { Project, FloorPlan } from "@forensic/shared";
import { signOutLocal } from "../lib/supabase";
import { api, ApiError } from "../lib/api";
import { FloorPlanCanvas } from "../components/FloorPlanCanvas";
import { PhotoLightbox } from "../components/PhotoLightbox";

/**
 * Project floor plan viewer page. Route: `/projects/:id/plan`
 * (optionally with `?planId=<id>` to deep-link a specific plan).
 *
 * Loads the project manifest, lets the user pick which floor plan
 * to view if there are multiple, and renders the canvas with all
 * pins + distress marks for the active plan. Clicking a pin opens
 * the lightbox at that photo's index.
 */
interface Props {
  session: Session;
}

export function ProjectPlanPage({ session }: Props) {
  const { id } = useParams<{ id: string }>();
  const [project, setProject] = useState<Project | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [activePlanId, setActivePlanId] = useState<string | null>(null);
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    setProject(null);
    setError(null);
    api
      .getProject(id)
      .then((res) => {
        if (cancelled) return;
        setProject(res.project);
        // Default to the project's active plan, falling back to the
        // first plan if `activeFloorPlanID` doesn't resolve.
        const candidate =
          res.project.activeFloorPlanID ?? res.project.floorPlans[0]?.id ?? null;
        setActivePlanId(candidate);
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

  const activePlan: FloorPlan | null =
    project?.floorPlans.find((p) => p.id === activePlanId) ?? null;

  return (
    <div className="mx-auto max-w-6xl px-6 py-10">
      <header className="mb-6 flex items-start justify-between gap-4">
        <div className="flex flex-col gap-1">
          <Link
            to={id ? `/projects/${id}` : "/projects"}
            className="text-xs text-neutral-500 hover:text-neutral-300"
          >
            ← Back to project
          </Link>
          <h1 className="text-2xl font-semibold">
            {project?.name ?? "Loading…"}{" "}
            <span className="text-neutral-500">/ Floor plans</span>
          </h1>
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

      {project && project.floorPlans.length === 0 && (
        <div className="rounded border border-dashed border-neutral-800 p-10 text-center text-sm text-neutral-500">
          This project has no floor plans yet. Add one from the iPhone
          and it'll appear here.
        </div>
      )}

      {project && project.floorPlans.length > 0 && (
        <>
          {project.floorPlans.length > 1 && (
            <div className="mb-4 flex flex-wrap gap-2">
              {project.floorPlans.map((p) => (
                <button
                  key={p.id}
                  type="button"
                  onClick={() => setActivePlanId(p.id)}
                  className={
                    p.id === activePlanId
                      ? "rounded border border-blue-500 bg-blue-950/40 px-3 py-1 text-sm text-blue-200"
                      : "rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
                  }
                >
                  {p.label}
                </button>
              ))}
            </div>
          )}

          {activePlan && id && (
            <FloorPlanCanvas
              projectId={id}
              plan={activePlan}
              photos={project.photos}
              onSelectPhoto={(idx) => setLightboxIndex(idx)}
            />
          )}
        </>
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
