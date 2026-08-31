import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
const apiMock = vi.hoisted(() => ({ requestUploadUrl: vi.fn(), commitUpload: vi.fn() }));
vi.mock("../lib/api", () => ({ api: apiMock, ApiError: class extends Error {} }));
import { uploadFile } from "../lib/uploadFile";
beforeEach(() => { vi.clearAllMocks(); apiMock.requestUploadUrl.mockResolvedValue({ uploadUrl: "https://storage.invalid/upload", objectKey: "project/photo/photo/unique", requiredHeaders: { "if-none-match": "*" } }); apiMock.commitUpload.mockResolvedValue({ ok: true }); });
afterEach(() => vi.unstubAllGlobals());
describe("immutable upload filename binding", () => {
  it("binds the actual manifest filename through issuance and commit, without leaking auth to storage", async () => {
    const fetcher = vi.fn().mockResolvedValue({ ok: true }); vi.stubGlobal("fetch", fetcher);
    const file = new File(["sample"], "camera-original-name.jpg", { type: "image/jpeg" });
    const key = await uploadFile({ projectId: "project", photoId: "photo", kind: "photo", sourceFilename: "manifest-photo-id.jpg", file, contentType: "image/jpeg" });
    expect(apiMock.requestUploadUrl).toHaveBeenCalledWith("project", expect.objectContaining({ sourceFilename: "manifest-photo-id.jpg", immutable: true }));
    expect(apiMock.commitUpload).toHaveBeenCalledWith("project", expect.objectContaining({ sourceFilename: "manifest-photo-id.jpg", immutable: true, objectKey: key }));
    expect(fetcher.mock.calls[0]?.[1].headers).toEqual({ "content-type": "image/jpeg", "if-none-match": "*" });
    expect(key).toBe("project/photo/photo/unique");
  });
  it("does not register evidence when its conditional upload fails", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 412, statusText: "Precondition Failed" }));
    await expect(uploadFile({ projectId: "project", photoId: "photo", kind: "markup_png", sourceFilename: "new-overlay.png", file: new Blob(["sample"]), contentType: "image/png" })).rejects.toThrow("412");
    expect(apiMock.commitUpload).not.toHaveBeenCalled();
  });
});
