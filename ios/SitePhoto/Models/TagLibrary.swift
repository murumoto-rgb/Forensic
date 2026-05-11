import Foundation

/// App-wide three-level catalog of investigation contexts, primary tags,
/// and secondary tags used by the AI tagging pipeline. The engineer
/// extends this library through the Tag Library Manager — additions are
/// visible to every existing and future project on the device.
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
struct TagLibrary: Codable, Hashable, Sendable {
    var contexts: [InvestigationContext]

    init(contexts: [InvestigationContext] = []) {
        self.contexts = contexts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contexts = try c.decodeIfPresent([InvestigationContext].self,
                                               forKey: .contexts) ?? []
    }
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

// MARK: - Default seeds

extension TagLibrary {
    /// Bundled starter pack populated the first time the app launches on
    /// a device (i.e. when `tagLibrary.json` doesn't exist yet). The
    /// engineer can rename, reorder, delete, or extend any of these —
    /// they're seeds, not protected entries.
    ///
    /// "None" is treated as a regular secondary because every other
    /// secondary list in the pack carries it; keeping it in-data lets
    /// the engineer remove it intentionally on a per-primary basis if
    /// they don't want it offered to the AI for that tag.
    static let defaultSeeds: TagLibrary = TagLibrary(contexts: [
        // ── Foundation Performance ─────────────────────────────────────
        .init(name: "Foundation Performance", primaries: [
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
                "Local ponding near foundation",
                "Drainage swale / drainage channel",
                "Area drain / surface drain",
                "Landscape bed affecting drainage"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Regional Ponding / Site Moisture", secondaries: [
                "None",
                "Standing water",
                "Recurring ponding",
                "Broad area drainage condition",
                "Ponding at adjacent properties",
                "Ponding near rear property line",
                "Historical aerial ponding evidence",
                "Soil discoloration from prior ponding",
                "Frequently ponded soil context",
                "Site moisture context"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Foundation - Exterior", secondaries: [
                "None",
                "Grade beam crack",
                "Slab crack",
                "Garage slab crack",
                "Porch slab crack",
                "Patio slab crack",
                "Crack wider at top",
                "Crack wider at bottom",
                "Vertical-to-diagonal crack",
                "Diagonal / irregular crack",
                "Concrete spall",
                "Broken grade beam corner",
                "Parge coat raveling",
                "Foundation-to-veneer interface distress",
                "Anchor-related concrete damage",
                "Exposed foundation distress"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Foundation - Interior", secondaries: [
                "None",
                "Interior slab crack",
                "Displaced concrete"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Driveway and Flatwork", secondaries: [
                "None",
                "Driveway crack",
                "Walkway crack",
                "Flatwork crack",
                "Panel separation",
                "Separation from foundation",
                "Elevation offset",
                "Drop in driveway elevation",
                "Flatwork settlement",
                "Flatwork heave",
                "Step / trip hazard",
                "Patio / porch flatwork movement"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Masonry", secondaries: [
                "None",
                "Brick crack",
                "Stone crack",
                "Mortar joint crack",
                "Stair-step crack",
                "Vertical crack",
                "Diagonal crack",
                "Masonry separation",
                "Masonry-to-trim separation",
                "Masonry-to-siding separation",
                "Masonry-to-wall separation",
                "Masonry-to-floor separation",
                "Fireplace masonry separation",
                "Expansion joint wide / stretched",
                "Expansion joint compressed",
                "Expansion joint torn / failed",
                "Sealant missing at masonry",
                "Sealant cracked at masonry",
                "Sealant stretched at masonry",
                "Prior masonry repair"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Exterior Trim / Siding", secondaries: [
                "None",
                "Exterior trim crack",
                "Exterior trim separation",
                "Exterior trim misalignment",
                "Siding separation",
                "Siding joint separation",
                "Siding distortion",
                "Cement board siding separation",
                "Gap at cladding transition",
                "Window trim separation",
                "Door trim separation",
                "Prior exterior finish repair"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Walls", secondaries: [
                "None",
                "Wall sheetrock crack",
                "Corner crack",
                "Door / window corner crack",
                "Wall separation",
                "Bottom of wall separated from floor",
                "Loose / unattached wall",
                "Wall can be moved by hand",
                "Out-of-plumb wall",
                "Distorted wall framing",
                "Wall framing movement",
                "Previous wall repair"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Ceilings", secondaries: [
                "None",
                "Ceiling sheetrock crack",
                "Ceiling separation",
                "Ceiling buckling",
                "Ceiling pulled from joists",
                "Ceiling detached from framing",
                "Ceiling distress near stairs",
                "Previous ceiling repair"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Flooring", secondaries: [
                "None",
                "Floor tile crack",
                "Tile crack aligned with slab crack",
                "Bathroom tile distress",
                "Flooring joint separation",
                "Second-floor flooring separation",
                "Rippled vinyl flooring",
                "Uneven flooring",
                "Floor finish separation",
                "Floor finish distress",
                "Previous flooring repair"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Interior Trim / Cabinets / Counters", secondaries: [
                "None",
                "Baseboard separation",
                "Baseboard distortion",
                "Interior trim separation",
                "Door frame separation",
                "Cabinet separation from wall",
                "Countertop slope",
                "Counter / cabinet misalignment",
                "Windowsill separation",
                "Previous trim repair"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Doors / Windows", secondaries: [
                "None",
                "Door out of plumb",
                "Door racked",
                "Door does not latch",
                "Door self-opens / self-closes",
                "Door frame misalignment",
                "Window out of plumb",
                "Window frame separation",
                "Window difficult to operate",
                "Window / door functional issue"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Floor Slope / Levelness", secondaries: [
                "None",
                "Visible floor slope",
                "Measured floor slope",
                "Significant floor slope",
                "Uneven floor",
                "Overall tilt indicator",
                "Localized deflection indicator",
                "Counter slope",
                "Level reading shown"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Garage / Porch Slope", secondaries: [
                "None",
                "Garage reverse slope",
                "Garage drains toward interior",
                "Porch reverse slope",
                "Porch flat / inadequate slope",
                "Patio inadequate slope",
                "Exterior slab drains toward house",
                "Potential water accumulation at house"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Prior Repair / Patch", secondaries: [
                "None",
                "Prior foundation repair",
                "Prior concrete patch",
                "Prior slab breakout",
                "Prior masonry repair",
                "Prior drywall repair",
                "Prior cosmetic repair",
                "Crack through prior repair",
                "Recurrent distress",
                "Patch visible",
                "Texture / paint mismatch",
                "Repair excavation not fully backfilled"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Soil / Backfill", secondaries: [
                "None",
                "Soil erosion",
                "Soil void",
                "Incomplete backfill",
                "Exposed excavation area",
                "Soil against foundation",
                "Concrete curb against foundation",
                "Low clearance to soil",
                "Backfill settlement",
                "Soil moisture indicator"
            ].map(SecondaryTagEntry.init)),
            .init(name: "Trees / Vegetation", secondaries: [
                "None",
                "Mature tree near foundation",
                "Removed tree area",
                "Prior tree location",
                "Tree root zone near foundation",
                "Vegetation near foundation",
                "Flower bed near foundation",
                "Landscape border near foundation",
                "Vegetation / moisture context"
            ].map(SecondaryTagEntry.init))
        ]),

        // ── Roofing ────────────────────────────────────────────────────
        .init(name: "Roofing", primaries: [
            .init(name: "Roofing", secondaries: [
                "None",
                "Roof overview",
                "Roof drainage feature",
                "Gutter present",
                "Downspout present",
                "Limited gutter coverage",
                "Roof runoff discharge location",
                "Roof covering context",
                "Shingles wavy",
                "Deck deflection visible",
                "Ridge deflection visible"
            ].map(SecondaryTagEntry.init))
        ]),

        // ── Framing ────────────────────────────────────────────────────
        .init(name: "Framing", primaries: [
            .init(name: "Attic / Framing", secondaries: [
                "None",
                "Rafter twisted / warped",
                "Missing opposing rafter",
                "Rafter-to-ridge separation",
                "Rafter-to-valley separation",
                "Framing connection gap",
                "Loose framing connection",
                "Exposed fasteners",
                "Inadequate rafter support",
                "Purlin support issue",
                "Purlin brace supported on joist",
                "LVL / transfer beam support issue",
                "Improper framing fit-up",
                "Scrap lumber used for fit-up",
                "OSB scab patch",
                "Sheathing gap",
                "Rodent-sized opening",
                "Spray foam limits visibility",
                "Ceiling pulled from framing"
            ].map(SecondaryTagEntry.init))
        ]),

        // ── Stairs ─────────────────────────────────────────────────────
        .init(name: "Stairs", primaries: [
            .init(name: "Stair construction", secondaries: [
                "None",
                "Excessive riser height",
                "Non-uniform riser heights",
                "Stair geometry issue",
                "Stair safety issue",
                "Stair movement / distortion",
                "Stair finish distress"
            ].map(SecondaryTagEntry.init))
        ]),

        // ── Overall Views ──────────────────────────────────────────────
        .init(name: "Overall Views", primaries: [
            .init(name: "General Exterior Context", secondaries: [
                "None",
                "Front exterior overview",
                "Rear exterior overview",
                "Left side exterior overview",
                "Right side exterior overview",
                "Aerial / drone overview",
                "Site context",
                "Neighborhood context",
                "Exterior orientation photo",
                "No visible distress"
            ].map(SecondaryTagEntry.init)),
            .init(name: "General Interior Context", secondaries: [
                "None",
                "Room overview",
                "Hallway overview",
                "Interior orientation photo",
                "General finish context",
                "No visible distress"
            ].map(SecondaryTagEntry.init))
        ]),

        // ── Stucco ─────────────────────────────────────────────────────
        .init(name: "Stucco", primaries: [
            .init(name: "Stucco Construction", secondaries: [
                "None",
                "Stucco crack",
                "Vertical stucco crack",
                "Diagonal stucco crack",
                "Stucco separation",
                "Stucco panel distress",
                "Stucco patch / prior repair",
                "Stucco shrinkage-type cracking",
                "Stucco-to-trim separation",
                "Stucco-to-foundation separation"
            ].map(SecondaryTagEntry.init))
        ]),

        // ── Photo Quality ──────────────────────────────────────────────
        .init(name: "Photo Quality", primaries: [
            .init(name: "Poor / Unclear Photo", secondaries: [
                "None",
                "Poor lighting",
                "Blurry photo",
                "Obstructed view"
            ].map(SecondaryTagEntry.init))
        ])
    ])
}
