import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var startedAt: Date?
    var lastResumedAt: Date?
    var lastStoppedAt: Date?
    var stopped: Bool
    var projectGPS: ProjectGPS?
    var projectAddress: String?
    var photos: [Photo]
    /// Soft-deleted photos awaiting restore or auto-purge. Moved out of
    /// `photos` so every existing consumer (export, bucket counters,
    /// filters, map markers, …) keeps showing only live records without
    /// each call site having to remember to filter. Each entry's
    /// `trashedAt` carries the move timestamp used by the 30-day purge
    /// in `ProjectStore.purgeOldTrash()`.
    var trashedPhotos: [Photo] = []
    /// Multiple labelled floor plans per project. Order is preserved
    /// (the engineer can reorder via `ProjectStore.reorderFloorPlans`).
    /// Each `Photo` references its plan via `Photo.floorPlanID`.
    /// Manifests written before multi-plan support migrate at decode
    /// time: a singular legacy `floorPlan` entry is wrapped into a
    /// single-element `floorPlans` array with a freshly-minted UUID
    /// and a `"Plan 1"` label.
    var floorPlans: [FloorPlan]
    /// "Sticky" plan that drives default behaviour:
    ///   * `LocateSheet` defaults its picker to this plan after a
    ///     capture (and updates it to whatever the engineer picks);
    ///   * `PlanViewerView` opens to this plan first;
    ///   * `FloorPlanAssignmentSheet` (import-time) defaults here.
    /// `nil` means "use the first plan in `floorPlans`" — the computed
    /// `floorPlan` accessor below resolves the fallback.
    var activeFloorPlanID: UUID?
    /// Stable, human-readable folder name used on disk. Computed once at
    /// creation; nil only on projects created before this field existed.
    var folderName: String?
    /// Optional per-project free-text notes appended to Claude's system
    /// prompt as "Additional notes for this project." Use cases: one-off
    /// guidance like "focus on the east elevation" or "this project has
    /// a known foundation repair in 2018." `nil` or empty means no
    /// notes are appended. Historically this field held a full prompt
    /// override; with the rules-template + per-project tag-selection
    /// rework, it's been demoted to notes-only.
    var aiInstructions: String?
    /// User-defined categories for grouping photos in this project. Each
    /// `Photo.bucketID` references one of these (or nil). Folder export
    /// renders one directory per bucket in `sortOrder`. Empty by default —
    /// the user opts in by creating buckets via the manager sheet.
    var buckets: [Bucket]
    /// Project-scoped subset of the app-wide `TagLibrary` that drives the
    /// AI tagging prompt for this project. `nil` means the engineer
    /// hasn't picked anything yet — AI tagging refuses to run until at
    /// least one investigation context is picked.
    var tagSelection: ProjectTagSelection?
    /// Per-project additions to the controlled vocabulary. Always-on
    /// for the project that owns them: every primary + secondary
    /// listed here is sent to Claude alongside the main vocabulary
    /// block and accepted by `AIResponseValidator` for this project's
    /// responses. Never touches the app-wide `TagLibrary`. `nil` (or
    /// an empty `primaries` array) means the project doesn't add any
    /// custom vocabulary.
    var aiExtraVocabulary: ProjectExtraVocabulary?
    /// Soft-delete flag. `ProjectStore.delete(_:)` sets this to
    /// `true` and `restore(_:)` sets it back to `false`. The web
    /// client uses it to hide trashed projects from the list; iOS
    /// uses the on-disk folder location as its primary source of
    /// truth but ALSO writes this field so the manifest pushed to
    /// the server carries the correct state. Defaults to `false`
    /// for new projects + older manifests pre-Build #5.6.1.
    var isDeleted: Bool = false
    /// Project-lock / "finalized" flag (Build #5.126.1, Phase 4).
    /// When true the project is read-only on every client — edit
    /// controls are disabled in the UI and the server's access helper
    /// requires Owner/Admin to flip the flag. Distinct from the
    /// transient `project_locks` edit-lock; this is a persistent
    /// state for finalising a report.
    /// Defaults to `false` for new projects + older manifests pre-
    /// Build #5.126.1.
    var isFrozen: Bool = false
    /// Integer schema version of the on-disk manifest format. Bumped
    /// whenever a field is added, removed, renamed, or its semantics
    /// change — in one PR that touches `packages/shared/`,
    /// `docs/parity-matrix.md`, and any iOS / server code that reads
    /// or writes the changed field. The server rejects writes from
    /// clients reporting a higher version than it knows about
    /// (forces server-first updates). Legacy manifests written before
    /// this field shipped default to `1` at decode time.
    var manifestSchemaVersion: Int = 3

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.startedAt = nil
        self.lastResumedAt = nil
        self.lastStoppedAt = nil
        self.stopped = false
        self.projectGPS = nil
        self.projectAddress = nil
        self.photos = []
        self.trashedPhotos = []
        self.floorPlans = []
        self.activeFloorPlanID = nil
        self.folderName = Self.makeFolderName(id: id, name: name, createdAt: self.createdAt)
        self.aiInstructions = nil
        self.buckets = []
        self.tagSelection = nil
        self.aiExtraVocabulary = nil
        self.isDeleted = false
        self.isFrozen = false
        self.manifestSchemaVersion = 3
    }

    /// Explicit keys so the decoder can read the legacy singular
    /// `floorPlan` key from older manifests without keeping a backing
    /// stored property. `encode(to:)` below intentionally never writes
    /// that key — once a project is loaded + saved through this code,
    /// the on-disk shape is `floorPlans` + `activeFloorPlanID` only.
    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, startedAt, lastResumedAt, lastStoppedAt
        case stopped, projectGPS, projectAddress, photos, trashedPhotos
        case floorPlan          // legacy single-plan field (decode only)
        case floorPlans         // new multi-plan array
        case activeFloorPlanID  // new sticky plan ID
        case folderName, aiInstructions, buckets, tagSelection
        case aiExtraVocabulary
        case isDeleted
        case isFrozen
        case manifestSchemaVersion
    }

    /// Tolerate manifests written before any of the optional fields
    /// existed — and bridge the legacy single `floorPlan` key into the
    /// new `floorPlans` array transparently. The on-disk image file
    /// rename (`plan.jpg` → `plan-<uuid>.jpg`) happens in
    /// `ProjectStore.load()` on first load after migration; here we
    /// only fix up the in-memory model.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(UUID.self,            forKey: .id)
        self.name            = try c.decode(String.self,          forKey: .name)
        self.createdAt       = try c.decode(Date.self,            forKey: .createdAt)
        self.startedAt       = try c.decodeIfPresent(Date.self,   forKey: .startedAt)
        self.lastResumedAt   = try c.decodeIfPresent(Date.self,   forKey: .lastResumedAt)
        self.lastStoppedAt   = try c.decodeIfPresent(Date.self,   forKey: .lastStoppedAt)
        self.stopped         = try c.decode(Bool.self,            forKey: .stopped)
        self.projectGPS      = try c.decodeIfPresent(ProjectGPS.self, forKey: .projectGPS)
        self.projectAddress  = try c.decodeIfPresent(String.self, forKey: .projectAddress)
        self.photos          = try c.decode([Photo].self,         forKey: .photos)
        self.trashedPhotos   = try c.decodeIfPresent([Photo].self, forKey: .trashedPhotos) ?? []

        // Floor plans — prefer the new array; fall back to the legacy
        // singular field if the new key isn't present.
        if let plans = try c.decodeIfPresent([FloorPlan].self,
                                              forKey: .floorPlans), !plans.isEmpty {
            self.floorPlans = plans
        } else if let legacy = try c.decodeIfPresent(LegacyFloorPlan.self,
                                                       forKey: .floorPlan) {
            self.floorPlans = [legacy.upgraded(label: "Plan 1")]
        } else {
            self.floorPlans = []
        }
        let storedActive = try c.decodeIfPresent(UUID.self, forKey: .activeFloorPlanID)
        self.activeFloorPlanID = storedActive ?? self.floorPlans.first?.id

        self.folderName      = try c.decodeIfPresent(String.self, forKey: .folderName)
        self.aiInstructions  = try c.decodeIfPresent(String.self, forKey: .aiInstructions)
        self.buckets         = try c.decodeIfPresent([Bucket].self, forKey: .buckets) ?? []
        self.tagSelection    = try c.decodeIfPresent(ProjectTagSelection.self,
                                                       forKey: .tagSelection)
        self.aiExtraVocabulary = try c.decodeIfPresent(ProjectExtraVocabulary.self,
                                                         forKey: .aiExtraVocabulary)
        // Older manifests (pre-Build #5.6.1) didn't carry isDeleted.
        // Default to false so existing on-disk projects keep behaving
        // as not-deleted; ProjectStore.delete(_:) writes true going
        // forward.
        self.isDeleted = try c.decodeIfPresent(Bool.self,
                                                  forKey: .isDeleted) ?? false
        // Pre-Build #5.126.1 manifests didn't carry isFrozen.
        // Default to false so existing projects stay editable;
        // Owner/Admin flips true via the "Lock project" action.
        self.isFrozen = try c.decodeIfPresent(Bool.self,
                                                 forKey: .isFrozen) ?? false
        // Legacy manifests written before this field shipped default
        // to version 1 — the schema as it stood at the moment the
        // field was introduced. New manifests written by this code
        // always emit an explicit value.
        self.manifestSchemaVersion = try c.decodeIfPresent(Int.self,
                                                             forKey: .manifestSchemaVersion) ?? 1
    }

    /// Encoder mirrors the new on-disk shape (no legacy `floorPlan`
    /// key). After the first load+save through this code path, every
    /// manifest is in the new shape.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,                          forKey: .id)
        try c.encode(name,                        forKey: .name)
        try c.encode(createdAt,                   forKey: .createdAt)
        try c.encodeIfPresent(startedAt,          forKey: .startedAt)
        try c.encodeIfPresent(lastResumedAt,      forKey: .lastResumedAt)
        try c.encodeIfPresent(lastStoppedAt,      forKey: .lastStoppedAt)
        try c.encode(stopped,                     forKey: .stopped)
        try c.encodeIfPresent(projectGPS,         forKey: .projectGPS)
        try c.encodeIfPresent(projectAddress,     forKey: .projectAddress)
        try c.encode(photos,                      forKey: .photos)
        try c.encode(trashedPhotos,               forKey: .trashedPhotos)
        try c.encode(floorPlans,                  forKey: .floorPlans)
        try c.encodeIfPresent(activeFloorPlanID,  forKey: .activeFloorPlanID)
        try c.encodeIfPresent(folderName,         forKey: .folderName)
        try c.encodeIfPresent(aiInstructions,     forKey: .aiInstructions)
        try c.encode(buckets,                     forKey: .buckets)
        try c.encodeIfPresent(tagSelection,       forKey: .tagSelection)
        try c.encodeIfPresent(aiExtraVocabulary,  forKey: .aiExtraVocabulary)
        try c.encode(isDeleted,                   forKey: .isDeleted)
        try c.encode(isFrozen,                    forKey: .isFrozen)
        try c.encode(manifestSchemaVersion,       forKey: .manifestSchemaVersion)
    }

    var isActive: Bool { startedAt != nil && !stopped }
    var hasBeenStarted: Bool { startedAt != nil }

    /// Backward-compat accessor that returns whichever plan is "current":
    /// the explicit `activeFloorPlanID` if set + present, otherwise the
    /// first plan in the array. Lets the bulk of the existing
    /// single-plan code (`PlanViewerView`, `LocateSheet`,
    /// `RelocateSheet`, `PDFExportService`, etc.) keep using
    /// `project.floorPlan` while specific call sites migrate to
    /// per-plan-ID lookups in P2.
    var floorPlan: FloorPlan? {
        if let activeID = activeFloorPlanID,
           let plan = floorPlans.first(where: { $0.id == activeID }) {
            return plan
        }
        return floorPlans.first
    }

    /// Resolve a plan by ID. Returns `nil` for an unknown ID — used by
    /// the photo-list filter pill, the relocate sheet's plan picker,
    /// and per-photo lookups (`Photo.floorPlanID` resolution).
    func floorPlan(id: UUID) -> FloorPlan? {
        floorPlans.first { $0.id == id }
    }

    static func makeFolderName(id: UUID, name: String, createdAt: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        let dateStr = dateFormatter.string(from: createdAt)

        let cleaned = name
            .replacingOccurrences(of: "[^A-Za-z0-9 -]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let dashed = cleaned.replacingOccurrences(of: " +", with: "-", options: .regularExpression)
        let safe = String(dashed.prefix(40))
        let body = safe.isEmpty ? "project" : safe
        let idPrefix = String(id.uuidString.lowercased().prefix(6))
        return "\(dateStr)_\(body)_\(idPrefix)"
    }
}

struct ProjectGPS: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    var accuracyFeet: Double?
    var timestamp: Date
}

/// Kinds of structural distress the engineer can drop on a floor plan
/// alongside the photo pins. Three are point markers (different colors
/// so they're identifiable at a glance) and one — `crackFloor` — is a
/// free-style pencil stroke the engineer draws with their finger to
/// trace the crack's actual path on the slab.
enum DistressKind: String, Codable, CaseIterable, Hashable {
    case outOfPlumbDoor
    case doorNotLatching
    case crackGradeBeam
    case crackFloor

    var displayName: String {
        switch self {
        case .outOfPlumbDoor:    return "Out of plumb door"
        case .doorNotLatching:   return "Door not latching"
        case .crackGradeBeam:    return "Crack in grade beam"
        case .crackFloor:        return "Crack in floor"
        }
    }

    /// Short label for the contact-sheet legend and the on-plan
    /// callouts — `displayName` is too long to fit next to a marker.
    var shortLabel: String {
        switch self {
        case .outOfPlumbDoor:    return "Door (plumb)"
        case .doorNotLatching:   return "Door (latch)"
        case .crackGradeBeam:    return "Grade beam"
        case .crackFloor:        return "Floor crack"
        }
    }

    /// Whether this distress kind is rendered as a free-style stroke
    /// (true) or as a single point marker (false). Drives the placement
    /// gesture in `DistressViewerView` and the rendering path in the
    /// PDF exporter.
    var isStroke: Bool {
        self == .crackFloor
    }
}

/// One distress observation placed on a floor plan. Stored in
/// **plan-image pixel coordinates** so the placement survives
/// re-calibration of the plan's scale (same invariant as photo pins).
struct DistressMark: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: DistressKind
    /// Pixel coordinates on the plan image. One entry for dot kinds;
    /// many sampled points for the `crackFloor` pencil stroke.
    var points: [CGPoint]
    /// Optional engineer note — surfaced in the editor's side list and
    /// in the PDF legend. Nil when the user hasn't typed anything yet.
    var note: String?
    var createdAt: Date

    init(id: UUID = UUID(),
         kind: DistressKind,
         points: [CGPoint],
         note: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.points = points
        self.note = note
        self.createdAt = createdAt
    }
}

struct FloorPlan: Identifiable, Codable, Hashable {
    /// Stable identity assigned on creation. Photos reference the plan
    /// they live on through `Photo.floorPlanID`; the on-disk image file
    /// embeds a short prefix of this UUID so multiple plans can coexist
    /// in one project folder without filename collisions.
    var id: UUID
    /// Engineer-typed label. Defaults to "Plan N" where N is the next
    /// sequential index when added through `ProjectStore.addFloorPlan`.
    var label: String
    var imageFilename: String
    var pixelsPerFoot: Double
    var calibrationDistanceFeet: Double
    var anchorPixelX: Double
    var anchorPixelY: Double
    var anchorLocalXFeet: Double
    var anchorLocalYFeet: Double
    var northDeg: Double
    /// Distress observations placed on this plan. Independent of
    /// photo pins (different conceptual layer, different rendering
    /// path). Default empty so existing project manifests decode
    /// cleanly.
    var distress: [DistressMark]

    init(id: UUID = UUID(),
         label: String,
         imageFilename: String,
         pixelsPerFoot: Double,
         calibrationDistanceFeet: Double,
         anchorPixelX: Double,
         anchorPixelY: Double,
         anchorLocalXFeet: Double,
         anchorLocalYFeet: Double,
         northDeg: Double,
         distress: [DistressMark] = []) {
        self.id = id
        self.label = label
        self.imageFilename = imageFilename
        self.pixelsPerFoot = pixelsPerFoot
        self.calibrationDistanceFeet = calibrationDistanceFeet
        self.anchorPixelX = anchorPixelX
        self.anchorPixelY = anchorPixelY
        self.anchorLocalXFeet = anchorLocalXFeet
        self.anchorLocalYFeet = anchorLocalYFeet
        self.northDeg = northDeg
        self.distress = distress
    }

    /// Tolerate the legacy on-disk shape (no `id`, no `label`,
    /// no `distress`) by minting fresh values when those keys are
    /// missing. Existing installs that wrote a `floorPlans: [FloorPlan]`
    /// array before `id`/`label`/`distress` shipped will still decode
    /// cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                       = try c.decodeIfPresent(UUID.self,   forKey: .id)
            ?? UUID()
        self.label                    = try c.decodeIfPresent(String.self, forKey: .label)
            ?? "Plan"
        self.imageFilename            = try c.decode(String.self, forKey: .imageFilename)
        self.pixelsPerFoot            = try c.decode(Double.self, forKey: .pixelsPerFoot)
        self.calibrationDistanceFeet  = try c.decode(Double.self, forKey: .calibrationDistanceFeet)
        self.anchorPixelX             = try c.decode(Double.self, forKey: .anchorPixelX)
        self.anchorPixelY             = try c.decode(Double.self, forKey: .anchorPixelY)
        self.anchorLocalXFeet         = try c.decode(Double.self, forKey: .anchorLocalXFeet)
        self.anchorLocalYFeet         = try c.decode(Double.self, forKey: .anchorLocalYFeet)
        self.northDeg                 = try c.decode(Double.self, forKey: .northDeg)
        self.distress                 = try c.decodeIfPresent([DistressMark].self,
                                                              forKey: .distress) ?? []
    }
}

/// Disk shape of the legacy single-plan field. Decoded once when an
/// older manifest is loaded, then upgraded into a fresh `FloorPlan`
/// with a minted UUID + default label. Never re-encoded — the new
/// format takes over after the first save.
private struct LegacyFloorPlan: Codable {
    let imageFilename: String
    let pixelsPerFoot: Double
    let calibrationDistanceFeet: Double
    let anchorPixelX: Double
    let anchorPixelY: Double
    let anchorLocalXFeet: Double
    let anchorLocalYFeet: Double
    let northDeg: Double

    func upgraded(label: String) -> FloorPlan {
        FloorPlan(
            id: UUID(),
            label: label,
            imageFilename: imageFilename,
            pixelsPerFoot: pixelsPerFoot,
            calibrationDistanceFeet: calibrationDistanceFeet,
            anchorPixelX: anchorPixelX,
            anchorPixelY: anchorPixelY,
            anchorLocalXFeet: anchorLocalXFeet,
            anchorLocalYFeet: anchorLocalYFeet,
            northDeg: northDeg
        )
    }
}
