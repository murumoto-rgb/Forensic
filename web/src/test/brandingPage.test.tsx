import { act, cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AdminReportBrandingPage } from "../pages/AdminReportBrandingPage";

const mocks = vi.hoisted(() => ({ config: vi.fn(), logo: vi.fn(), upload: vi.fn(), convert: vi.fn(), session: vi.fn() }));
vi.mock("../lib/api", () => ({
  api: { getReportBrandingConfig: mocks.config, getBrandingLogo: mocks.logo, uploadBrandingLogo: mocks.upload },
  ApiError: class extends Error {},
}));
vi.mock("../lib/supabase", () => ({ signOutLocal: vi.fn(), supabase: { auth: { getSession: mocks.session } } }));
vi.mock("../lib/brandingLogo", () => ({ brandingLogoData: mocks.convert }));
const oldKey = "branding/old.png";
const oldURL = "https://example.invalid/old-logo.png";
const newImage = "data:image/png;base64,aW1hZ2U=";
const session: any = { user: { id: "owner", email: "owner@example.invalid" } };
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}
beforeEach(() => {
  vi.resetAllMocks();
  mocks.config.mockResolvedValue({ value: { titleOverride: null, subtitleOverride: null, footerOverride: null, logoStoragePath: oldKey }, revision: "r1" });
  mocks.convert.mockResolvedValue(newImage);
  mocks.session.mockResolvedValue({ data: { session: { ...session, access_token: "synthetic-token" } } });
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe("branding draft preview", () => {
  it("blocks publication during upload and restores the saved preview when changes are discarded", async () => {
    mocks.logo.mockResolvedValue({ objectKey: oldKey, url: oldURL });
    const upload = deferred<{ objectKey: string }>();
    mocks.upload.mockReturnValue(upload.promise);
    const view = render(<MemoryRouter><AdminReportBrandingPage session={session} /></MemoryRouter>);
    await waitFor(() => expect(view.getByAltText("Report logo preview").getAttribute("src")).toBe(oldURL));
    fireEvent.change(view.container.querySelector('input[type="file"]')!, { target: { files: [new File(["test"], "new.png", { type: "image/png" })] } });
    await waitFor(() => expect(mocks.upload).toHaveBeenCalledTimes(1));
    expect(view.getByRole("button", { name: "Save" }).matches(":disabled")).toBe(true);
    await act(async () => { upload.resolve({ objectKey: "branding/new.png" }); });
    await waitFor(() => expect(view.getByAltText("Report logo preview").getAttribute("src")).toBe(newImage));
    fireEvent.click(view.getByRole("button", { name: "Discard changes" }));
    expect(view.getByAltText("Report logo preview").getAttribute("src")).toBe(oldURL);
    expect(view.getByText(oldKey)).not.toBeNull();
  });

  it("does not replace a newly chosen preview with a late saved-logo response", async () => {
    const initial = deferred<{ objectKey: string; url: string }>();
    mocks.logo.mockReturnValue(initial.promise);
    mocks.upload.mockResolvedValue({ objectKey: "branding/new.png" });
    const view = render(<MemoryRouter><AdminReportBrandingPage session={session} /></MemoryRouter>);
    await waitFor(() => expect(view.getByRole("button", { name: "Upload logo" })).not.toBeNull());
    fireEvent.change(view.container.querySelector('input[type="file"]')!, { target: { files: [new File(["test"], "new.png", { type: "image/png" })] } });
    await waitFor(() => expect(view.getByAltText("Report logo preview").getAttribute("src")).toBe(newImage));
    await act(async () => { initial.resolve({ objectKey: oldKey, url: oldURL }); });
    expect(view.getByAltText("Report logo preview").getAttribute("src")).toBe(newImage);
    fireEvent.click(view.getByRole("button", { name: "Discard changes" }));
    expect(view.getByAltText("Report logo preview").getAttribute("src")).toBe(oldURL);
  });

  it("retains the newly saved logo when the initial download completes after publication", async () => {
    const initial = deferred<{ objectKey: string; url: string }>();
    mocks.logo.mockReturnValue(initial.promise);
    mocks.upload.mockResolvedValue({ objectKey: "branding/new.png" });
    const publish = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ revision: "r2" }) });
    vi.stubGlobal("fetch", publish);
    const view = render(<MemoryRouter><AdminReportBrandingPage session={session} /></MemoryRouter>);
    await waitFor(() => expect(view.getByRole("button", { name: "Upload logo" })).not.toBeNull());
    fireEvent.change(view.container.querySelector('input[type="file"]')!, { target: { files: [new File(["test"], "new.png", { type: "image/png" })] } });
    await waitFor(() => expect(view.getByAltText("Report logo preview").getAttribute("src")).toBe(newImage));
    fireEvent.click(view.getByRole("button", { name: "Save" }));
    await waitFor(() => expect(view.getByText(/^Saved ·/)).not.toBeNull());
    expect(JSON.parse(publish.mock.calls[0]![1].body).value.logoStoragePath).toBe("branding/new.png");
    await act(async () => { initial.resolve({ objectKey: oldKey, url: oldURL }); });
    fireEvent.change(view.getByRole("textbox", { name: "Title override" }), { target: { value: "Discard this edit" } });
    fireEvent.click(view.getByRole("button", { name: "Discard changes" }));
    expect(view.getByAltText("Report logo preview").getAttribute("src")).toBe(newImage);
    expect(view.getByText("branding/new.png")).not.toBeNull();
  });
});
