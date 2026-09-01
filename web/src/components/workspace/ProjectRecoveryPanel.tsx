import { useEffect, useRef, useState } from "react";
import type { GetProjectVersionResponse, Project, ProjectHealthResponse, ProjectVersionSummary } from "@forensic/shared";
import { api } from "../../lib/api";
import type { ProjectManifestHook, RestoreReview } from "../../lib/useProjectManifest";
import { Modal } from "../Modal";

const message = (error: unknown) => error instanceof Error ? error.message : "Request failed";
interface VersionPreview { id: string; review: RestoreReview; detail: GetProjectVersionResponse | null }
const fieldLabels: Partial<Record<keyof Project, string>> = { name: "Project name", projectAddress: "Address", photos: "Photo metadata", trashedPhotos: "Trashed photos", floorPlans: "Floor plans", aiInstructions: "AI instructions", inspectionChecklist: "Checklist", inspectionSessions: "Inspection visits", reportLayout: "Report layout", isFrozen: "Finalized", isDeleted: "In trash" };
function displayValue(value: unknown): string {
  if (value == null) return "Not set";
  if (Array.isArray(value)) return `${value.length} items`;
  if (typeof value === "object") return "Settings / metadata";
  return String(value);
}
export function ManifestComparison({ current, target }: { current: Project; target: Project }) {
  const [expanded, setExpanded] = useState<string | null>(null);
  const fields = (Object.keys(target) as Array<keyof Project>).filter(key => JSON.stringify(current[key]) !== JSON.stringify(target[key]));
  return <div className="space-y-2 text-xs">
    <p>{fields.length ? `${fields.length} fields differ from the current project.` : "The manifest metadata matches the current project; asset references may differ."}</p>
    {fields.map(key => <div key={key} className="rounded border border-neutral-700 p-2">
      <button type="button" aria-expanded={expanded === key} onClick={() => setExpanded(expanded === key ? null : key)} className="w-full text-left font-medium text-blue-200">{fieldLabels[key] ?? key}: {displayValue(current[key])} → {displayValue(target[key])}</button>
      {expanded === key && <div className="mt-2 grid gap-2"><div><strong>Current</strong><pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all">{JSON.stringify(current[key], null, 2)}</pre></div><div><strong>Reviewed version</strong><pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all">{JSON.stringify(target[key], null, 2)}</pre></div></div>}
    </div>)}
  </div>;
}
export function ProjectRecoveryPanel({ projectId, manifest, canEdit }: { projectId: string; manifest: ProjectManifestHook; canEdit: boolean }) {
  const [health, setHealth] = useState<ProjectHealthResponse | null>(null);
  const [healthError, setHealthError] = useState<string | null>(null);
  const [versionsError, setVersionsError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [versions, setVersions] = useState<ProjectVersionSummary[]>([]);
  const [preview, setPreview] = useState<VersionPreview | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [confirmed, setConfirmed] = useState(false);
  const requestRef = useRef(0);
  const previewRequestRef = useRef(0);
  useEffect(() => () => { requestRef.current++; previewRequestRef.current++; }, [projectId]);

  async function verify() {
    const request = ++requestRef.current;
    setBusy(true); setHealthError(null); setVersionsError(null);
    const [healthResult, historyResult] = await Promise.allSettled([api.getProjectHealth(projectId, true), api.listProjectVersions(projectId)]);
    if (request !== requestRef.current) return;
    if (healthResult.status === "fulfilled") setHealth(healthResult.value);
    else setHealthError(`Asset verification failed: ${message(healthResult.reason)}`);
    if (historyResult.status === "fulfilled") setVersions(historyResult.value.versions);
    else setVersionsError(`Version history failed: ${message(historyResult.reason)}`);
    setBusy(false);
  }
  async function openPreview(id: string) {
    const current = manifest.projectRef.current;
    const revision = manifest.revisionRef.current;
    if (!current || !revision) return;
    const request = ++previewRequestRef.current;
    const review = { project: current, revision };
    setPreview({ id, review, detail: null }); setPreviewError(null); setConfirmed(false);
    try {
      const detail = await api.getProjectVersion(projectId, id);
      if (request === previewRequestRef.current) setPreview({ id, review, detail });
    } catch (error) { if (request === previewRequestRef.current) setPreviewError(`Could not load version preview: ${message(error)}`); }
  }
  function closePreview() {
    if (manifest.restoring) return;
    previewRequestRef.current++; setPreview(null); setPreviewError(null); setConfirmed(false);
  }
  async function restore() {
    if (!preview?.detail || !confirmed) return;
    setPreviewError(null);
    try { await manifest.restoreVersion(preview.id, preview.review); closePreview(); }
    catch (error) { setPreviewError(`Restore failed: ${message(error)}`); }
  }
  const changedSincePreview = preview !== null && (manifest.project !== preview.review.project || manifest.revision !== preview.review.revision);
  const unverified = health?.assets.filter(asset => asset.state === "unverified").length ?? 0;
  return <section className="rounded border border-neutral-800 bg-neutral-900/40 p-4">
    <div className="flex items-center justify-between gap-2"><h2 className="text-sm font-medium">Project health and version history</h2><button type="button" onClick={() => void verify()} disabled={busy || manifest.restoring} className="rounded border border-neutral-700 px-2 py-1 text-xs disabled:opacity-50">{busy ? "Verifying…" : "Verify assets"}</button></div>
    {healthError && <p role="alert" className="mt-2 text-xs text-red-300">{healthError}</p>}
    {versionsError && <p role="alert" className="mt-2 text-xs text-red-300">{versionsError}</p>}
    {health && <div className="mt-2 text-xs text-neutral-300"><p>{health.available} available / {health.expected} expected · {health.missing} missing · {unverified} unverified.</p><p className="text-neutral-500">Checked {new Date(health.checkedAt).toLocaleString()}. This availability check is not a backup receipt.</p><ul>{health.assets.filter(asset => asset.state === "missing" || asset.state === "unverified").map(asset => <li key={`${asset.entityId}-${asset.kind}-${asset.filename}`}>{asset.filename}: {asset.state}</li>)}</ul></div>}
    <div className="mt-3 space-y-2">{versions.map(version => <div key={version.id} className="flex items-center justify-between gap-2 rounded border border-neutral-800 p-2 text-xs"><span>{new Date(version.createdAt).toLocaleString()} · {version.photoCount} photos · {version.restorable ? "Immutable references complete" : `${version.missingAssetCount} incomplete references`}</span><button type="button" onClick={() => void openPreview(version.id)} disabled={manifest.restoring} className="rounded border border-neutral-700 px-2 py-1">Preview version</button></div>)}</div>
    {preview && <Modal title="Review project version" onClose={closePreview} className="max-w-2xl">
      <h3 className="font-medium">Review project version</h3>
      {previewError && <p role="alert" className="text-sm text-red-300">{previewError}</p>}
      {!preview.detail && !previewError && <p role="status">Loading version metadata…</p>}
      {preview.detail && <>
        <p className="text-xs">Version from {new Date(preview.detail.version.createdAt).toLocaleString()}. Restore replaces the current manifest and its asset references. Existing history is retained.</p>
        <ManifestComparison current={preview.review.project} target={preview.detail.project} />
        {!preview.detail.version.restorable && <p role="alert" className="text-xs text-amber-200">This version has incomplete evidence references. Its metadata can be reviewed, but it cannot be restored.</p>}
        {changedSincePreview && <p role="alert" className="text-xs text-amber-200">The project changed after this preview. Close it and review the version again.</p>}
        {manifest.hasPendingChanges && <p className="text-xs text-amber-200">Finish or retry pending saves before restoring.</p>}
        <label className="flex items-center gap-2 text-xs"><input type="checkbox" checked={confirmed} onChange={event => setConfirmed(event.target.checked)} disabled={manifest.restoring} />I reviewed these changes and want to restore this version.</label>
      </>}
      <div className="flex justify-end gap-2"><button type="button" onClick={closePreview} disabled={manifest.restoring}>Cancel</button><button type="button" onClick={() => void restore()} disabled={!preview.detail?.version.restorable || !confirmed || !canEdit || manifest.restoring || manifest.hasPendingChanges || changedSincePreview || manifest.project?.isFrozen} className="rounded border border-amber-600 px-3 py-1 disabled:opacity-50">{manifest.restoring ? "Restoring…" : "Confirm restore"}</button></div>
    </Modal>}
  </section>;
}
