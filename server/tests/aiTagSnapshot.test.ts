import Fastify, { type FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PhotoSchema, ProjectSchema } from "@forensic/shared";

const state = vi.hoisted(() => ({
  project: null as unknown,
  file: { object_key: "", source_filename: null as string | null },
  fields: [] as string[],
  reserve: vi.fn(), release: vi.fn(), read: vi.fn(), provider: vi.fn(), audit: vi.fn(),
}));
vi.mock("../src/env.js", () => ({ env: { ANTHROPIC_API_KEY: "synthetic-no-network", AI_MAX_OUTPUT_TOKENS: 4096 } }));
vi.mock("../src/access.js", () => ({ assertProjectAccess: vi.fn(async () => "editor"), sendAccessError: () => false }));
vi.mock("../src/sentry.js", () => ({ setRequestUser: () => undefined }));
vi.mock("../src/resourceLimits.js", () => ({ reserveAI: state.reserve, releaseAI: state.release }));
vi.mock("../src/r2.js", () => ({ getObjectBytes: state.read }));
vi.mock("../src/audit.js", () => ({ recordAITagAudit: state.audit }));
vi.mock("@anthropic-ai/sdk", () => ({ default: class {
  messages = { create: state.provider };
  static APIError = class extends Error {};
} }));
vi.mock("../src/supabase.js", () => ({
  verifyUserJWT: async () => ({ id: "33333333-3333-4333-8333-333333333333", email: "synthetic@example.invalid" }),
  supabaseAdmin: { from: (table: string) => {
    const q = {
      select: (fields: string) => { if (table === "current_project_files") state.fields.push(fields); return q; },
      eq: () => q, order: () => q, limit: () => q, abortSignal: () => q,
      maybeSingle: async () => {
        if (table === "projects") return { data: { manifest: state.project }, error: null };
        if (table === "current_project_files") return { data: state.file, error: null };
        throw new Error(`Unexpected table ${table}`);
      },
    };
    return q;
  } },
}));
import { aiTagRoute } from "../src/routes/aiTag.js";

const projectId = "11111111-1111-4111-8111-111111111111";
const photoId = "abcdefab-cdef-4abc-8def-abcdefabcdef";
const legacyKey = `${projectId}/${photoId}/photo`;
let app: FastifyInstance;
beforeEach(async () => {
  vi.clearAllMocks(); state.fields = [];
  state.project = ProjectSchema.parse({ id: projectId, name: "Captured manifest", createdAt: "2026-08-30T00:00:00Z", stopped: false,
    photos: [PhotoSchema.parse({ id: photoId, imageFilename: "snapshot.jpg", sequenceNumber: 1, timestamp: "2026-08-30T00:00:00Z", positionSource: "none", isPrimary: true, cameraZoom: 1, flashMode: "auto", tags: [], pendingSuggestions: [], isFavorite: false, previewRotation: 0 })],
    trashedPhotos: [], floorPlans: [], buckets: [], manifestSchemaVersion: 4 });
  state.file = { object_key: `${legacyKey}/44444444-4444-4444-8444-444444444444`, source_filename: "snapshot.jpg" };
  state.reserve.mockResolvedValue("synthetic-lease"); state.release.mockResolvedValue(undefined);
  state.read.mockResolvedValue(Buffer.from("synthetic-image")); state.audit.mockResolvedValue(undefined);
  state.provider.mockResolvedValue({ content: [{ type: "text", text: "synthetic-analysis" }], usage: { input_tokens: 1, output_tokens: 2 } });
  app = Fastify(); await app.register(aiTagRoute); await app.ready();
});
afterEach(async () => { await app.close(); });
const request = (requestedPhotoId = photoId) => app.inject({ method: "POST", url: "/v1/ai/tag-photo", headers: { authorization: "Bearer synthetic" },
  payload: { projectId, photoId: requestedPhotoId, model: "claude-sonnet-4-6", systemPrompt: "Describe evidence", userText: "photo_id: snapshot.jpg" } });

describe("AI evidence snapshot binding", () => {
  it.each([
    [photoId.toUpperCase(), photoId], // Swift manifest and iOS request.
    [photoId, photoId.toUpperCase()],
  ])("resolves manifest UUID %s from equivalent request UUID %s", async (manifestPhotoId, requestedPhotoId) => {
    const project = ProjectSchema.parse(state.project);
    project.photos[0]!.id = manifestPhotoId;
    state.project = project;
    state.file.object_key = legacyKey;
    const response = await request(requestedPhotoId);
    expect(response.statusCode, response.body).toBe(200);
    expect(response.json().rawText).toBe("synthetic-analysis");
    expect(state.read).toHaveBeenCalledExactlyOnceWith(legacyKey);
    expect(state.reserve).toHaveBeenCalledTimes(1);
    expect(state.provider).toHaveBeenCalledTimes(1);
    expect(state.release).toHaveBeenCalledTimes(1);
    expect(state.provider.mock.calls[0]![0].messages[0].content[1].text).toBe("photo_id: snapshot.jpg");
  });
  it.each(["replacement.png", null])("refuses current filename %s after reading a different manifest, without paid admission", async filename => {
    // The file view is read after the manifest; simulate a rename/restore in
    // between. Null is not a supported legacy fallback: 0017 backfills it.
    state.file.source_filename = filename;
    const response = await request();
    expect(response.statusCode, response.body).toBe(409);
    expect(response.json().error).toBe("revision_mismatch");
    expect(state.reserve).not.toHaveBeenCalled(); expect(state.provider).not.toHaveBeenCalled();
    expect(state.read).not.toHaveBeenCalled(); expect(state.audit).not.toHaveBeenCalled();
  });
  it.each([legacyKey, `${legacyKey}/44444444-4444-4444-8444-444444444444`])("uses the exact matching registered key %s without reconstructing it", async key => {
    state.file.object_key = key;
    const response = await request();
    expect(response.statusCode, response.body).toBe(200);
    expect(state.fields).toEqual(["object_key, source_filename"]);
    expect(response.json().rawText).toBe("synthetic-analysis");
    expect(state.read).toHaveBeenCalledExactlyOnceWith(key);
    expect(state.reserve).toHaveBeenCalledTimes(1); expect(state.release).toHaveBeenCalledTimes(1);
    expect(state.provider).toHaveBeenCalledTimes(1);
    const content = state.provider.mock.calls[0]![0].messages[0].content;
    expect(content[0].source.media_type).toBe("image/jpeg");
    expect(content[1].text).toBe("photo_id: snapshot.jpg");
  });
});
