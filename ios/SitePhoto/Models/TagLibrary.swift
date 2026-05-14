import Foundation

/// App-wide three-level catalog of investigation contexts, primary tags,
/// and secondary tags used by the AI tagging pipeline. The engineer
/// extends this library through the Tag Library Manager — additions are
/// visible to every existing and future project on the device.
///
/// As of seed v3 the bundled defaults collapse to a SINGLE context
/// ("Foundation Performance Evaluation") that holds every primary tag
/// the forensic-residential workflow needs. The context machinery is
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
    /// Bumped whenever the bundled vocab or context name changes in a
    /// way that requires existing installs to re-seed.
    /// `ProjectStore.loadTagLibraryFromDisk` compares the persisted
    /// value against `currentSeedVersion` on launch and re-runs
    /// migration when the persisted blob is behind.
    static let currentSeedVersion: Int = 3
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

// MARK: - Default seeds (v3)

extension TagLibrary {
    /// Bundled starter pack populated the first time the app launches on
    /// a device (i.e. when `tagLibrary.json` doesn't exist yet) and
    /// re-applied to every existing install whenever
    /// `TagLibrary.currentSeedVersion` is bumped. The engineer can
    /// rename, reorder, delete, or extend any of these in the Tag
    /// Library Manager — they're seeds, not protected entries.
    ///
    /// v3 keeps the single-context layout v2 introduced but renames
    /// the context "Forensic Investigation" → "Foundation Performance
    /// Evaluation" and reshapes the vocabulary against the engineer's
    /// most recent markup workbook (22 primaries, ~136 secondaries
    /// total). The vocab block in the prompt now renders each entry
    /// as a `Context::Primary::Secondary` triple so the AI never has
    /// to remember which primary a secondary sits under — see
    /// `PromptCompiler.compileVocabularyBlock`.
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
    /// The vocabulary mirrors the v3 prompt + worked examples shipped
    /// in `AIRulesTemplate.defaultText` — keep the two in sync.
    static let defaultSeeds: TagLibrary = TagLibrary(
        contexts: [
            .init(name: "Foundation Performance Evaluation", primaries: [
                .init(name: "General Exterior Orientation", secondaries: [
                    "Front elevation overall view",
                    "Rear elevation overall view",
                    "Left elevation overall view",
                    "Right elevation overall view",
                    "Porch / patio overall view"
                ].map(SecondaryTagEntry.init)),
                .init(name: "General Interior Orientation", secondaries: [
                    "Interior overall view"
                ].map(SecondaryTagEntry.init)),
                .init(name: "General Site Overview", secondaries: [
                    "Yard overview",
                    "Side yard overview",
                    "Rear yard overview",
                    "Retaining wall context",
                    "Drainage path context",
                    "Hardscape context",
                    "Grade change context"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Drainage / Grading", secondaries: [
                    "Drainage visually away from foundation",
                    "Marginal or flat drainage adjacent to foundation",
                    "Negative drainage toward foundation",
                    "Inadequate soil-to-siding clearance",
                    "Downspout discharging near foundation",
                    "Downspout extension present",
                    "Local ponding evidence",
                    "Standing water",
                    "Area drain / surface drain",
                    "Trench drain / sump pit",
                    "Overall view of landscape bed adjacent to foundation (not closeup or partial)",
                    "Evidence of ponding debris on slab"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Foundation / Grade Beam", secondaries: [
                    "Grade beam crack",
                    "Foundation corner crack",
                    "Brick ledge crack",
                    "Foundation-to-veneer interface distress",
                    "Parge coat raveling",
                    "Parge coat crazing",
                    "Concrete spall",
                    "Poorly consolidated concrete visible",
                    "Deteriorated concrete",
                    "Exposed rebar"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Concrete Slabs - Garage / Porch / Patio / Interior", secondaries: [
                    "Garage slab crack",
                    "Porch slab crack",
                    "Patio slab crack",
                    "Interior slab crack",
                    "Differential elevation across slab crack",
                    "Concrete crazing",
                    "Slab patch",
                    "Surface staining at slab"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Driveway and Flatwork", secondaries: [
                    "Driveway crack",
                    "Flatwork crack",
                    "Panel separation",
                    "Panel differential elevation",
                    "Loss of support / void"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Masonry Veneer", secondaries: [
                    "Mortar joint crack",
                    "Stair-step crack",
                    "Crack through masonry unit",
                    "Masonry-to-trim separation",
                    "Masonry-to-siding separation",
                    "Masonry-to-window separation",
                    "Masonry-to-foundation separation",
                    "Fireplace masonry separation",
                    "Expansion joint wide / stretched",
                    "Expansion joint compressed",
                    "Expansion joint torn / failed",
                    "Sealant cracked between masonry and adjacent item",
                    "Prior masonry repair"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Stucco / Exterior Finish", secondaries: [
                    "Stucco crack",
                    "Paint / coating distress",
                    "Prior stucco repair",
                    "No sealant visible around windows and doors (defective construction?)"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Exterior Trim / Siding / Soffit", secondaries: [
                    "Exterior trim separation",
                    "Siding separation",
                    "Siding joint separation",
                    "Siding distortion",
                    "Window trim separation",
                    "Door trim separation",
                    "Prior exterior finish repair"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Interior Wall and Ceiling Sheetrock Finish", secondaries: [
                    "Wall sheetrock crack",
                    "Wall-to-wall joint crack",
                    "Wall-to-ceiling joint crack",
                    "Bottom of wall separated from floor",
                    "Out-of-plumb wall (only if documented with a level)",
                    "Previous wall repair (cracks painted over)",
                    "Texture / paint mismatch",
                    "Ceiling sheetrock crack"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Flooring", secondaries: [
                    "Floor tile crack",
                    "Grout crack",
                    "Loose tile",
                    "Tile distress",
                    "Wood flooring separation",
                    "Wood flooring hump / unevenness (documented with a level)",
                    "Rippled vinyl flooring"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Interior Trim / Cabinets / Counters", secondaries: [
                    "Baseboard separation",
                    "Interior trim separation",
                    "Door casing/trim separation",
                    "Crown molding crack / separation",
                    "Cabinet separation from wall",
                    "Countertop slope (documented with a level)",
                    "Windowsill separation"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Doors", secondaries: [
                    "Door out of plumb (visible via non-straight gap between door and frame)",
                    "Door rubs frame (rubbing marks on frame)",
                    "Door does not latch (photo of door latch)"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Floor Slope / Levelness", secondaries: [
                    "Floor slope documented with a level",
                    "Digital level reading shown",
                    "Level bubble reading shown"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Attic Framing", secondaries: [
                    "Attic framing overview",
                    "Rafter twisted / warped",
                    "Exposed fasteners between wood framing members",
                    "Loose / untight framing connection (wide joints)",
                    "Truss plate / gang nail distress",
                    "Moisture-stained roof sheathing"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Roofing", secondaries: [
                    "Roof overview",
                    "Buckled shingles",
                    "Wavy / wrinkled shingles",
                    "Damaged metal roof",
                    "Damaged shingles",
                    "Metal roof overall view"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Moisture Intrusion", secondaries: [
                    "Moisture stain on ceiling",
                    "Moisture stain on wall",
                    "Damp sheathing visible",
                    "Efflorescence / mineral staining",
                    "Wood deterioration from water exposure",
                    "Wood staining or discoloration from water exposure"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Trees / Vegetation / Landscaping", secondaries: [
                    "Mature tree near foundation",
                    "Removed tree stump"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Pool", secondaries: [
                    "Pool overview",
                    "Pool waterline uneven",
                    "Pool coping elevation difference",
                    "Pool deck elevation difference"
                ].map(SecondaryTagEntry.init)),
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
