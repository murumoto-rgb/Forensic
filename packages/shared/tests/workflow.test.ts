import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { ProjectSchema } from "../src/validation.js";
import { mergeManifest } from "../src/merge.js";
import { applyInspectionPreset, setInspectionSession, type InspectionPreset } from "../src/workflow.js";

const project = () => ProjectSchema.parse({
  id: "11111111-1111-4111-8111-111111111111", name: "Original inspection",
  createdAt: "2026-08-30T12:00:00Z", stopped: false,
  photos: [], trashedPhotos: [], floorPlans: [], buckets: [], manifestSchemaVersion: 3,
});
const preset: InspectionPreset = {
  id: "preset", name: "Envelope", projectNamePrefix: "Template",
  projectAddress: "Template address", aiInstructions: "Describe visible evidence only",
  tagSelection: null, aiExtraVocabulary: null,
  buckets: [{ id: "template-bucket", name: "Wall", colorHex: "#123456", sortOrder: 0, libraryCategoryID: null }],
  checklist: ["Overall view", "Close view"],
  reportLayout: { perPage: 4, groupByBucket: true, includeMetadataTable: true },
};

describe("inspection workflow safety", () => {
  it("loads an older project without inventing a completed visit or checklist", () => {
    const old = project();
    assert.deepEqual(old.inspectionChecklist, []);
    assert.deepEqual(old.inspectionSessions, []);
    assert.equal(old.reportLayout, null);
  });

  it("merges a checklist rename and completion on different devices", () => {
    const base = { ...project(), inspectionChecklist: [{ id: "view", label: "Wall", isComplete: false }] };
    const server = { ...base, inspectionChecklist: [{ ...base.inspectionChecklist[0]!, label: "North wall" }] };
    const client = { ...base, inspectionChecklist: [{ ...base.inspectionChecklist[0]!, isComplete: true }] };
    assert.deepEqual(mergeManifest(base, server, client).merged.inspectionChecklist,
      [{ id: "view", label: "North wall", isComplete: true }]);
  });

  it("keeps the prior visit when stopping and resuming, without duplicate start", () => {
    const started = setInspectionSession(project(), "start", "2026-08-30T12:00:00Z", () => "first");
    assert.strictEqual(setInspectionSession(started, "start"), started);
    const stopped = setInspectionSession(started, "stop", "2026-08-30T13:00:00Z");
    const resumed = setInspectionSession(stopped, "start", "2026-08-30T14:00:00Z", () => "second");
    assert.equal(resumed.inspectionSessions.length, 2);
    assert.equal(resumed.inspectionSessions[0]!.endedAt, "2026-08-30T13:00:00Z");
    assert.equal(resumed.inspectionSessions[1]!.endedAt, null);
    assert.equal(resumed.startedAt, started.startedAt);
  });

  it("does not resurrect a stopped visit when another device changes metadata", () => {
    const base = setInspectionSession(project(), "start", "2026-08-30T12:00:00Z", () => "first");
    const server = setInspectionSession(base, "stop", "2026-08-30T13:00:00Z");
    const client = { ...base, name: "Updated name" };
    const merged = mergeManifest(base, server, client).merged;
    assert.equal(merged.inspectionSessions[0]!.endedAt, "2026-08-30T13:00:00Z");
    assert.equal(merged.name, "Updated name");
  });

  it("applies setup without replacing evidence, existing address or bucket identity", () => {
    const original = { ...project(), projectAddress: "Actual site", buckets: [...preset.buckets] };
    let nextID = 0;
    const applied = applyInspectionPreset(original, preset, () => `new-${++nextID}`);
    assert.equal(applied.name, original.name);
    assert.equal(applied.projectAddress, "Actual site");
    assert.strictEqual(applied.photos, original.photos);
    assert.strictEqual(applied.floorPlans, original.floorPlans);
    assert.strictEqual(applied.trashedPhotos, original.trashedPhotos);
    assert.deepEqual(applied.buckets[0], original.buckets[0]);
    assert.notEqual(applied.buckets[1]!.id, original.buckets[0]!.id);
    assert.ok(applied.inspectionChecklist.every((item) => !item.isComplete));
    const repeat = applyInspectionPreset(applied, preset, () => `new-${++nextID}`);
    assert.equal(new Set(repeat.buckets.map((b) => b.id)).size, repeat.buckets.length);
  });

  it("rejects preset and lifecycle changes on finalized projects", () => {
    const frozen = { ...project(), isFrozen: true };
    assert.strictEqual(applyInspectionPreset(frozen, preset), frozen);
    assert.strictEqual(setInspectionSession(frozen, "start"), frozen);
    assert.strictEqual(setInspectionSession(frozen, "stop"), frozen);
  });
});
