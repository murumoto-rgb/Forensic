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
    /// "None" is treated as a regular secondary because every other
    /// secondary list in the pack carries it; keeping it in-data lets
    /// the engineer remove it intentionally on a per-primary basis if
    /// they don't want it offered to the AI for that tag.
    ///
    /// The vocabulary mirrors the v2 prompt + disambiguation guide
    /// shipped in `AIRulesTemplate.defaultText` — keep the two in sync.
    static let defaultSeeds: TagLibrary = TagLibrary(
        contexts: [
            .init(name: "Forensic Investigation", primaries: [
                // ── Context / overview ────────────────────────────────
                .init(name: "General Exterior Context", secondaries: [
                    "None",
                    "Front elevation overview",
                    "Rear elevation overview",
                    "Left elevation overview",
                    "Right elevation overview",
                    "Exterior material context",
                    "Exterior opening context",
                    "Foundation perimeter context",
                    "Garage exterior context",
                    "Porch / patio context",
                    "Roof overview context"
                ].map(SecondaryTagEntry.init)),
                .init(name: "General Interior Context", secondaries: [
                    "None",
                    "Room overview",
                    "Wall overview",
                    "Ceiling overview",
                    "Floor overview",
                    "Door / window overview",
                    "Cabinet / trim overview",
                    "Stair overview",
                    "Garage interior overview"
                ].map(SecondaryTagEntry.init)),
                .init(name: "General Site / Yard Context", secondaries: [
                    "None",
                    "Yard overview",
                    "Side yard overview",
                    "Rear yard overview",
                    "Adjacent property context",
                    "Retaining wall context",
                    "Drainage path context",
                    "Hardscape context",
                    "Grade change context"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Aerial / Historical Site Context", secondaries: [
                    "None",
                    "Historical aerial image",
                    "Tree removal context",
                    "Prior tree location",
                    "Site grading context",
                    "Ponding / drainage history",
                    "Adjacent lot condition",
                    "Pre-construction site context"
                ].map(SecondaryTagEntry.init)),
                // ── Site + drainage + foundation concrete ─────────────
                .init(name: "Drainage / Grading", secondaries: [
                    "None",
                    "Adequate drainage",
                    "Marginal drainage",
                    "Flat drainage",
                    "Negative drainage toward foundation",
                    "Inadequate soil-to-finished-floor clearance",
                    "Downspout discharging near foundation",
                    "Downspout extension present",
                    "Missing or limited gutters/downspouts",
                    "Local ponding evidence",
                    "Standing water",
                    "Soil staining from ponding",
                    "Drainage swale / drainage channel",
                    "Area drain / surface drain",
                    "Trench drain / sump pit",
                    "Retaining wall drainage context",
                    "Landscape bed affecting drainage"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Foundation / Grade Beam", secondaries: [
                    "None",
                    "Grade beam crack",
                    "Foundation corner crack",
                    "Broken grade beam corner",
                    "Brick ledge crack",
                    "Foundation-to-veneer interface distress",
                    "Parge coat crack",
                    "Parge coat raveling",
                    "Parge coat crazing",
                    "Concrete spall",
                    "Anchor-related concrete damage",
                    "Poorly consolidated concrete visible",
                    "Deteriorated concrete at crack",
                    "Exposed foundation distress",
                    "Crack wider at top",
                    "Crack wider at bottom",
                    "Vertical crack",
                    "Diagonal / irregular crack",
                    "Vertical-to-diagonal crack"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Concrete Slabs - Garage / Porch / Patio / Interior", secondaries: [
                    "None",
                    "Garage slab crack",
                    "Porch slab crack",
                    "Patio slab crack",
                    "Interior slab crack",
                    "Concrete slab crack under floor finish",
                    "Differential elevation across slab crack",
                    "Displaced concrete",
                    "Slab edge crack",
                    "Concrete crazing",
                    "Slab patch",
                    "Slab breakout area",
                    "Reverse slope visible",
                    "Surface staining at slab"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Driveway and Flatwork", secondaries: [
                    "None",
                    "Driveway crack",
                    "Walkway crack",
                    "Sidewalk crack",
                    "Flatwork crack",
                    "Control-joint-adjacent crack",
                    "Panel separation",
                    "Separation from foundation",
                    "Separation at garage threshold",
                    "Elevation offset",
                    "Drop in driveway elevation",
                    "Flatwork settlement",
                    "Flatwork heave",
                    "Loss of support / void",
                    "Step / trip hazard",
                    "Pool deck flatwork movement"
                ].map(SecondaryTagEntry.init)),
                // ── Exterior cladding ─────────────────────────────────
                .init(name: "Masonry Veneer", secondaries: [
                    "None",
                    "Brick crack",
                    "Stone crack",
                    "Mortar joint crack",
                    "Stair-step crack",
                    "Vertical crack",
                    "Diagonal crack",
                    "Crack through masonry unit",
                    "Masonry separation",
                    "Masonry displacement",
                    "Masonry out of plane",
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
                    "Sealant missing at masonry",
                    "Prior masonry repair"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Stucco / Exterior Finish", secondaries: [
                    "None",
                    "Stucco crack",
                    "Stucco separation",
                    "Stucco distortion",
                    "Stucco control joint missing / limited",
                    "Stucco-to-window termination issue",
                    "Stucco-to-door termination issue",
                    "Weep screed missing / not visible",
                    "Drainage plane issue visible",
                    "Damp sheathing visible",
                    "Paint / coating distress",
                    "Prior stucco repair",
                    "Gap at cladding transition"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Exterior Trim / Siding / Soffit", secondaries: [
                    "None",
                    "Exterior trim crack",
                    "Exterior trim separation",
                    "Exterior trim misalignment",
                    "Frieze board separation",
                    "Soffit separation",
                    "Siding separation",
                    "Siding joint separation",
                    "Siding distortion",
                    "Cement board siding separation",
                    "Cement board siding too close to slab",
                    "Window trim separation",
                    "Door trim separation",
                    "Prior exterior finish repair"
                ].map(SecondaryTagEntry.init)),
                // ── Interior finish ───────────────────────────────────
                .init(name: "Interior Wall Finish", secondaries: [
                    "None",
                    "Wall sheetrock crack",
                    "Corner crack",
                    "Door / window corner crack",
                    "Wall-to-wall joint crack",
                    "Wall-to-ceiling joint crack",
                    "Wall separation",
                    "Bottom of wall separated from floor",
                    "Loose / unattached wall",
                    "Wall can be moved by hand",
                    "Out-of-plumb wall",
                    "Distorted wall framing visible",
                    "Previous wall repair",
                    "Texture / paint mismatch",
                    "Moisture stain on wall"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Interior Ceiling Finish", secondaries: [
                    "None",
                    "Ceiling sheetrock crack",
                    "Ceiling separation",
                    "Ceiling buckling",
                    "Ceiling pulled from joists",
                    "Ceiling detached from framing",
                    "Ceiling distress near stairs",
                    "Wall-to-ceiling joint crack",
                    "Previous ceiling repair",
                    "Texture / paint mismatch",
                    "Moisture stain on ceiling"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Flooring", secondaries: [
                    "None",
                    "Floor tile crack",
                    "Grout crack",
                    "Tile crack aligned with slab crack",
                    "Loose tile",
                    "Bathroom tile distress",
                    "Shower tile joint crack",
                    "Flooring joint separation",
                    "Wood flooring separation",
                    "Wood flooring hump / unevenness",
                    "Second-floor flooring separation",
                    "Rippled vinyl flooring",
                    "Uneven flooring",
                    "Floor finish separation",
                    "Previous flooring repair"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Interior Trim / Cabinets / Counters", secondaries: [
                    "None",
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
                    "None",
                    "Door out of plumb",
                    "Door racked",
                    "Door rubs frame",
                    "Door does not latch",
                    "Door difficult to open",
                    "Door jammed / inoperable",
                    "Door self-opens / self-closes",
                    "Door frame misalignment",
                    "Door frame crack / separation",
                    "Window out of plumb",
                    "Window frame separation",
                    "Window difficult to operate",
                    "Window / door functional issue",
                    "Safety / egress concern visible"
                ].map(SecondaryTagEntry.init)),
                // ── Slope / level ─────────────────────────────────────
                // "Water accumulation risk visible" dropped per user
                // direction — interpretation tag, not a visual cue.
                // The visible geometry is covered by "Exterior slab
                // drains toward house" / "Garage drains toward
                // interior" / "Porch reverse slope" / "Patio reverse
                // slope".
                .init(name: "Floor Slope / Levelness", secondaries: [
                    "None",
                    "Visible floor slope",
                    "Measured floor slope",
                    "Digital level reading shown",
                    "Level reading shown",
                    "Counter slope",
                    "Uneven floor",
                    "Garage reverse slope",
                    "Garage drains toward interior",
                    "Porch reverse slope",
                    "Patio reverse slope",
                    "Exterior slab drains toward house"
                ].map(SecondaryTagEntry.init)),
                // ── Roof + framing ────────────────────────────────────
                .init(name: "Roof / Attic Framing", secondaries: [
                    "None",
                    "Attic framing overview",
                    "Rafter twisted / warped",
                    "Rafter gap at ridge",
                    "Exposed fasteners",
                    "Loose / untight framing connection",
                    "Disconnected brace",
                    "Ridge brace issue",
                    "Purlin brace issue",
                    "Brace supported on flat member",
                    "Missing matching rafter",
                    "Scabbed framing / OSB",
                    "Scrap lumber fit-up",
                    "Notched rafter",
                    "Inadequate support visible",
                    "Truss plate / gang nail distress",
                    "Sheathing gap",
                    "Sheathing fastener issue",
                    "Ceiling pulled from framing",
                    "Moisture-stained roof sheathing"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Roofing / Roof Covering", secondaries: [
                    "None",
                    "Roof overview",
                    "Buckled shingles",
                    "Wavy / wrinkled shingles",
                    "Damaged shingles",
                    "Metal roof context",
                    "Roof edge / eave issue",
                    "Roof penetration / flashing context",
                    "Roof leak repair context",
                    "Roofing installation concern visible"
                ].map(SecondaryTagEntry.init)),
                // ── Moisture / repair / site ──────────────────────────
                .init(name: "Moisture Intrusion / Staining", secondaries: [
                    "None",
                    "Moisture stain on ceiling",
                    "Moisture stain on wall",
                    "Moisture stain on roof sheathing",
                    "Moisture stain on slab / patio",
                    "Water intrusion evidence",
                    "Localized repair from water intrusion",
                    "Damp sheathing visible",
                    "Efflorescence / mineral staining",
                    "Sealant failure with staining",
                    "Ponding-related staining"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Prior Repair / Patch", secondaries: [
                    "None",
                    "Prior foundation repair",
                    "Prior concrete patch",
                    "Prior slab breakout",
                    "Prior masonry repair",
                    "Prior stucco repair",
                    "Prior drywall repair",
                    "Prior flooring repair",
                    "Prior cosmetic repair",
                    "Patch visible",
                    "Texture / paint mismatch",
                    "Crack through prior repair",
                    "Recurrent distress",
                    "Repair excavation not fully backfilled"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Soil / Backfill / Excavation", secondaries: [
                    "None",
                    "Soil erosion",
                    "Soil void",
                    "Incomplete backfill",
                    "Exposed excavation area",
                    "Backfill settlement",
                    "Soil against foundation",
                    "Low clearance to soil",
                    "Concrete curb against foundation",
                    "Landscape border near foundation",
                    "Soil moisture indicator",
                    "Exposed root / root-zone context"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Trees / Vegetation / Landscaping", secondaries: [
                    "None",
                    "Mature tree near foundation",
                    "Removed tree area",
                    "Prior tree location",
                    "Tree root zone near foundation",
                    "Vegetation near foundation",
                    "Flower bed near foundation",
                    "Landscape border near foundation",
                    "Landscaping affects drainage",
                    "Vegetation / moisture context"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Pool / Gazebo / Site Structure", secondaries: [
                    "None",
                    "Pool overview",
                    "Pool waterline uneven",
                    "Pool coping movement",
                    "Pool deck movement",
                    "Gazebo overview",
                    "Gazebo foundation distress",
                    "Gazebo parge coat crack",
                    "Erosion below gazebo foundation",
                    "Column joint separation",
                    "Step crack / distress",
                    "Retaining wall context",
                    "Retaining wall distress"
                ].map(SecondaryTagEntry.init)),
                // ── Measurement / photo quality ───────────────────────
                .init(name: "Measurement / Instrument Readout", secondaries: [
                    "None",
                    "Ruler / tape visible",
                    "Crack comparator visible",
                    "Digital level visible",
                    "ZipLevel / elevation equipment visible",
                    "Measurement number visible",
                    "Crack width measurement",
                    "Floor slope measurement",
                    "Elevation reading",
                    "Scale reference present",
                    "Measurement unclear / obstructed"
                ].map(SecondaryTagEntry.init)),
                .init(name: "Photo Quality / Re-shoot", secondaries: [
                    "None",
                    "Blurry image",
                    "Too dark",
                    "Overexposed",
                    "Obstructed view",
                    "Too close to identify component",
                    "Too far to see distress",
                    "Distress cropped off",
                    "Measurement unreadable",
                    "Location not discernible"
                ].map(SecondaryTagEntry.init))
            ])
        ],
        seedVersion: TagLibrary.currentSeedVersion
    )
}
