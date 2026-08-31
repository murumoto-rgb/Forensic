/**
 * Tests for the deterministic 3-way manifest merge (Build #5.116.1).
 *
 * These lock in the properties the cloud-first flip depends on:
 *  - idempotence / convergence (`merge(b, X, X) === X`),
 *  - clean one-sided wins,
 *  - additive adds + base-aware deletes,
 *  - the soft-delete-vs-edit and tag-confidence rules,
 *  - the `base = server` additive first-sync (iOS migration safety).
 *
 * If you add a field to `Project`/`Photo`/etc., `mergeManifest` won't
 * compile until it has a rule — and the round-trip test below will
 * fail if that rule drops the field. Update both in the same PR.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { mergeManifest, deepEqual } from "../src/merge.js";
import type { Project, Photo, Tag } from "../src/manifest.js";

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

function photo(id: string, over: Partial<Photo> = {}): Photo {
  return {
    id,
    sequenceNumber: 1,
    timestamp: "2026-01-01T00:00:00Z",
    imageFilename: `${id}.jpg`,
    thumbnailFilename: `${id}.thumb.jpg`,
    floorPlanID: null,
    localXFeet: null,
    localYFeet: null,
    planPixelX: null,
    planPixelY: null,
    headingDegrees: null,
    positionSource: "none",
    groupID: null,
    isPrimary: false,
    cameraZoom: 1,
    lensName: null,
    flashMode: "auto",
    aiDescription: null,
    aiSeverity: null,
    aiObservation: null,
    aiFollowUp: null,
    aiAnalysis: null,
    tags: [],
    pendingSuggestions: [],
    bucketID: null,
    markupOverlayFilename: null,
    markupDrawingFilename: null,
    reshootsPhotoID: null,
    isFavorite: false,
    trashedAt: null,
    userCaption: null,
    userObservation: null,
    previewRotation: 0,
    ...over,
  };
}

function project(over: Partial<Project> = {}): Project {
  return {
    id: "proj-1",
    name: "Site A",
    createdAt: "2026-01-01T00:00:00Z",
    startedAt: null,
    lastResumedAt: null,
    lastStoppedAt: null,
    stopped: false,
    isDeleted: false,
    isFrozen: false,
    projectGPS: null,
    projectAddress: null,
    photos: [],
    trashedPhotos: [],
    floorPlans: [],
    activeFloorPlanID: null,
    folderName: null,
    aiInstructions: null,
    buckets: [],
    tagSelection: null,
    aiExtraVocabulary: null,
    inspectionChecklist: [], inspectionSessions: [], reportLayout: null,
    manifestSchemaVersion: 2,
    ...over,
  };
}

function tag(label: string, confidence = 1, parentTag: string | null = null): Tag {
  return { label, confidence, parentTag };
}

const clone = <T,>(x: T): T => JSON.parse(JSON.stringify(x)) as T;

// ---------------------------------------------------------------------------
// Determinism laws
// ---------------------------------------------------------------------------

describe("mergeManifest — laws", () => {
  it("idempotent: merge(base, X, X) === X", () => {
    const base = project();
    const x = project({
      name: "Site A — renamed",
      photos: [
        photo("p1", { userCaption: "crack", tags: [tag("Foundation"), tag("Cracking", 0.8, "Foundation")] }),
        photo("p2", { isFavorite: true }),
      ],
      trashedPhotos: [photo("p3", { trashedAt: "2026-02-01T00:00:00Z" })],
      buckets: [{ id: "b1", name: "Exterior", colorHex: "#fff", sortOrder: 0, libraryCategoryID: null }],
      tagSelection: { contextIDs: ["c1"], primariesByContext: { c1: ["pri"] }, deselectedSecondariesByPrimary: {} },
    });
    const { merged } = mergeManifest(base, clone(x), clone(x));
    assert.ok(deepEqual(merged, x), "merge of identical sides must equal that side");
  });

  it("client made no changes: merge(base, server, base) === server", () => {
    const base = project({ photos: [photo("p1", { userCaption: "old" })] });
    const server = project({
      name: "Renamed on server",
      photos: [photo("p1", { userCaption: "server edit" }), photo("p2")],
    });
    const { merged } = mergeManifest(clone(base), clone(server), clone(base));
    assert.ok(deepEqual(merged, server), "must adopt the server when client is unchanged");
  });

  it("server unchanged: merge(base, base, client) === client", () => {
    const base = project({ photos: [photo("p1")] });
    const client = project({
      name: "Renamed on client",
      photos: [photo("p1", { isFavorite: true }), photo("p2")],
    });
    const { merged } = mergeManifest(clone(base), clone(base), clone(client));
    assert.ok(deepEqual(merged, client), "must take the client when server is unchanged");
  });
});

// ---------------------------------------------------------------------------
// The core scenario: concurrent additive edits don't clobber
// ---------------------------------------------------------------------------

describe("mergeManifest — concurrent edits", () => {
  it("iPhone adds a photo while web edits a caption on an existing one — both survive", () => {
    const base = project({ photos: [photo("p1", { userCaption: null })] });
    // Web (client) edits p1's caption.
    const client = project({ photos: [photo("p1", { userCaption: "spalling at NE corner" })] });
    // iPhone (already pushed) added p2 — that's the current server state.
    const server = project({
      photos: [photo("p1", { userCaption: null }), photo("p2", { userCaption: "new capture" })],
    });
    const { merged } = mergeManifest(base, server, client);
    const ids = merged.photos.map((p) => p.id).sort();
    assert.deepEqual(ids, ["p1", "p2"], "both photos present");
    assert.equal(merged.photos.find((p) => p.id === "p1")!.userCaption, "spalling at NE corner");
    assert.equal(merged.photos.find((p) => p.id === "p2")!.userCaption, "new capture");
  });

  it("both edit different fields of the same photo — both edits land", () => {
    const base = project({ photos: [photo("p1")] });
    const server = project({ photos: [photo("p1", { isFavorite: true })] });
    const client = project({ photos: [photo("p1", { userCaption: "hi" })] });
    const { merged } = mergeManifest(base, server, client);
    const p1 = merged.photos[0]!;
    assert.equal(p1.isFavorite, true, "server's favorite kept");
    assert.equal(p1.userCaption, "hi", "client's caption kept");
  });

  it("both edit the SAME field differently — client wins, recorded", () => {
    const base = project({ photos: [photo("p1", { userCaption: "base" })] });
    const server = project({ photos: [photo("p1", { userCaption: "server" })] });
    const client = project({ photos: [photo("p1", { userCaption: "client" })] });
    const { merged, report } = mergeManifest(base, server, client);
    assert.equal(merged.photos[0]!.userCaption, "client");
    assert.equal(report.conflicts.length, 1);
    assert.equal(report.conflicts[0]!.path, "photos[p1].userCaption");
    assert.equal(report.conflicts[0]!.chosen, "client");
  });
});

// ---------------------------------------------------------------------------
// Deletes
// ---------------------------------------------------------------------------

describe("mergeManifest — deletes", () => {
  it("hard-delete on one side honoured when the other left it untouched", () => {
    const base = project({ photos: [photo("p1"), photo("p2")] });
    const server = project({ photos: [photo("p1"), photo("p2")] }); // unchanged
    const client = project({ photos: [photo("p1")] }); // deleted p2
    const { merged } = mergeManifest(base, server, client);
    assert.deepEqual(merged.photos.map((p) => p.id), ["p1"], "p2 removed");
  });

  it("modify-beats-delete: edited on one side, deleted on the other — kept", () => {
    const base = project({ photos: [photo("p1"), photo("p2", { userCaption: null })] });
    const server = project({ photos: [photo("p1"), photo("p2", { userCaption: "important note" })] }); // edited p2
    const client = project({ photos: [photo("p1")] }); // deleted p2
    const { merged } = mergeManifest(base, server, client);
    const p2 = merged.photos.find((p) => p.id === "p2");
    assert.ok(p2, "p2 survives because it was edited on the server");
    assert.equal(p2!.userCaption, "important note");
  });

  it("soft-delete (trash) wins over a concurrent edit, but the edit is applied", () => {
    const base = project({ photos: [photo("p1", { userCaption: null, trashedAt: null })] });
    // Server trashed p1.
    const server = project({
      photos: [],
      trashedPhotos: [photo("p1", { userCaption: null, trashedAt: "2026-03-01T00:00:00Z" })],
    });
    // Client edited p1's caption (still active).
    const client = project({ photos: [photo("p1", { userCaption: "edited", trashedAt: null })] });
    const { merged } = mergeManifest(base, server, client);
    assert.equal(merged.photos.length, 0, "p1 not active");
    assert.equal(merged.trashedPhotos.length, 1, "p1 trashed (trash wins)");
    assert.equal(merged.trashedPhotos[0]!.userCaption, "edited", "client's edit still applied");
  });
});

// ---------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------

describe("mergeManifest — tags", () => {
  it("additive union of tags from both sides, max confidence on overlap", () => {
    const base = project({ photos: [photo("p1", { tags: [tag("Foundation", 0.5)] })] });
    const server = project({ photos: [photo("p1", { tags: [tag("Foundation", 0.9), tag("Rust", 0.7)] })] });
    const client = project({ photos: [photo("p1", { tags: [tag("Foundation", 0.6), tag("Cracking", 0.8)] })] });
    const { merged } = mergeManifest(base, server, client);
    const tags = merged.photos[0]!.tags;
    const byLabel = Object.fromEntries(tags.map((t) => [t.label, t.confidence]));
    assert.equal(byLabel["Foundation"], 0.9, "max confidence kept");
    assert.equal(byLabel["Rust"], 0.7, "server-only tag kept");
    assert.equal(byLabel["Cracking"], 0.8, "client-only tag kept");
  });

  it("a tag deleted on one side and untouched on the other is dropped", () => {
    const base = project({ photos: [photo("p1", { tags: [tag("Foundation", 0.5), tag("Rust", 0.5)] })] });
    const server = project({ photos: [photo("p1", { tags: [tag("Foundation", 0.5), tag("Rust", 0.5)] })] });
    const client = project({ photos: [photo("p1", { tags: [tag("Foundation", 0.5)] })] }); // removed Rust
    const { merged } = mergeManifest(base, server, client);
    assert.deepEqual(merged.photos[0]!.tags.map((t) => t.label), ["Foundation"], "Rust removal honoured");
  });
});

// ---------------------------------------------------------------------------
// Scalar tie-breaks
// ---------------------------------------------------------------------------

describe("mergeManifest — scalar rules", () => {
  it("isFrozen: true wins on conflict (freeze is protective intent)", () => {
    const base = project({ isFrozen: false });
    const server = project({ isFrozen: true });
    const client = project({ isFrozen: false, name: "edited concurrently" });
    const { merged } = mergeManifest(base, server, client);
    assert.equal(merged.isFrozen, true);
  });

  it("isDeleted: true wins on conflict (deletion not silently resurrected)", () => {
    const base = project({ isDeleted: false });
    const server = project({ isDeleted: true });
    const client = project({ isDeleted: false, name: "still editing" });
    const { merged } = mergeManifest(base, server, client);
    assert.equal(merged.isDeleted, true);
  });

  it("manifestSchemaVersion never downgrades", () => {
    const base = project({ manifestSchemaVersion: 2 });
    const server = project({ manifestSchemaVersion: 3 });
    const client = project({ manifestSchemaVersion: 2 });
    const { merged } = mergeManifest(base, server, client);
    assert.equal(merged.manifestSchemaVersion, 3);
  });

  it("only-client-changed scalar takes the client", () => {
    const base = project({ name: "A" });
    const server = project({ name: "A" });
    const client = project({ name: "B" });
    const { merged, report } = mergeManifest(base, server, client);
    assert.equal(merged.name, "B");
    assert.equal(report.conflicts.length, 0, "not a conflict — only one side moved");
  });
});

// ---------------------------------------------------------------------------
// iOS migration safety: base = current server → purely additive
// ---------------------------------------------------------------------------

describe("mergeManifest — migration first sync (superset construction)", () => {
  // The safe first cloud-first sync for an install with no stored base
  // is NOT `base := serverCurrent` with a partial client — that would
  // read every server-only photo the client lacks as a client deletion
  // and drop it. The correct construction is base := serverCurrent AND
  // client := serverCurrent ∪ (the client's local-only-new items). A
  // client that is a SUPERSET of base never drops a base item, so all
  // server data is preserved and only genuinely-new local captures are
  // added. (iOS PR 1.4 builds the client this way; offline edits to
  // existing items defer to the server on this one-time sync.)
  it("client = server ∪ local-new → nothing dropped, local-new added", () => {
    const server = project({ photos: [photo("p1"), photo("p2"), photo("p3")] });
    const base = clone(server);
    const client = project({
      photos: [...clone(server).photos, photo("p4", { userCaption: "local capture" })],
    });
    const { merged } = mergeManifest(base, server, client);
    const ids = merged.photos.map((p) => p.id).sort();
    assert.deepEqual(ids, ["p1", "p2", "p3", "p4"], "server photos preserved + local-new added");
    assert.equal(merged.photos.find((p) => p.id === "p4")!.userCaption, "local capture");
  });

  it("base=server with a PARTIAL client treats missing items as deletes (why superset matters)", () => {
    // Documents the trap: do NOT migrate with a partial client.
    const server = project({ photos: [photo("p1"), photo("p2"), photo("p3")] });
    const base = clone(server);
    const partialClient = project({ photos: [photo("p1")] });
    const { merged } = mergeManifest(base, server, partialClient);
    assert.deepEqual(merged.photos.map((p) => p.id), ["p1"], "partial client drops p2/p3 — correct delete semantics");
  });
});

// ---------------------------------------------------------------------------
// Convergence: re-merging a merged state is stable
// ---------------------------------------------------------------------------

describe("mergeManifest — convergence", () => {
  it("merging an already-merged state against either side is a no-op on content", () => {
    const base = project({ photos: [photo("p1")] });
    const server = project({ photos: [photo("p1", { isFavorite: true }), photo("p2")] });
    const client = project({ photos: [photo("p1", { userCaption: "x" })] });
    const { merged } = mergeManifest(base, server, client);
    // Re-merge the merged result against itself — must be identical.
    const again = mergeManifest(merged, clone(merged), clone(merged)).merged;
    assert.ok(deepEqual(again, merged), "re-merge converges");
  });
});
