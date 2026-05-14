import Foundation

/// App-wide three-level catalog of investigation contexts, primary tags,
/// and secondary tags used by the AI tagging pipeline. The engineer
/// extends this library through the Tag Library Manager — additions are
/// visible to every existing and future project on the device.
///
/// As of seed v2 the bundled defaults collapse to a SINGLE context
/// ("Forensic Investigation") that holds every primary tag the
/// forensic-residential workflow needs. The context machinery is
/// retained so engineers can still add custom contexts of their own,
/// but the default flow no longer asks them to pick multiple contexts
/// per project.
///
/// The library is intentionally separate from the per-project selection
/// (`ProjectTagSelection`). When the engineer kicks off AI tagging on a
/// project, the project's selection is resolved against this library to
/// produce the vocabulary block embedded in Claude's system prompt.
struct InvestigationContext: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var primaries: [PrimaryTagEntry]

    init(id: UUID = UUID(), name: String, primaries: [PrimaryTagEntry]) {
        self.id = id
        self.name = name
        self.primaries = primaries
    }
}

struct PrimaryTagEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var secondaries: [SecondaryTagEntry]

    init(id: UUID = UUID(), name: String, secondaries: [SecondaryTagEntry]) {
        self.id = id
        self.name = name
        self.secondaries = secondaries
    }
}

struct SecondaryTagEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// Unlabeled convenience init so the bulky seed array can be written
    /// as `["None", "Adequate drainage", …].map(SecondaryTagEntry.init)`
    /// rather than `.map { .init(name: $0) }`.
    init(_ name: String) {
        self.init(id: UUID(), name: name)
    }
}

/// Container that wraps the ordered context list so we can sidestep the
/// surprises of decoding a bare top-level Codable array (no
/// schema-versioning, no room for future sibling fields).
///
/// `seedVersion` is informational only — it records which bundled seed
/// initially populated a device's library. The loader does NOT compare
/// it on launch and does NOT trigger migrations off it. Custom edits
/// to the on-disk library are durable across app updates by design.
/// The field is retained so older persisted files decode cleanly and
/// so any hypothetical future migration has a version anchor to read
/// — but new migrations should be additive (append missing primaries /
/// secondaries) rather than replacing the file wholesale.
struct TagLibrary: Codable, Hashable, Sendable {
    var contexts: [InvestigationContext]
    var seedVersion: Int

    init(contexts: [InvestigationContext] = [],
         seedVersion: Int = currentSeedVersion) {
        self.contexts = contexts
        self.seedVersion = seedVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contexts = try c.decodeIfPresent([InvestigationContext].self,
                                               forKey: .contexts) ?? []
        self.seedVersion = try c.decodeIfPresent(Int.self,
                                                   forKey: .seedVersion) ?? 1
    }

    /// Seed version stamped onto fresh installs and onto `defaultSeeds`.
    /// No longer used as a load-time migration trigger — kept so the
    /// persisted file carries a sensible default if a future tool ever
    /// needs to introspect it.
    static let currentSeedVersion: Int = 2
}

extension TagLibrary {
    /// Quick lookup by ID — handy when the picker filters out stale IDs
    /// (left over after a library entry was deleted) without rewriting
    /// every project manifest.
    func context(id: UUID) -> InvestigationContext? {
        contexts.first { $0.id == id }
    }

    func primary(id: UUID) -> (context: InvestigationContext, primary: PrimaryTagEntry)? {
        for ctx in contexts {
            if let p = ctx.primaries.first(where: { $0.id == id }) {
                return (ctx, p)
            }
        }
        return nil
    }

    func secondary(id: UUID) -> (primary: PrimaryTagEntry, secondary: SecondaryTagEntry)? {
        for ctx in contexts {
            for p in ctx.primaries {
                if let s = p.secondaries.first(where: { $0.id == id }) {
                    return (p, s)
                }
            }
        }
        return nil
    }

}

// MARK: - Default seeds (v2)

extension TagLibrary {
    /// Bundled starter pack populated the first time the app launches on
    /// a device (i.e. when `tagLibrary.json` doesn't exist yet). The
    /// engineer can rename, reorder, delete, or extend any of these —
    /// they're seeds, not protected entries.
    ///
    /// v2 collapses the previous seven-context layout (Foundation
    /// Performance, Roofing, Framing, Stairs, Overall Views, Stucco,
    /// Photo Quality) into a single "Forensic Investigation" context
    /// that contains every primary tag the residential-forensic
    /// workflow needs. The flatten resolves two real bugs: (a) projects
    /// scoped to Foundation Performance never saw the
    /// `General Exterior/Interior Context` primaries the rules template
    /// referred them to; (b) engineers had to remember to pick multiple
    /// contexts when a job touched roofing, framing, moisture, or pool/
    /// site structures.
    ///
    /// (Earlier seeds carried a `"None"` secondary on every primary as
    /// a sentinel for "tag the primary but don't claim a specific
    /// secondary." That fallback is gone — every primary now ships
    /// with concrete overview / context secondaries, and the model
    /// either picks one of those or skips the primary entirely. The
    /// validator + downstream filters still tolerate the literal
    /// `"None"` string defensively in case an older model run or a
    /// legacy persisted library still emits it.)
    ///
    /// The vocabulary mirrors the v2 prompt + disambiguation guide
    /// shipped in `AIRulesTemplate.defaultText` — keep the two in sync.
    static let defaultSeeds: TagLibrary = TagLibrary(
        contexts: [
            .init(name: "Forensic Investigation", primaries: [
                // ── Context / overview ────────────────────────────────
                .init(name: "General Exterior Orientation", secondaries: [
                    "Front elevation overview",
                    "Rear elevation overview",
                    "Left elevation overview",
                    "Right elevation overview",
                    "Exterior material context",
                    "Porch / patio context"
                ].map(SecondaryTagEntry.init)),
                .init(name: "General Interior Orientation", secondaries: [
                    "Interior overview"
                ].map(SecondaryTagEntry.init)),
                .init(name: "General Site / Yard Context", secondaries: [
                    "Yard overview",
                    "Side yard overview",
                    "Rear yard overview",
                    "Retaining wall context",
                    "Drainage path context",
                    "Hardscape context",
                    "Grade change context"
                ].map(SecondaryTagEntry.init)),
                // ── Site + drainage + foundation concrete ─────────────
                .init(name: "Drainage / Grading", secondaries: [
                    "Drainage visually away from foundation",
                    "Marginal or flat drainage adjacent to foundation",
                    "Negative drainage toward foundation",
                    "Inadequate soil-to-finished-floor clearance",
                    "Downspout discharging near foundation",
                    "Downspout extension present",
                    "Local ponding evidence",
                    "Standing water",
                    "Area drain / surface drain",
                    "Trench drain / sump pit",
                    "Landscape bed adjacent to foundation"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Foundation / Grade Beam", secondaries: [
                    "Grade beam crack",
                    "Foundation corner crack",
                    "Brick ledge crack",
                    "Foundation-to-veneer interface distress",
                    "Parge coat crack",
                    "Parge coat raveling",
                    "Parge coat crazing",
                    "Concrete spall",
                    "Poorly consolidated concrete visible",
                    "Deteriorated concrete",
                    "Crack wider at top",
                    "Crack wider at bottom",
                    "Vertical crack",
                    "Diagonal / irregular crack",
                    "Vertical-to-diagonal crack"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Concrete Slabs - Garage / Porch / Patio / Interior", secondaries: [
                    "Garage slab crack",
                    "Porch slab crack",
                    "Patio slab crack",
                    "Interior slab crack",
                    "Differential elevation across slab crack",
                    "Displaced concrete",
                    "Slab edge crack",
                    "Concrete crazing",
                    "Slab patch",
                    "Slab breakout area",
                    "Surface staining at slab"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Driveway and Flatwork", secondaries: [
                    "Driveway crack",
                    "Sidewalk crack",
                    "Flatwork crack",
                    "Control-joint-adjacent crack",
                    "Panel separation",
                    "Separation from foundation",
                    "Separation at garage threshold",
                    "Elevation offset",
                    "Drop in driveway elevation",
                    "Loss of support / void",
                    "Step / trip hazard"
                ].map(SecondaryTagEntry.init)),
                // ── Exterior cladding ─────────────────────────────────
                .init(name: "Masonry Veneer", secondaries: [
                    "Mortar joint crack",
                    "Stair-step crack",
                    "Crack through masonry unit",
                    "Masonry-to-trim separation",
                    "Masonry-to-siding separation",
                    "Masonry-to-window separation",
                    "Masonry-to-roof interface separation",
                    "Masonry-to-foundation separation",
                    "Fireplace masonry separation",
                    "Expansion joint wide / stretched",
                    "Expansion joint compressed",
                    "Expansion joint torn / failed",
                    "Sealant cracked at masonry",
                    "Prior masonry repair"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Stucco / Exterior Finish", secondaries: [
                    "Stucco crack",
                    "Stucco separation",
                    "Paint / coating distress",
                    "Prior stucco repair",
                    "Gap at cladding transition"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Exterior Trim / Siding / Soffit", secondaries: [
                    "Exterior trim crack",
                    "Exterior trim separation",
                    "Exterior trim misalignment",
                    "Frieze board separation",
                    "Soffit separation",
                    "Siding separation",
                    "Siding joint separation",
                    "Siding distortion",
                    "Window trim separation",
                    "Door trim separation",
                    "Prior exterior finish repair"
                ].map(SecondaryTagEntry.init)),
                // ── Interior finish ───────────────────────────────────
                .init(name: "Interior Wall and Ceiling Sheetrock Finish", secondaries: [
                    "Wall sheetrock crack",
                    "Door / window corner crack",
                    "Wall-to-wall joint crack",
                    "Wall-to-ceiling joint crack",
                    "Bottom of wall separated from floor",
                    "Loose / unattached wall",
                    "Out-of-plumb wall",
                    "Previous wall repair",
                    "Texture / paint mismatch",
                    "Moisture stain on sheetrock",
                    "Ceiling sheetrock crack"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Flooring", secondaries: [
                    "Floor tile crack",
                    "Grout crack",
                    "Loose tile",
                    "Tile distress",
                    "Wood flooring separation",
                    "Wood flooring hump / unevenness",
                    "Rippled vinyl flooring",
                    "Floor finish separation",
                    "Previous flooring repair"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Interior Trim / Cabinets / Counters", secondaries: [
                    "Baseboard separation",
                    "Baseboard distortion",
                    "Baseboard-to-floor gap",
                    "Interior trim separation",
                    "Door casing separation",
                    "Crown molding crack / separation",
                    "Cabinet separation from wall",
                    "Countertop slope",
                    "Counter / cabinet misalignment",
                    "Windowsill separation",
                    "Prior trim repair"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Doors / Windows", secondaries: [
                    "Door out of plumb",
                    "Door racked",
                    "Door rubs frame",
                    "Door does not latch",
                    "Door frame crack / separation",
                    "Window out of plumb"
                ].map(SecondaryTagEntry.init)),
                // ── Slope / level ─────────────────────────────────────
                .init(name: "Floor Slope / Levelness", secondaries: [
                    "Measured floor slope",
                    "Digital level reading shown",
                    "Level reading shown"
                ].map(SecondaryTagEntry.init)),
                // ── Roof + framing ────────────────────────────────────
                .init(name: "Roof / Attic Framing", secondaries: [
                    "Attic framing overview",
                    "Rafter twisted / warped",
                    "Exposed fasteners",
                    "Loose / untight framing connection",
                    "Scrap lumber fit-up",
                    "Truss plate / gang nail distress",
                    "Sheathing gap",
                    "Moisture-stained roof sheathing"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Roofing", secondaries: [
                    "Roof overview",
                    "Buckled shingles",
                    "Wavy / wrinkled shingles",
                    "Damaged shingles",
                    "Metal roof context"
                ].map(SecondaryTagEntry.init)),
                // ── Moisture / site / structures ──────────────────────
                .init(name: "Moisture Intrusion / Staining", secondaries: [
                    "Moisture stain on ceiling",
                    "Moisture stain on wall",
                    "Moisture stain on roof sheathing",
                    "Moisture stain on slab / patio",
                    "Water intrusion evidence",
                    "Localized repair from water intrusion",
                    "Damp sheathing visible",
                    "Efflorescence / mineral staining",
                    "Wood deterioration or staining from water exposure",
                    "Sealant failure with staining",
                    "Ponding-related staining"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Trees / Vegetation / Landscaping", secondaries: [
                    "Mature tree near foundation",
                    "Removed tree area",
                    "Prior tree location"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Pool / Gazebo / Site Structure", secondaries: [
                    "Pool overview",
                    "Pool waterline uneven",
                    "Pool coping elevation difference",
                    "Pool deck elevation difference"
                ].map(SecondaryTagEntry.init)),
                // ── Measurement / photo quality ───────────────────────
                .init(name: "Measurement / Instrument Readout", secondaries: [
                    "Ruler / tape visible",
                    "Crack comparator visible",
                    "Digital level visible",
                    "ZipLevel / elevation equipment visible",
                    "Moisture meter reading",
                    "Measurement number visible",
                    "Floor slope measurement",
                    "Scale reference present",
                    "Measurement unclear / obstructed"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Photo Quality / Re-shoot", secondaries: [
                    "Blurry image",
                    "Too dark",
                    "Overexposed"
                ].map(SecondaryTagEntry.init))
            ])
        ],
        seedVersion: TagLibrary.currentSeedVersion
    )
}
