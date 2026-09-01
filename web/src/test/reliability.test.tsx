import { act, cleanup, render, renderHook, waitFor } from "@testing-library/react";
import type { MutableRefObject } from "react";
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { mergeManifest } from "@forensic/shared";
import { useProjectManifest } from "../lib/useProjectManifest";
import { useBatchRetag } from "../lib/useBatchRetag";
import { PhotoList } from "../components/PhotoList";
import { Modal } from "../components/Modal";
import { FolderExportClient } from "../components/FolderExportClient";
import { PhotosTab } from "../components/workspace/PhotosTab";
import JSZip from "jszip";

const { apiMock } = vi.hoisted(() => ({ apiMock: { getProject: vi.fn(), putProject: vi.fn(), getPhotoUrlsBatch: vi.fn(), getTagLibraryConfig: vi.fn(), getAIRulesTemplateConfig: vi.fn(), getFolderExportManifest: vi.fn() } }));
const { tagMock } = vi.hoisted(() => ({ tagMock: vi.fn() }));
vi.mock("../lib/api", () => ({ api: apiMock, ApiError: class ApiError extends Error { status = 500; errorCode = "test"; } }));
vi.mock("../lib/tagPhotoFlow", () => ({ tagPhotoWithValidation: tagMock }));
vi.mock("../lib/useUserPrefs", async (importOriginal) => ({ ...(await importOriginal<typeof import("../lib/useUserPrefs")>()), useUserPrefs: () => ({ model: "claude-sonnet-4-6", concurrency: 1 }) }));
vi.mock("@forensic/shared", async (importOriginal) => ({ ...(await importOriginal<typeof import("@forensic/shared")>()), compilePrompt: () => ({ joinedSystemPrompt: "test" }), resolveValidationVocabulary: () => null, aiAnalysisToSuggestions: () => [] }));

const makePhoto = (id: string, caption: string | null = null): any => ({
  id, sequenceNumber: 1, timestamp: "2025-01-01T00:00:00Z", imageFilename: `${id}.jpg`, thumbnailFilename: null,
  floorPlanID: null, localXFeet: null, localYFeet: null, planPixelX: null, planPixelY: null, headingDegrees: null,
  positionSource: "none", groupID: null, isPrimary: false, cameraZoom: 1, lensName: null, flashMode: "auto",
  aiDescription: null, aiSeverity: null, aiObservation: null, aiFollowUp: null, aiAnalysis: null, tags: [], pendingSuggestions: [],
  bucketID: null, markupOverlayFilename: null, markupDrawingFilename: null, reshootsPhotoID: null, isFavorite: false, trashedAt: null,
  userCaption: caption, userObservation: null, previewRotation: 0,
});
const makeProject = (photos: any[]): any => ({ id: "p", name: "P", createdAt: "2025-01-01T00:00:00Z", startedAt: null, lastResumedAt: null, lastStoppedAt: null, stopped: false, isDeleted: false, isFrozen: false, projectGPS: null, projectAddress: null, photos, trashedPhotos: [], floorPlans: [], activeFloorPlanID: null, folderName: null, aiInstructions: null, buckets: [], tagSelection: null, aiExtraVocabulary: null, manifestSchemaVersion: 3 });

beforeEach(() => { vi.clearAllMocks(); });
afterEach(() => { cleanup(); });

describe("web reliability regressions", () => {
  it("rebases a queued edit onto remote data acknowledged by the first save", async () => {
    const initial = makeProject([makePhoto("a"), makePhoto("b")]);
    let release!: (value: any) => void;
    apiMock.getProject.mockResolvedValue({ project: initial, revision: "r0" });
    apiMock.putProject.mockImplementationOnce((_id: string, p: any, _rev: string, base: any) => new Promise((resolve) => { release = () => resolve({ project: mergeManifest(base, makeProject([makePhoto("a", "remote"), makePhoto("b")]), p).merged, revision: "r1" }); })).mockResolvedValueOnce((_id: string, p: any, _rev: string, base: any) => ({ project: mergeManifest(base, makeProject([makePhoto("a", "remote"), makePhoto("b")]), p).merged, revision: "r2" }));
    const { result } = renderHook(() => useProjectManifest("p"));
    await waitFor(() => expect(result.current.project).not.toBeNull());
    act(() => result.current.save(makeProject([makePhoto("a"), makePhoto("b", "local")] )));
    act(() => result.current.save(makeProject([makePhoto("a"), makePhoto("b", "local-2")] )));
    await act(async () => { release({}); await Promise.resolve(); });
    await waitFor(() => expect(apiMock.putProject).toHaveBeenCalledTimes(2));
    const final = apiMock.putProject.mock.calls[1]![1];
    expect(final.photos[0].userCaption).toBe("remote");
    expect(final.photos[1].userCaption).toBe("local-2");
  });

  it("saveAndWait resolves only after the server acknowledges the write", async () => {
    const initial = makeProject([makePhoto("a")]);
    let release!: (value: any) => void;
    apiMock.getProject.mockResolvedValue({ project: initial, revision: "r0" });
    apiMock.putProject.mockImplementation(() => new Promise((resolve) => { release = resolve; }));
    const { result } = renderHook(() => useProjectManifest("p"));
    await waitFor(() => expect(result.current.project).not.toBeNull());
    let finished = false;
    let promise!: Promise<void>;
    act(() => { promise = result.current.saveAndWait(makeProject([makePhoto("a", "new")])); });
    await Promise.resolve();
    expect(finished).toBe(false);
    promise.then(() => { finished = true; });
    await act(async () => { release({ project: makeProject([makePhoto("a", "new")]), revision: "r1" }); await promise; });
    expect(finished).toBe(true);
  });

  it("retains the newest pending snapshot when the network save fails", async () => {
    const initial = makeProject([makePhoto("a")]);
    apiMock.getProject.mockResolvedValue({ project: initial, revision: "r0" });
    apiMock.putProject.mockRejectedValueOnce(new Error("offline")).mockResolvedValueOnce({ project: makeProject([makePhoto("a", "newest")]), revision: "r1" });
    const { result } = renderHook(() => useProjectManifest("p"));
    await waitFor(() => expect(result.current.project).not.toBeNull());
    act(() => result.current.save(makeProject([makePhoto("a", "newest")] )));
    await waitFor(() => expect(result.current.status.kind).toBe("error"));
    act(() => result.current.save(makeProject([makePhoto("a", "newest")] )));
    await waitFor(() => expect(apiMock.putProject).toHaveBeenCalledTimes(2));
    expect(apiMock.putProject.mock.calls[1]![1].photos[0].userCaption).toBe("newest");
  });

  it("retries IDs whose thumbnail request was cancelled by a filter change", async () => {
    const first = Promise.resolve({ urls: { A: "thumb-a" } });
    let calls = 0;
    apiMock.getPhotoUrlsBatch.mockImplementation(() => { calls += 1; return calls === 1 ? first : Promise.resolve({ urls: { A: "thumb-a" } }); });
    const pA = makePhoto("A");
    const pB = makePhoto("B");
    const props: any = { projectId: "p", project: makeProject([pA, pB]), photos: [pA, pB], canEdit: true, selectMode: false, selectedIds: new Set(), onOpen: vi.fn(), onOpenEditor: vi.fn(), onPhotoUpdated: vi.fn(), onToggleSelected: vi.fn() };
    const view = render(<PhotoList {...props} />);
    view.rerender(<PhotoList {...props} photos={[pA]} />);
    await waitFor(() => expect(apiMock.getPhotoUrlsBatch).toHaveBeenCalledTimes(2));
    expect(view.container.querySelector('img[src="thumb-a"]')).not.toBeNull();
  });

  it("batch AI checkpoints preserve late manual fields and await save acknowledgement", async () => {
    const photo = makePhoto("A");
    const initial = makeProject([photo]);
    let releaseAI!: () => void;
    let releaseSave!: () => void;
    tagMock.mockImplementation(() => new Promise((resolve) => { releaseAI = () => resolve({ analysis: { photoID: "A", parseFailed: false, reviewerFlag: "", validationErrors: [] } }); }));
    apiMock.getTagLibraryConfig.mockResolvedValue({ value: { contexts: [] } });
    apiMock.getAIRulesTemplateConfig.mockResolvedValue({ value: { text: "" } });
    const projectRef = { current: initial } as MutableRefObject<any>;
    const revisionRef = { current: "r0" } as MutableRefObject<string | null>;
    let saved: any;
    const saveAndWait = vi.fn((next: any) => { saved = next; return new Promise<void>((resolve) => { releaseSave = resolve; }); });
    const { result } = renderHook(() => useBatchRetag({ projectId: "p", projectRef, revisionRef, setProject: (next) => { projectRef.current = next; }, setRevision: vi.fn(), save: vi.fn(), saveAndWait }));
    const run = result.current.start({ model: "claude-sonnet-4-6", skipAlreadyTagged: false, concurrency: 1 });
    await waitFor(() => expect(tagMock).toHaveBeenCalled());
    projectRef.current = makeProject([{ ...photo, userCaption: "manual", isFavorite: true, bucketID: "bucket-manual" }]);
    releaseAI();
    await waitFor(() => expect(saveAndWait).toHaveBeenCalled());
    expect(saved.photos[0].userCaption).toBe("manual");
    expect(saved.photos[0].isFavorite).toBe(true);
    expect(saved.photos[0].bucketID).toBe("bucket-manual");
    let completed = false;
    void run.then(() => { completed = true; });
    await Promise.resolve();
    expect(completed).toBe(false);
    releaseSave();
    await run;
    expect(completed).toBe(true);
  });

  it("moves focus into a modal and restores it after Escape", async () => {
    const trigger = document.createElement("button");
    trigger.textContent = "Open";
    document.body.appendChild(trigger);
    trigger.focus();
    const view = render(<Modal title="Test dialog" onClose={() => view.unmount()}><button>Close</button></Modal>);
    await waitFor(() => expect(document.activeElement?.textContent).toBe("Close"));
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
    await waitFor(() => expect(document.activeElement).toBe(trigger));
    trigger.remove();
  });

  it("does not restore stale AI fields on skipped photos", async () => {
    const tagged = { ...makePhoto("B"), tags: [{ label: "Reviewed" }] };
    const projectRef = { current: makeProject([makePhoto("A"), tagged]) };
    let releaseAI!: (value: unknown) => void;
    tagMock.mockImplementation(() => new Promise(resolve => { releaseAI = resolve; }));
    apiMock.getTagLibraryConfig.mockResolvedValue({ value: { contexts: [] } });
    apiMock.getAIRulesTemplateConfig.mockResolvedValue({ value: { text: "" } });
    const saveAndWait = vi.fn(async (next: any) => { projectRef.current = next; });
    const { result } = renderHook(() => useBatchRetag({ projectId: "p", projectRef, revisionRef: { current: "r0" }, setProject: vi.fn(), setRevision: vi.fn(), saveAndWait }));
    let run!: Promise<void>;
    act(() => { run = result.current.start({ model: "claude-sonnet-4-6", skipAlreadyTagged: true, concurrency: 1 }); });
    await waitFor(() => expect(tagMock).toHaveBeenCalledTimes(1));
    const reviewed = { ...tagged, aiAnalysis: { reviewerFlag: "Reviewed manually" }, pendingSuggestions: [{ label: "Keep this review", parentTag: null }] };
    projectRef.current = makeProject([makePhoto("A"), reviewed]);
    await act(async () => { releaseAI({ analysis: { photoID: "A", parseFailed: false } }); await run; });
    expect(projectRef.current.photos[1]).toEqual(reviewed);
  });

  it("discards an AI result when the source image changed while it was running", async () => {
    const projectRef = { current: makeProject([makePhoto("A")]) };
    let releaseAI!: (value: unknown) => void;
    tagMock.mockImplementation(() => new Promise(resolve => { releaseAI = resolve; }));
    apiMock.getTagLibraryConfig.mockResolvedValue({ value: { contexts: [] } });
    apiMock.getAIRulesTemplateConfig.mockResolvedValue({ value: { text: "" } });
    const saveAndWait = vi.fn(async () => {});
    const { result } = renderHook(() => useBatchRetag({ projectId: "p", projectRef, revisionRef: { current: "r0" }, setProject: vi.fn(), setRevision: vi.fn(), saveAndWait }));
    let run!: Promise<void>;
    act(() => { run = result.current.start({ model: "claude-sonnet-4-6", skipAlreadyTagged: false, concurrency: 1 }); });
    await waitFor(() => expect(tagMock).toHaveBeenCalledTimes(1));
    projectRef.current = makeProject([{ ...makePhoto("A"), imageFilename: "replacement.jpg" }]);
    await act(async () => { releaseAI({ analysis: { photoID: "A", parseFailed: false } }); await run; });
    expect(saveAndWait).not.toHaveBeenCalled();
    expect(result.current.state.failedCount).toBe(1);
    expect(projectRef.current.photos[0].aiAnalysis).toBeNull();
  });

  it("selection tagging uses the shared save coordinator and waits before showing complete", async () => {
    const project = makeProject([makePhoto("A"), { ...makePhoto("B"), sequenceNumber: 2 }]);
    const projectRef = { current: project };
    let releaseSave!: () => void;
    const saveAndWait = vi.fn(() => new Promise<void>(resolve => { releaseSave = resolve; }));
    const manifest: any = { project, projectRef, revisionRef: { current: "r0" }, setProject: vi.fn(), setRevision: vi.fn(), save: vi.fn(), saveAndWait };
    apiMock.getPhotoUrlsBatch.mockResolvedValue({ urls: {} });
    apiMock.getTagLibraryConfig.mockResolvedValue({ value: { contexts: [] } });
    apiMock.getAIRulesTemplateConfig.mockResolvedValue({ value: { text: "" } });
    tagMock.mockResolvedValue({ analysis: { photoID: "A", parseFailed: false } });
    const view = render(<PhotosTab projectId="p" manifest={manifest} canEdit />);
    act(() => view.getByRole("button", { name: "Select" }).click());
    act(() => view.getByRole("checkbox", { name: "Select photo 1" }).click());
    act(() => view.getByRole("button", { name: "Re-tag with AI" }).click());
    act(() => view.getByRole("button", { name: "Start" }).click());
    await waitFor(() => expect(saveAndWait).toHaveBeenCalledTimes(1));
    expect(tagMock).toHaveBeenCalledTimes(1);
    expect(tagMock.mock.calls[0]![0].photoId).toBe("A");
    expect(apiMock.putProject).not.toHaveBeenCalled();
    expect(view.queryByText(/Batch complete/)).toBeNull();
    await act(async () => { releaseSave(); });
    await waitFor(() => expect(view.getByText(/Batch complete/)).not.toBeNull());
  });

  it("keeps a visible save error if the project revision disappears before the final checkpoint", async () => {
    const projectRef = { current: makeProject([makePhoto("A")]) };
    const revisionRef = { current: "r0" } as MutableRefObject<string | null>;
    let releaseAI!: (value: unknown) => void;
    tagMock.mockImplementation(() => new Promise(resolve => { releaseAI = resolve; }));
    apiMock.getTagLibraryConfig.mockResolvedValue({ value: { contexts: [] } });
    apiMock.getAIRulesTemplateConfig.mockResolvedValue({ value: { text: "" } });
    const saveAndWait = vi.fn(async () => {});
    const { result } = renderHook(() => useBatchRetag({ projectId: "p", projectRef, revisionRef, setProject: vi.fn(), setRevision: vi.fn(), saveAndWait }));
    let run!: Promise<void>;
    act(() => { run = result.current.start({ model: "claude-sonnet-4-6", skipAlreadyTagged: false, concurrency: 1 }); });
    await waitFor(() => expect(tagMock).toHaveBeenCalledTimes(1));
    revisionRef.current = null;
    await act(async () => { releaseAI({ analysis: { photoID: "A", parseFailed: false } }); await run; });
    expect(saveAndWait).not.toHaveBeenCalled();
    expect(result.current.state.kind).toBe("error");
    expect(result.current.state.errorMessage).toContain("AI results were not saved");
  });

  it("keeps an incomplete folder export visibly incomplete until partial download is chosen", async () => {
    const manifest: any = { projectName: "Case", revision: "reviewed-r7", buckets: [], unbucketedFolderName: "Unbucketed", plans: [], photos: [
      { id: "A", filename: "a.jpg", sequenceNumber: 1, timestamp: "2025-01-01", bucketId: null, userCaption: null, userObservation: null, aiSummary: null, tags: [], presignedUrl: "ok", sizeBytes: 5 },
      { id: "B", filename: "b.jpg", sequenceNumber: 2, timestamp: "2025-01-01", bucketId: null, userCaption: null, userObservation: null, aiSummary: null, tags: [], presignedUrl: "missing", sizeBytes: 5 },
    ] };
    apiMock.getFolderExportManifest.mockResolvedValue({ manifest });
    vi.stubGlobal("fetch", vi.fn(async (url: string) => url === "missing" ? { ok: false, status: 503 } : { ok: true, blob: async () => new window.Blob(["image"]) }));
    vi.stubGlobal("URL", { createObjectURL: vi.fn(() => "blob:test"), revokeObjectURL: vi.fn() });
    const view = render(<FolderExportClient projectId="p" canExport photoCount={2} />);
    await act(async () => { view.getByRole("button", { name: /download folder/i }).click(); });
    await waitFor(() => expect(view.getByText(/Incomplete: 1 of 2/)).not.toBeNull());
    expect(view.queryByText(/Complete export/)).toBeNull();
    const partial = view.getByRole("button", { name: /download partial zip/i });
    expect(partial).not.toBeNull();
    expect(URL.createObjectURL).not.toHaveBeenCalled();
    await act(async () => { partial.click(); });
    await waitFor(() => expect(URL.createObjectURL).toHaveBeenCalledTimes(1));
    expect(document.querySelector("a")?.download).toContain("INCOMPLETE export");
    const blob = vi.mocked(URL.createObjectURL).mock.calls[0]![0] as Blob;
    const zip = await JSZip.loadAsync(blob);
    const receipt = await zip.file("EXPORT_STATUS.txt")!.async("string");
    expect(receipt).toContain("INCOMPLETE — PARTIAL EXPORT");
    expect(receipt).toContain("Manifest revision: reviewed-r7");
    expect(receipt).toContain("Missing: b.jpg (B)");
    expect(view.queryByText(/Complete export/)).toBeNull();
  });

  it("reports a complete folder export when every asset downloads", async () => {
    const manifest: any = { projectName: "Case", buckets: [], unbucketedFolderName: "Unbucketed", plans: [], attachments: [{ id: "m1", photoId: "A", kind: "markup_png", filename: "mark.png", presignedUrl: "markup", sizeBytes: 10 }], photos: [{ id: "A", filename: "a.jpg", sequenceNumber: 1, timestamp: "2025-01-01", bucketId: null, userCaption: null, userObservation: null, aiSummary: null, tags: [], presignedUrl: "ok", sizeBytes: 5 }] };
    apiMock.getFolderExportManifest.mockResolvedValue({ manifest });
    vi.stubGlobal("fetch", vi.fn(async (url: string) => ({ ok: true, blob: async () => new window.Blob([url === "markup" ? "0123456789" : "image"]) })));
    vi.stubGlobal("URL", { createObjectURL: vi.fn(() => "blob:test"), revokeObjectURL: vi.fn() });
    const view = render(<FolderExportClient projectId="p" canExport photoCount={1} />);
    await act(async () => { view.getAllByRole("button", { name: /download folder/i }).at(-1)!.click(); });
    await waitFor(() => expect(view.getByText(/Complete export: 2 \/ 2/)).not.toBeNull());
  });

  it.each([
    ["photo", undefined],
    ["photo", 0],
    ["plan", undefined],
    ["plan", 0],
  ])("keeps a %s with %s sizeBytes incomplete before fetching", async (kind, sizeBytes) => {
    const asset: any = { id: "A", filename: `${kind}.bin`, presignedUrl: "asset", sizeBytes, sequenceNumber: 1, timestamp: "2025-01-01", tags: [] };
    const manifest: any = {
      projectName: "Case", buckets: [], unbucketedFolderName: "Unbucketed",
      plans: kind === "plan" ? [asset] : [], photos: kind === "photo" ? [asset] : [],
    };
    apiMock.getFolderExportManifest.mockResolvedValue({ manifest });
    const fetchMock = vi.fn(async () => ({ ok: true, blob: async () => new window.Blob(["asset"]) }));
    vi.stubGlobal("fetch", fetchMock);
    const view = render(<FolderExportClient projectId="p" canExport photoCount={1} />);
    await act(async () => { view.getByRole("button", { name: /download folder/i }).click(); });
    await waitFor(() => expect(view.getByText(/Incomplete: 0 of 1/)).not.toBeNull());
    expect(view.queryByText(/Complete export/)).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
