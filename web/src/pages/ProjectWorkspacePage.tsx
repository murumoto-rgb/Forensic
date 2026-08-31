import {
  Link,
  Navigate,
  Route,
  Routes,
  useLocation,
  useParams,
} from "react-router-dom";
import { lazy, Suspense } from "react";
import type { Session } from "@supabase/supabase-js";
import { signOutLocal } from "../lib/supabase";
import { useProjectLock } from "../lib/useProjectLock";
import { useProjectManifest } from "../lib/useProjectManifest";
import { LockBanner } from "../components/LockBanner";
import { PhotosTab } from "../components/workspace/PhotosTab";
const FloorPlanTab = lazy(() => import("../components/workspace/FloorPlanTab").then((m) => ({ default: m.FloorPlanTab })));
const AITab = lazy(() => import("../components/workspace/AITab").then((m) => ({ default: m.AITab })));
const BucketsTab = lazy(() => import("../components/workspace/BucketsTab").then((m) => ({ default: m.BucketsTab })));
const ExportTab = lazy(() => import("../components/workspace/ExportTab").then((m) => ({ default: m.ExportTab })));
const InfoTab = lazy(() => import("../components/workspace/InfoTab").then((m) => ({ default: m.InfoTab })));

/**
 * Tabbed workspace shell (Build #5.76.1 — Path P #1/8).
 *
 * One container for everything you can do to a project: photos,
 * floor plan, AI configuration, buckets, export, project info.
 * Replaces the two single-purpose pages (`ProjectDetailPage`,
 * `ProjectPlanPage`) and lets every tab share one manifest, one
 * lock, one save loop.
 *
 * URL strategy: `/projects/:id/<tab>` so each tab is bookmarkable.
 * `/projects/:id` (no tab) redirects to `/photos`. Backwards-
 * compatible `/projects/:id/plan` keeps working because
 * `FloorPlanTab` lives at `/projects/:id/plan` — the old route
 * just lands on the same tab.
 */
interface Props {
  session: Session;
}

interface TabDef {
  slug: string;
  label: string;
}

const TABS: TabDef[] = [
  { slug: "photos", label: "Photos" },
  { slug: "plan", label: "Plan" },
  { slug: "ai", label: "Review" },
  { slug: "buckets", label: "Buckets" },
  { slug: "export", label: "Export" },
  { slug: "info", label: "Details" },
];

export function ProjectWorkspacePage({ session }: Props) {
  const { id } = useParams<{ id: string }>();
  const manifest = useProjectManifest(id);
  const lock = useProjectLock(id ?? null);
  // Build #5.126.1: composite gate. Holding the edit-lock + viewer
  // gate from #5.125.1 + project not frozen. Frozen projects are
  // read-only for everyone (Owner/Admin uses a separate "Unlock"
  // toggle on the Info tab that's exempt from this gate).
  //
  // Build #6.33.1: split `canExport` out from `canEdit`. iOS keeps
  // export available on finalized projects deliberately (frozen
  // means "don't edit the report any more", not "can't read it out")
  // and doesn't gate it on the edit lock either. Web now matches:
  // any account with write access can export, regardless of who's
  // holding the lock or whether the project is frozen. Viewers
  // still can't export — that's `hasWriteAccess` doing its job.
  const isFrozen = manifest.project?.isFrozen === true;
  const canExport = manifest.hasWriteAccess;
  const canEdit =
    canExport && lock.status.kind === "holding" && !isFrozen && !manifest.restoring;

  return (
    <div className="mx-auto max-w-6xl px-6 py-10">
      <WorkspaceHeader
        session={session}
        projectId={id ?? null}
        manifest={manifest}
      />

      <LockBanner
        status={lock.status}
        acquire={lock.acquire}
        release={lock.release}
        force={lock.force}
        refresh={lock.refresh}
        acknowledgeLost={lock.acknowledgeLost}
      />

      {isFrozen && (
        <div className="mb-4 flex items-center gap-2 rounded border border-amber-700 bg-amber-950/30 px-3 py-2 text-sm text-amber-200">
          <span>🔒</span>
          <span>
            This project is <span className="font-medium">locked / finalized</span>.
            All edits are disabled until an owner or admin unlocks it
            from the Info tab.
          </span>
        </div>
      )}

      <TabBar projectId={id ?? null} />

      <div className="mt-4">
        {!id ? (
          <div className="text-sm text-red-300">No project id in URL.</div>
        ) : manifest.status.kind === "loading" ? (
          <div className="text-sm text-neutral-500">Loading project…</div>
        ) : manifest.status.kind === "error" && manifest.project === null ? (
          <div className="rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
            {manifest.status.message}
          </div>
        ) : manifest.project == null ? (
          <div className="text-sm text-neutral-500">Project not found.</div>
        ) : (
          <Suspense fallback={<div className="text-sm text-neutral-500">Loading workspace tab…</div>}><Routes>
            <Route index element={<Navigate to="photos" replace />} />
            <Route
              path="photos"
              element={
                <PhotosTab
                  projectId={id}
                  manifest={manifest}
                  canEdit={canEdit}
                />
              }
            />
            <Route
              path="plan"
              element={
                <FloorPlanTab
                  projectId={id}
                  manifest={manifest}
                  canEdit={canEdit}
                />
              }
            />
            <Route
              path="ai"
              element={
                <AITab
                  projectId={id}
                  manifest={manifest}
                  canEdit={canEdit}
                />
              }
            />
            <Route
              path="buckets"
              element={
                <BucketsTab
                  projectId={id}
                  manifest={manifest}
                  canEdit={canEdit}
                />
              }
            />
            <Route
              path="export"
              element={
                <ExportTab
                  projectId={id}
                  manifest={manifest}
                  canExport={canExport}
                />
              }
            />
            <Route
              path="info"
              element={
                <InfoTab projectId={id} manifest={manifest} canEdit={canEdit} />
              }
            />
            <Route path="*" element={<Navigate to="photos" replace />} />
          </Routes></Suspense>
        )}
      </div>
    </div>
  );
}

interface WorkspaceHeaderProps {
  session: Session;
  projectId: string | null;
  manifest: ReturnType<typeof useProjectManifest>;
}

function WorkspaceHeader({ session, manifest }: WorkspaceHeaderProps) {
  const project = manifest.project;
  return (
    <header className="mb-6 flex items-start justify-between gap-4">
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
            {project.floorPlans.length} plan
            {project.floorPlans.length === 1 ? "" : "s"}
            {" · "}
            Created {new Date(project.createdAt).toLocaleDateString()}
          </div>
        )}
      </div>
      <div className="flex flex-col items-end gap-2 text-right">
        <span className="text-xs text-neutral-500">{session.user.email}</span>
        <SaveStatusPill status={manifest.status} />
        {manifest.restoring && <span role="status" className="text-xs text-amber-200">Restoring reviewed version…</span>}
        {manifest.hasPendingChanges && (manifest.status.kind === "error" || manifest.status.kind === "conflict") && <button type="button" onClick={() => { if (manifest.project) manifest.save(manifest.project); }} className="text-xs text-blue-200">Retry save</button>}
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => void manifest.reload()}
            disabled={manifest.status.kind === "loading" || manifest.status.kind === "saving" || manifest.restoring || manifest.hasPendingChanges}
            className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800 disabled:opacity-50"
            title="Re-fetch the manifest from the server. Mirrors iOS's Sync-now button."
          >
            ↻
          </button>
          <Link
            to="/settings"
            className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
            title="Account + AI preferences + diagnostics"
          >
            ⚙
          </Link>
          <button
            type="button"
            onClick={() => signOutLocal()}
            className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
          >
            Sign out
          </button>
        </div>
      </div>
    </header>
  );
}

function SaveStatusPill({
  status,
}: {
  status: ReturnType<typeof useProjectManifest>["status"];
}) {
  if (status.kind === "saving") {
    return <span className="text-xs text-neutral-400">Saving…</span>;
  }
  if (status.kind === "saved") {
    return <span className="text-xs text-green-400">Saved ✓</span>;
  }
  if (status.kind === "conflict" || status.kind === "error") {
    return (
      <span
        className="max-w-[16rem] truncate text-xs text-red-400"
        title={status.message}
      >
        {status.message}
      </span>
    );
  }
  return null;
}

function TabBar({ projectId }: { projectId: string | null }) {
  // `useLocation` re-renders the bar on every navigation so the
  // active-tab highlight stays in sync without manual subscriptions.
  const location = useLocation();
  const path = location.pathname.replace(/\/+$/, "");
  const activeSlug =
    TABS.find((t) => path.endsWith(`/${t.slug}`))?.slug ?? "photos";

  return (
    <nav className="flex flex-wrap gap-1 border-b border-neutral-800 pb-1">
      {TABS.map((tab) => {
        const isActive = tab.slug === activeSlug;
        return (
          <Link
            key={tab.slug}
            to={projectId ? `/projects/${projectId}/${tab.slug}` : "#"}
            className={
              isActive
                ? "rounded-t border-b-2 border-blue-500 px-3 py-1.5 text-sm font-medium text-blue-200"
                : "rounded-t border-b-2 border-transparent px-3 py-1.5 text-sm text-neutral-400 hover:text-neutral-200"
            }
          >
            {tab.label}
          </Link>
        );
      })}
    </nav>
  );
}
