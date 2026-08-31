import { beforeEach, describe, expect, it, vi } from "vitest";
import Fastify from "fastify";
const state = vi.hoisted(() => ({ key: null as string | null, put: vi.fn(), get: vi.fn(), bytes: vi.fn() }));
vi.mock("../src/supabase.js", () => ({
  verifyUserJWT: async (token: string) => ({ id: token, email: "synthetic@example.invalid" }),
  supabaseAdmin: { from: () => {
    const query = { select: () => query, eq: () => query, abortSignal: () => query,
      maybeSingle: async () => ({ data: { value: { logoStoragePath: state.key } }, error: null }) };
    return query;
  } },
}));
vi.mock("../src/access.js", () => ({ isOrgAdmin: async (user: string) => user === "owner" }));
vi.mock("../src/sentry.js", () => ({ setRequestUser: () => undefined }));
vi.mock("../src/r2.js", () => ({ putObjectBytes: state.put, presignedGet: state.get, getObjectBytes: state.bytes }));
import { brandingRoute } from "../src/routes/branding.js";
import { loadReportBrandingForExport } from "../src/reportBranding.js";
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4sAAAAASUVORK5CYII=";
beforeEach(() => { vi.clearAllMocks(); state.key = null; state.get.mockResolvedValue("https://storage.invalid/logo"); state.bytes.mockResolvedValue(Buffer.from(png, "base64")); });

describe("shared report logo", () => {
  it("requires admin for uploads and authentication for downloads", async () => {
    const app = Fastify(); await app.register(brandingRoute);
    expect((await app.inject({ method: "GET", url: "/v1/branding/logo" })).statusCode).toBe(401);
    expect((await app.inject({ method: "POST", url: "/v1/branding/logo", headers: { authorization: "Bearer viewer" }, payload: { pngBase64: png } })).statusCode).toBe(403);
    expect(state.put).not.toHaveBeenCalled(); await app.close();
  });
  it("stores an immutable branding asset without attaching it to any project or publishing config", async () => {
    const app = Fastify(); await app.register(brandingRoute);
    const result = await app.inject({ method: "POST", url: "/v1/branding/logo", headers: { authorization: "Bearer owner" }, payload: { pngBase64: png } });
    expect(result.statusCode).toBe(200);
    expect(result.json().objectKey).toMatch(/^branding\/owner\/[\da-f-]+\.png$/);
    expect(state.put).toHaveBeenCalledWith(expect.objectContaining({ objectKey: result.json().objectKey, ifNoneMatch: "*", contentType: "image/png" }));
    expect(state.key).toBeNull();
    expect((await app.inject({ method: "GET", url: "/v1/branding/logo", headers: { authorization: "Bearer owner" } })).statusCode).toBe(404);
    state.key = result.json().objectKey;
    const downloaded = await app.inject({ method: "GET", url: "/v1/branding/logo", headers: { authorization: "Bearer viewer" } });
    expect(downloaded.json().objectKey).toBe(state.key); await app.close();
  });
  it("rejects malformed logos and refuses a report with an unavailable configured logo", async () => {
    const app = Fastify(); await app.register(brandingRoute);
    const result = await app.inject({ method: "POST", url: "/v1/branding/logo", headers: { authorization: "Bearer owner" }, payload: { pngBase64: Buffer.from("not an image").toString("base64") } });
    expect(result.statusCode).toBe(400); expect(state.put).not.toHaveBeenCalled();
    state.key = "branding/owner/logo.png"; state.bytes.mockRejectedValue(new Error("missing logo"));
    await expect(loadReportBrandingForExport()).rejects.toThrow("missing logo"); await app.close();
  });
  it("uses the same persisted identity and logo bytes for a report snapshot", async () => {
    state.key = "branding/owner/logo.png";
    const result = await loadReportBrandingForExport();
    expect(result.logoDataUrl).toBe(`data:image/png;base64,${png}`);
    expect(state.bytes).toHaveBeenCalledWith(state.key, expect.objectContaining({ maxBytes: 1024 * 1024, timeoutMs: 10000 }));
  });
});
