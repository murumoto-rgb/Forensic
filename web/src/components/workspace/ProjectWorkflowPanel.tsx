import { useCallback, useEffect, useRef, useState } from "react";
import { applyInspectionPreset, setInspectionSession, type InspectionPreset, type Project, type WorkflowLibrary } from "@forensic/shared";
import { api } from "../../lib/api";
import type { ProjectManifestHook, RestoreReview } from "../../lib/useProjectManifest";
import { Modal } from "../Modal";
import { ManifestComparison } from "./ProjectRecoveryPanel";
const button = "rounded border border-neutral-700 px-2 py-1 text-xs disabled:opacity-50";
const panel = "rounded border border-neutral-800 bg-neutral-900/40 p-4";
const input = "rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-xs";
const message = (error: unknown) => error instanceof Error ? error.message : "Request failed";
export function ProjectWorkflowPanel({ manifest, canEdit }: { manifest: ProjectManifestHook; canEdit: boolean }) {
  const [library, setLibrary] = useState<WorkflowLibrary | null>(null);
  const [revision, setRevision] = useState<string | null>(null);
  const [libraryError, setLibraryError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [libraryBusy, setLibraryBusy] = useState(false);
  const [presetName, setPresetName] = useState("");
  const [checklistDraft, setChecklistDraft] = useState("");
  const [preview, setPreview] = useState<{ preset: InspectionPreset; review: RestoreReview; next: Project } | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [editPreset, setEditPreset] = useState<InspectionPreset | null>(null);
  const [editName, setEditName] = useState("");
  const [editChecklist, setEditChecklist] = useState("");
  const [editorError, setEditorError] = useState<string | null>(null);
  const [editorReloaded, setEditorReloaded] = useState(false);
  const editRevision = useRef<string | null>(null);
  const editSnapshot = useRef<InspectionPreset | null>(null);
  const [editError, setEditError] = useState<string | null>(null);
  const loadRequest = useRef(0);
  const loadLibrary = useCallback(async () => {
    const request = ++loadRequest.current;
    setLibraryBusy(true); setLibraryError(null);
    try { const response = await api.getWorkflowLibrary(); if (request === loadRequest.current) { setLibrary(response.library); setRevision(response.revision); return response; } }
    catch (error) { if (request === loadRequest.current) setLibraryError(`Could not load preset library: ${message(error)}`); }
    finally { if (request === loadRequest.current) setLibraryBusy(false); }
  }, []);
  useEffect(() => { void loadLibrary(); return () => { loadRequest.current++; }; }, [loadLibrary]);
  const project = manifest.project;
  if (!project) return null;
  const writable = canEdit && manifest.hasWriteAccess && !project.isFrozen && !manifest.restoring && !busy;
  async function persist(next: Project): Promise<boolean> {
    setBusy(true); setEditError(null);
    try { await manifest.saveAndWait(next); return true; }
    catch (error) { setEditError(`Change not saved: ${message(error)}`); return false; }
    finally { setBusy(false); }
  }
  async function savePresets(presets: InspectionPreset[]): Promise<boolean> {
    if (!library || libraryBusy) return false;
    setLibraryBusy(true); setLibraryError(null);
    const next = { ...library, inspectionPresets: presets };
    try { const response = await api.putWorkflowLibrary({ library: next, expectedRevision: revision }); setLibrary(next); setRevision(response.revision); return true; }
    catch (error) { setLibraryError(`Preset library was not saved: ${message(error)}. Refresh the library before retrying; your name was kept.`); return false; }
    finally { setLibraryBusy(false); }
  }
  function openPresetEditor(preset: InspectionPreset) {
    setEditPreset(preset);
    setEditName(preset.name);
    setEditChecklist(preset.checklist.join("\n"));
    setEditorError(null);
    setEditorReloaded(false);
    editRevision.current = revision;
    editSnapshot.current = preset;
  }
  async function reloadEditorLibrary() {
    if (libraryBusy || !editPreset) return;
    const response = await loadLibrary();
    if (!response) { setEditorError("Library reload failed. Your draft is kept."); return; }
    const current = response.library.inspectionPresets.find(preset => preset.id === editPreset.id);
    editRevision.current = response.revision;
    editSnapshot.current = current ?? null;
    if (!current) { setEditorError("This preset was deleted on another device. Your draft is kept, but it cannot overwrite the deletion."); return; }
    setEditPreset(current); setEditorReloaded(true); setEditorError(null);
  }
  async function savePresetEdit() {
    if (!writable || libraryBusy || !editPreset || !library || !editName.trim()) return;
    if (revision !== editRevision.current || library.inspectionPresets.find((preset) => preset.id === editPreset.id) !== editSnapshot.current) {
      setEditorError("This preset changed elsewhere. Refresh the library before saving.");
      return;
    }
    const lines = editChecklist.split("\n").map((line) => line.trim()).filter(Boolean);
    if (editName.trim().length > 100 || lines.length > 200 || lines.some((line) => line.length > 500)) {
      setEditorError("Preset name must be 100 characters or fewer; required views must be at most 200 lines of 500 characters each.");
      return;
    }
    const current = library.inspectionPresets.find((preset) => preset.id === editPreset.id);
    if (!current) { setEditorError("This preset was removed or changed elsewhere. Refresh the library before saving."); return; }
    const updated: InspectionPreset = { ...current, name: editName.trim(), checklist: lines };
    if (await savePresets(library.inspectionPresets.map((preset) => preset.id === updated.id ? updated : preset))) setEditPreset(null);
    else setEditorError("Preset was not saved. Refresh the library and try again; your draft was kept.");
  }
  async function createPreset() {
    const current = manifest.projectRef.current;
    const name = presetName.trim();
    if (!current || !name || !library) return;
    const preset: InspectionPreset = { id: crypto.randomUUID(), name, projectNamePrefix: current.name, projectAddress: current.projectAddress, aiInstructions: current.aiInstructions, tagSelection: current.tagSelection, aiExtraVocabulary: current.aiExtraVocabulary, buckets: current.buckets, checklist: current.inspectionChecklist.map(item => item.label), reportLayout: current.reportLayout ?? { perPage: 6, groupByBucket: false, includeMetadataTable: false } };
    if (await savePresets([...library.inspectionPresets, preset])) setPresetName(value => value.trim() === name ? "" : value);
  }
  function previewPreset(preset: InspectionPreset) {
    const current = manifest.projectRef.current;
    const currentRevision = manifest.revisionRef.current;
    if (!current || !currentRevision) return;
    setPreview({ preset, review: { project: current, revision: currentRevision }, next: applyInspectionPreset(current, preset) });
    setPreviewError(null);
  }
  async function applyPreset() {
    if (!preview) return;
    if (manifest.projectRef.current !== preview.review.project || manifest.revisionRef.current !== preview.review.revision || manifest.hasPendingChanges) {
      setPreviewError("The project changed after this preview. Close it and preview the preset again."); return;
    }
    setBusy(true); setPreviewError(null);
    try { await manifest.saveAndWait(preview.next); setPreview(null); }
    catch (error) { setPreviewError(`Preset was not saved: ${message(error)}. The preview was kept.`); }
    finally { setBusy(false); }
  }
  const sessions = project.inspectionSessions;
  const layout = project.reportLayout ?? { perPage: 6, groupByBucket: false, includeMetadataTable: false };
  return <>
    {editError && <p role="alert" className="text-sm text-red-300">{editError}</p>}
    <section className={panel}><h2 className="mb-2 text-sm font-medium">Inspection session</h2>
      <div className="flex flex-wrap gap-2 text-xs"><span>{sessions.length} visits</span><button className={button} disabled={!writable || sessions.some(session => session.endedAt === null)} onClick={() => void persist(setInspectionSession(project, "start"))}>Start / Resume</button><button className={button} disabled={!writable || !sessions.some(session => session.endedAt === null)} onClick={() => void persist(setInspectionSession(project, "stop"))}>Stop</button></div>
      <ol className="mt-2 space-y-1 text-xs text-neutral-400">{sessions.slice(-5).reverse().map(session => <li key={session.id}>Started {new Date(session.startedAt).toLocaleString()} · {session.endedAt ? `Stopped ${new Date(session.endedAt).toLocaleString()}` : "In progress"}</li>)}</ol>
    </section>
    <section className={panel}><h2 className="mb-2 text-sm font-medium">Inspection checklist</h2>
      <div className="space-y-2">{project.inspectionChecklist.map(item => <div key={item.id} className="flex items-center gap-2 text-xs"><label className="flex flex-1 items-center gap-2"><input type="checkbox" checked={item.isComplete} disabled={!writable} onChange={() => void persist({ ...project, inspectionChecklist: project.inspectionChecklist.map(current => current.id === item.id ? { ...current, isComplete: !current.isComplete } : current) })} />{item.label}</label><button aria-label={`Remove ${item.label}`} type="button" disabled={!writable} onClick={() => void persist({ ...project, inspectionChecklist: project.inspectionChecklist.filter(current => current.id !== item.id) })}>Remove</button></div>)}</div>
      <div className="mt-2 flex gap-2"><input aria-label="Required view" className={`${input} flex-1`} value={checklistDraft} onChange={event => setChecklistDraft(event.target.value)} placeholder="Required view" disabled={!writable} /><button className={button} disabled={!writable || !checklistDraft.trim()} onClick={() => { const label = checklistDraft.trim(); void persist({ ...project, inspectionChecklist: [...project.inspectionChecklist, { id: crypto.randomUUID(), label, isComplete: false }] }).then(saved => { if (saved) setChecklistDraft(value => value.trim() === label ? "" : value); }); }}>Add</button></div>
    </section>
    <section className={panel}><h2 className="mb-2 text-sm font-medium">Report layout</h2>
      <div className="flex flex-wrap gap-4 text-xs"><label>Photos per page <select aria-label="Photos per page" className={input} value={layout.perPage} disabled={!writable} onChange={event => void persist({ ...project, reportLayout: { ...layout, perPage: Number(event.target.value) } })}>{Array.from({ length: 12 }, (_, i) => <option key={i + 1} value={i + 1}>{i + 1}</option>)}</select></label><label><input type="checkbox" checked={layout.groupByBucket} disabled={!writable} onChange={event => void persist({ ...project, reportLayout: { ...layout, groupByBucket: event.target.checked } })} /> Group by bucket</label><label><input type="checkbox" checked={layout.includeMetadataTable} disabled={!writable} onChange={event => void persist({ ...project, reportLayout: { ...layout, includeMetadataTable: event.target.checked } })} /> Include metadata table</label></div>
    </section>
    <section className={panel}><h2 className="mb-2 text-sm font-medium">Inspection presets</h2>
      {libraryError && <p role="alert" className="mb-2 text-xs text-red-300">{libraryError}</p>}
      <button type="button" className={button} onClick={() => void loadLibrary()} disabled={libraryBusy}>{libraryBusy ? "Loading library…" : "Refresh preset library"}</button>
      <div className="mt-2 flex gap-2"><input aria-label="Preset name" value={presetName} onChange={event => setPresetName(event.target.value)} placeholder="Preset name" className={`${input} flex-1`} /><button type="button" className={button} disabled={!writable || !library || libraryBusy || !presetName.trim()} onClick={() => void createPreset()}>Save current setup</button></div>
      <div className="mt-3 space-y-2">{library?.inspectionPresets.map(preset => <div key={preset.id} className="flex flex-wrap items-center justify-between gap-2 rounded border border-neutral-800 p-2 text-xs"><button className="min-w-0 break-words text-left" type="button" onClick={() => previewPreset(preset)}>{preset.name}</button><span>{preset.checklist.length} required views · {preset.buckets.length} buckets</span><button type="button" disabled={!writable || libraryBusy} onClick={() => openPresetEditor(preset)}>Edit</button><button type="button" disabled={!writable || libraryBusy} onClick={() => void savePresets(library.inspectionPresets.filter(current => current.id !== preset.id))}>Delete</button></div>)}</div>
      {editPreset && <Modal title={`Edit preset: ${editPreset.name}`} onClose={() => { if (!libraryBusy) setEditPreset(null); }}>
        <p className="text-xs">Changes only this saved preset. Applying it to a project remains a separate reviewed action.</p>
        <label className="flex flex-col gap-1 text-xs">Name<input aria-label="Preset name" value={editName} disabled={libraryBusy} onChange={(event) => setEditName(event.target.value)} className={input} /></label>
        <label className="flex flex-col gap-1 text-xs">Required views, one per line<textarea aria-label="Required views" value={editChecklist} disabled={libraryBusy} onChange={(event) => setEditChecklist(event.target.value)} rows={8} className={input} /></label>
        {editorError && <><p role="alert" className="text-xs text-red-300">{editorError}</p><button type="button" className={button} disabled={libraryBusy} onClick={() => void reloadEditorLibrary()}>Reload saved library, keep draft</button></>}
        {editorReloaded && <div className="text-xs"><p>Saved version after reload: {editPreset.name}</p><ul>{editPreset.checklist.map((line, index) => <li key={index}>{line}</li>)}</ul><p>Your draft above was kept. Review before saving; saving replaces these fields in the saved version.</p></div>}
        <div className="flex justify-end gap-2"><button type="button" disabled={libraryBusy} onClick={() => setEditPreset(null)}>Cancel</button><button type="button" className={button} disabled={!writable || libraryBusy || !editName.trim() || !library?.inspectionPresets.some(preset => preset.id === editPreset.id)} onClick={() => void savePresetEdit()}>{libraryBusy ? "Saving…" : "Save changes"}</button></div>
      </Modal>}
      {preview && <Modal title={`Preview preset: ${preview.preset.name}`} onClose={() => { if (!busy) setPreview(null); }} className="max-w-2xl"><h3>Preview preset: {preview.preset.name}</h3><p className="text-xs">Append {preview.preset.buckets.length} buckets and {preview.preset.checklist.length} checklist items, and update the settings below.</p><ManifestComparison current={preview.review.project} target={preview.next} />{previewError && <p role="alert" className="text-xs text-red-300">{previewError}</p>}<div className="flex justify-end gap-2"><button disabled={busy} onClick={() => setPreview(null)}>Cancel</button><button className={button} disabled={!writable || manifest.hasPendingChanges} onClick={() => void applyPreset()}>{busy ? "Saving…" : "Apply preset"}</button></div></Modal>}
    </section>
  </>;
}
