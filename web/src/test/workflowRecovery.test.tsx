import { act, cleanup, fireEvent, render, renderHook, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ProjectSchema, type Project } from "@forensic/shared";
import { useProjectManifest } from "../lib/useProjectManifest";
import { InfoTab } from "../components/workspace/InfoTab";
import { Modal } from "../components/Modal";
import { ProjectListPage } from "../pages/ProjectListPage";

const { apiMock } = vi.hoisted(() => ({ apiMock: { getProject: vi.fn(), putProject: vi.fn(), restoreProjectVersion: vi.fn(), getProjectHealth: vi.fn(), listProjectVersions: vi.fn(), getProjectVersion: vi.fn(), getWorkflowLibrary: vi.fn(), putWorkflowLibrary: vi.fn(), getMe: vi.fn(), listProjects: vi.fn(), searchProjects: vi.fn() } }));
vi.mock("../lib/api", () => ({ api: apiMock, ApiError: class ApiError extends Error { status = 500; errorCode = "test"; } }));
vi.mock("../lib/supabase", () => ({ signOutLocal: vi.fn() }));
const id = "10000000-0000-4000-8000-000000000001";
function project(overrides: Partial<Project> = {}): Project {
  return ProjectSchema.parse({ id, name: "Current project", createdAt: "2026-08-01T00:00:00Z", stopped: false, photos: [], trashedPhotos: [], floorPlans: [], buckets: [], manifestSchemaVersion: 4, ...overrides });
}
const initial = project();
const version = { id: "version-1", revision: "old", createdAt: "2026-08-01T00:00:00Z", photoCount: 0, planCount: 0, restorable: true, missingAssetCount: 0 };
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (reason: unknown) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function Details() { const manifest = useProjectManifest(id); return <InfoTab projectId={id} manifest={manifest} canEdit={!manifest.restoring} />; }
const renderDetails = () => render(<MemoryRouter><Details /></MemoryRouter>);
const renderList = () => render(<MemoryRouter><ProjectListPage session={{ user: { email: "test@example.com" } } as any} /></MemoryRouter>);
beforeEach(() => {
  vi.resetAllMocks();
  apiMock.getProject.mockResolvedValue({ project: initial, revision: "r0", role: "editor", isOwner: true });
  apiMock.getMe.mockResolvedValue({ isAdmin: false });
  apiMock.listProjects.mockResolvedValue({ projects: [] });
  apiMock.getWorkflowLibrary.mockResolvedValue({ library: { savedSearches: [], inspectionPresets: [] }, revision: "w0" });
  apiMock.getProjectHealth.mockResolvedValue({ assets: [], available: 0, expected: 0, missing: 0, checkedAt: "2026-08-30T00:00:00Z" });
  apiMock.listProjectVersions.mockResolvedValue({ versions: [version] });
  apiMock.getProjectVersion.mockResolvedValue({ version, project: project({ name: "Historical project" }) });
  apiMock.putProject.mockImplementation(async (_id, next) => ({ project: next, revision: "r1" }));
});
afterEach(cleanup);

describe("atomic project restore", () => {
  it("uses the restored manifest and revision as the base of the next edit", async () => {
    const restored = project({ name: "Historical project", projectAddress: "Restored address" });
    apiMock.restoreProjectVersion.mockResolvedValue({ project: restored, revision: "restored-revision" });
    const { result } = renderHook(() => useProjectManifest(id));
    await waitFor(() => expect(result.current.project).toBe(initial));
    await act(async () => result.current.restoreVersion(version.id, { project: result.current.project!, revision: result.current.revision! }));
    const edit = { ...result.current.project!, name: "Edited after restore" };
    await act(async () => result.current.saveAndWait(edit));
    expect(apiMock.putProject).toHaveBeenCalledWith(id, edit, "restored-revision", restored);
    expect(result.current.projectRef.current).toEqual(edit);
    expect(result.current.revisionRef.current).toBe("r1");
  });
  it("refuses restore and reload while a save is pending without losing the edit", async () => {
    const saving = deferred<any>(); apiMock.putProject.mockReturnValue(saving.promise);
    const { result } = renderHook(() => useProjectManifest(id));
    await waitFor(() => expect(result.current.project).toBe(initial));
    const review = { project: initial, revision: "r0" };
    const edit = { ...initial, name: "Unsaved name" };
    let saved!: Promise<void>;
    act(() => { saved = result.current.saveAndWait(edit); });
    await expect(result.current.restoreVersion(version.id, review)).rejects.toThrow(/pending saves/);
    await act(async () => result.current.reload());
    expect(apiMock.restoreProjectVersion).not.toHaveBeenCalled(); expect(apiMock.getProject).toHaveBeenCalledTimes(1);
    expect(result.current.project).toBe(edit);
    await act(async () => { saving.resolve({ project: edit, revision: "r1" }); await saved; });
  });
  it("serializes restore against new saves and rejects stale review snapshots", async () => {
    const restoring = deferred<any>(); apiMock.restoreProjectVersion.mockReturnValue(restoring.promise);
    const { result } = renderHook(() => useProjectManifest(id));
    await waitFor(() => expect(result.current.project).toBe(initial));
    await expect(result.current.restoreVersion(version.id, { project: { ...initial }, revision: "r0" })).rejects.toThrow(/changed after this preview/);
    let restored!: Promise<void>;
    act(() => { restored = result.current.restoreVersion(version.id, { project: initial, revision: "r0" }); });
    await expect(result.current.saveAndWait({ ...initial, name: "Concurrent" })).rejects.toThrow(/finish before editing/);
    expect(apiMock.putProject).not.toHaveBeenCalled(); expect(result.current.project).toBe(initial);
    await act(async () => { restoring.resolve({ project: project({ name: "Restored" }), revision: "r2" }); await restored; });
    expect(result.current.restoring).toBe(false);
  });
});

describe("visible workflow and recovery failures", () => {
  it("edits an existing preset without mutating the manifest", async () => {
    const preset = { id: "preset", name: "Original", projectNamePrefix: "Prefix", projectAddress: "Address", aiInstructions: "Rules", tagSelection: null, aiExtraVocabulary: null, buckets: [], checklist: ["Roof"], reportLayout: { perPage: 6, groupByBucket: false, includeMetadataTable: false } };
    apiMock.getWorkflowLibrary.mockResolvedValue({ revision: "w7", library: { savedSearches: [], inspectionPresets: [preset] } });
    apiMock.putWorkflowLibrary.mockResolvedValue({ revision: "w8" });
    const view = renderDetails();
    fireEvent.click(await view.findByRole("button", { name: "Edit" }));
    const names = view.getAllByLabelText("Preset name") as HTMLInputElement[];
    fireEvent.change(names[names.length - 1]!, { target: { value: "Renamed" } });
    fireEvent.change(view.getByLabelText("Required views"), { target: { value: "Roof\nAttic" } });
    fireEvent.click(view.getByRole("button", { name: "Save changes" }));
    await waitFor(() => expect(apiMock.putWorkflowLibrary).toHaveBeenCalled());
    const request = apiMock.putWorkflowLibrary.mock.calls[0]![0];
    expect(request.expectedRevision).toBe("w7"); expect(request.library.inspectionPresets[0]).toEqual({ ...preset, name: "Renamed", checklist: ["Roof", "Attic"] }); expect(apiMock.putProject).not.toHaveBeenCalled();
  });
  it("keeps the preset editor draft and shows a visible CAS failure", async () => {
    const preset = { id: "preset", name: "Original", projectNamePrefix: "", projectAddress: null, aiInstructions: null, tagSelection: null, aiExtraVocabulary: null, buckets: [], checklist: ["Roof"], reportLayout: { perPage: 6, groupByBucket: false, includeMetadataTable: false } };
    apiMock.getWorkflowLibrary.mockResolvedValue({ revision: "w7", library: { savedSearches: [], inspectionPresets: [preset] } });
    apiMock.putWorkflowLibrary.mockRejectedValue(new Error("CAS conflict"));
    const view = renderDetails(); fireEvent.click(await view.findByRole("button", { name: "Edit" }));
    const name = view.getAllByLabelText("Preset name").at(-1)! as HTMLInputElement; fireEvent.change(name, { target: { value: "Draft rename" } }); fireEvent.click(view.getByRole("button", { name: "Save changes" }));
    expect(await view.findByText(/Preset was not saved/)).not.toBeNull(); expect(view.getByRole("dialog", { name: /Edit preset/ })).not.toBeNull(); expect((view.getAllByLabelText("Preset name").at(-1)! as HTMLInputElement).value).toBe("Draft rename");
    apiMock.getWorkflowLibrary.mockResolvedValue({ revision: "w8", library: { savedSearches: [], inspectionPresets: [{ ...preset, name: "Remote name", aiInstructions: "New remote instructions" }] } });
    fireEvent.click(view.getByRole("button", { name: "Reload saved library, keep draft" }));
    expect(await view.findByText(/Saved version after reload: Remote name/)).not.toBeNull();
    expect((view.getAllByLabelText("Preset name").at(-1)! as HTMLInputElement).value).toBe("Draft rename");
    expect(apiMock.putWorkflowLibrary).toHaveBeenCalledTimes(1);
    apiMock.putWorkflowLibrary.mockResolvedValue({ revision: "w9" });
    fireEvent.click(view.getByRole("button", { name: "Save changes" }));
    await waitFor(() => expect(apiMock.putWorkflowLibrary).toHaveBeenCalledTimes(2));
    expect(apiMock.putWorkflowLibrary.mock.calls[1]![0]).toMatchObject({ expectedRevision: "w8", library: { inspectionPresets: [{ ...preset, name: "Draft rename", aiInstructions: "New remote instructions" }] } });
  });
  it.each([{ role: "viewer", isFrozen: false, isOwner: false }, { role: "editor", isFrozen: true, isOwner: true }])("disables preset editing for $role with isFrozen=$isFrozen", async ({ role, isFrozen, isOwner }) => {
    apiMock.getProject.mockResolvedValue({ project: project({ isFrozen }), revision: "r0", role, isOwner });
    apiMock.getWorkflowLibrary.mockResolvedValue({ revision: "w7", library: { savedSearches: [], inspectionPresets: [{ id: "preset", name: "Original", projectNamePrefix: "", projectAddress: null, aiInstructions: null, tagSelection: null, aiExtraVocabulary: null, buckets: [], checklist: [], reportLayout: { perPage: 6, groupByBucket: false, includeMetadataTable: false } }] } });
    const view = renderDetails(); await view.findByRole("button", { name: "Edit" });
    expect((view.getByRole("button", { name: "Edit" }) as HTMLButtonElement).disabled).toBe(true);
  });
  it("renders Details from loading state and surfaces both health and history failures", async () => {
    apiMock.getProjectHealth.mockRejectedValue(new Error("storage offline"));
    apiMock.listProjectVersions.mockRejectedValue(new Error("history offline"));
    const view = renderDetails();
    fireEvent.click(await view.findByRole("button", { name: "Verify assets" }));
    expect(await view.findByText(/Asset verification failed: storage offline/)).not.toBeNull();
    expect(view.getByText(/Version history failed: history offline/)).not.toBeNull();
  });
  it("shows actual version changes, requires confirmation and preserves a failed restore preview", async () => {
    apiMock.restoreProjectVersion.mockRejectedValue(new Error("An asset is unavailable"));
    const view = renderDetails();
    fireEvent.click(await view.findByRole("button", { name: "Verify assets" }));
    fireEvent.click(await view.findByRole("button", { name: "Preview version" }));
    expect(await view.findByText(/Project name: Current project → Historical project/)).not.toBeNull();
    expect((view.getByRole("button", { name: "Confirm restore" }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(view.getByLabelText("I reviewed these changes and want to restore this version."));
    fireEvent.click(view.getByRole("button", { name: "Confirm restore" }));
    expect(await view.findByText(/Restore failed: An asset is unavailable/)).not.toBeNull();
    expect(view.getByRole("dialog", { name: "Review project version" })).not.toBeNull();
    expect(view.getByText(/Project name: Current project → Historical project/)).not.toBeNull();
    expect((view.getByPlaceholderText("Project name") as HTMLInputElement).value).toBe("Current project");
  });
  it("retains a preset name after a failed CAS and shows workflow-load errors", async () => {
    apiMock.putWorkflowLibrary.mockRejectedValue(new Error("Revision conflict"));
    const view = renderDetails();
    fireEvent.change(await view.findByLabelText("Preset name"), { target: { value: "Inspection setup" } });
    await waitFor(() => expect((view.getByRole("button", { name: "Save current setup" }) as HTMLButtonElement).disabled).toBe(false));
    fireEvent.click(view.getByRole("button", { name: "Save current setup" }));
    expect(await view.findByText(/Preset library was not saved: Revision conflict/)).not.toBeNull();
    expect((view.getByLabelText("Preset name") as HTMLInputElement).value).toBe("Inspection setup");
    apiMock.getWorkflowLibrary.mockRejectedValue(new Error("Library offline"));
    fireEvent.click(view.getByRole("button", { name: "Refresh preset library" }));
    expect(await view.findByText(/Could not load preset library: Library offline/)).not.toBeNull();
  });
  it("catches checklist failures and keeps a failed add draft", async () => {
    apiMock.putProject.mockRejectedValue(new Error("Offline"));
    const view = renderDetails();
    fireEvent.change(await view.findByLabelText("Required view"), { target: { value: "Roof overview" } });
    fireEvent.click(view.getByRole("button", { name: "Add" }));
    expect(await view.findByText(/Change not saved: Offline/)).not.toBeNull();
    expect((view.getByLabelText("Required view") as HTMLInputElement).value).toBe("Roof overview");
  });
  it("rejects preset apply after the reviewed project changed and supports 12-photo layout", async () => {
    apiMock.getWorkflowLibrary.mockResolvedValue({ revision: "w0", library: { savedSearches: [], inspectionPresets: [{ id: "preset", name: "Preset one", projectNamePrefix: "", projectAddress: null, aiInstructions: null, tagSelection: null, aiExtraVocabulary: null, buckets: [], checklist: ["Roof"], reportLayout: { perPage: 12, groupByBucket: true, includeMetadataTable: true } }] } });
    const view = renderDetails();
    fireEvent.change(await view.findByLabelText("Photos per page"), { target: { value: "12" } });
    await waitFor(() => expect(apiMock.putProject).toHaveBeenCalledTimes(1));
    expect(apiMock.putProject.mock.calls[0]![1].reportLayout.perPage).toBe(12);
    await waitFor(() => expect((view.getByLabelText("Photos per page") as HTMLSelectElement).disabled).toBe(false));
    fireEvent.click(view.getByRole("button", { name: "Preset one" }));
    fireEvent.change(view.getByPlaceholderText("Project name"), { target: { value: "Changed since preview" } });
    fireEvent.blur(view.getByPlaceholderText("Project name"));
    await waitFor(() => expect(apiMock.putProject).toHaveBeenCalledTimes(2));
    await waitFor(() => expect((view.getByRole("button", { name: "Apply preset" }) as HTMLButtonElement).disabled).toBe(false));
    fireEvent.click(view.getByRole("button", { name: "Apply preset" }));
    expect(await view.findByText(/The project changed after this preview/)).not.toBeNull();
    expect(apiMock.putProject).toHaveBeenCalledTimes(2);
  });
});

describe("search and modal safety", () => {
  it("ignores old search responses after a saved filter starts a newer request", async () => {
    const old = deferred<any>();
    apiMock.getWorkflowLibrary.mockResolvedValue({ revision: "w0", library: { inspectionPresets: [], savedSearches: [{ id: "saved", name: "Saved recent", filter: { query: "new", fromDate: null, toDate: null, favoritesOnly: false } }] } });
    apiMock.searchProjects.mockReturnValueOnce(old.promise).mockResolvedValueOnce({ hits: [{ projectId: id, projectName: "New result", timestamp: "now" }], nextOffset: null });
    const view = renderList();
    await view.findByRole("button", { name: "Saved recent" });
    fireEvent.change(view.getByLabelText("Query"), { target: { value: "old" } });
    fireEvent.click(view.getByRole("button", { name: "Search" }));
    fireEvent.click(view.getByRole("button", { name: "Saved recent" }));
    await view.findByText("New result");
    await act(async () => { old.resolve({ hits: [{ projectId: id, projectName: "Old result", timestamp: "old" }], nextOffset: null }); });
    expect(view.queryByText("Old result")).toBeNull(); expect(view.getByText("New result")).not.toBeNull();
  });
  it("preserves filter names on CAS failure and rejects reversed calendar ranges", async () => {
    apiMock.putWorkflowLibrary.mockRejectedValue(new Error("Revision conflict"));
    const view = renderList();
    await view.findByRole("button", { name: "Refresh saved filters" });
    fireEvent.change(view.getByLabelText("Filter name"), { target: { value: "Keep my name" } });
    fireEvent.click(view.getByRole("button", { name: "Save filter" }));
    expect(await view.findByText(/Saved filters were not changed: Revision conflict/)).not.toBeNull();
    expect((view.getByLabelText("Filter name") as HTMLInputElement).value).toBe("Keep my name");
    fireEvent.change(view.getByLabelText("From"), { target: { value: "2026-08-30" } });
    fireEvent.change(view.getByLabelText("To"), { target: { value: "2026-08-01" } });
    fireEvent.click(view.getByRole("button", { name: "Search" }));
    expect(view.getByText(/Enter valid calendar dates/)).not.toBeNull(); expect(apiMock.searchProjects).not.toHaveBeenCalled();
  });
  it("keeps Tab focus inside a dialog without controls and bounds viewport height", () => {
    const view = render(<Modal title="Waiting" onClose={vi.fn()}><p>Please wait</p></Modal>);
    const dialog = view.getByRole("dialog");
    const tab = new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true });
    document.dispatchEvent(tab);
    expect(tab.defaultPrevented).toBe(true); expect(document.activeElement).toBe(dialog);
    expect(dialog.className).toContain("max-h-[calc(100dvh-2rem)]"); expect(dialog.className).toContain("overflow-y-auto");
  });
});
