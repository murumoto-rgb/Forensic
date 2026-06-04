import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import { signOutLocal } from "../lib/supabase";
import { api, ApiError, type ProjectListItem } from "../lib/api";

interface Props {
  session: Session;
}

export function ProjectListPage({ session }: Props) {
  const [projects, setProjects] = useState<ProjectListItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .listProjects()
      .then((res) => setProjects(res.projects))
      .catch((e: unknown) => {
        if (e instanceof ApiError) {
          setError(`${e.errorCode}: ${e.message}`);
        } else {
          setError("Failed to load projects");
        }
      });
  }, []);

  return (
    <div className="mx-auto max-w-3xl px-6 py-10">
      <header className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Projects</h1>
          <p className="text-xs text-neutral-500">{session.user.email}</p>
        </div>
        <div className="flex items-center gap-2">
          <Link
            to="/admin/tag-library"
            className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
            title="Edit the team's app-wide AI tag library"
          >
            Tag library
          </Link>
          <Link
            to="/admin/ai-rules"
            className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
            title="Edit the team's app-wide AI rules / schema template"
          >
            AI rules
          </Link>
          <button
            type="button"
            onClick={() => signOutLocal()}
            className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
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

      {projects === null && !error && (
        <div className="text-sm text-neutral-500">Loading…</div>
      )}

      {projects !== null && projects.length === 0 && (
        <div className="rounded border border-dashed border-neutral-800 p-10 text-center text-sm text-neutral-500">
          No projects yet. Capture one on iOS and it will show up here.
        </div>
      )}

      {projects !== null && projects.length > 0 && (
        <ul className="divide-y divide-neutral-800 rounded border border-neutral-800">
          {projects.map((p) => (
            <li key={p.id}>
              <Link
                to={`/projects/${p.id}`}
                className="flex items-center justify-between gap-4 px-4 py-3 transition hover:bg-neutral-900"
              >
                <div className="min-w-0 flex-1">
                  <div className="truncate font-medium text-neutral-100">
                    {p.name}
                  </div>
                  <div className="text-xs text-neutral-500">
                    Updated {new Date(p.updatedAt).toLocaleString()}
                  </div>
                </div>
                <div className="text-neutral-600">›</div>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
