import Foundation

/// Static seed for the primary→secondary tag vocabulary. After the
/// tag-library rework, the runtime source of truth is
/// `ProjectStore.tagLibrary` (seeded from `TagLibrary.defaultSeeds`) —
/// this file is kept around so:
///   * `ValidationVocabulary.fallback` has a sensible default for unit
///     tests / unmigrated call paths,
///   * tag-sorting helpers (`primaryRank`, `primaries`,
///     `primariesLowercased`) can rank primaries in canonical order
///     without needing a `ProjectStore` reference,
///   * `Photo.swift`'s legacy "Primary / Secondary" flat-label
///     splitting can decide whether the left half is actually a
///     primary tag.
enum ControlledVocabulary {

    /// Primary → ordered secondaries, in the canonical seed order.
    /// Order matters because the filter UI
    /// and the batch-summary breakdown both render in this sequence.
    static let entries: [(primary: String, secondaries: [String])] = [
        ("Drainage / Grading", [
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
        ]),
        ("Regional Ponding / Site Moisture", [
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
        ]),
        ("Foundation / Slab", [
            "None",
            "Grade beam crack",
            "Slab crack",
            "Garage slab crack",
            "Porch slab crack",
            "Patio slab crack",
            "Interior slab crack",
            "Crack wider at top",
            "Crack wider at bottom",
            "Vertical-to-diagonal crack",
            "Diagonal / irregular crack",
            "Concrete spall",
            "Broken grade beam corner",
            "Displaced concrete",
            "Parge coat raveling",
            "Foundation-to-veneer interface distress",
            "Anchor-related concrete damage",
            "Exposed foundation distress"
        ]),
        ("Driveway / Flatwork", [
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
        ]),
        ("Masonry", [
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
        ]),
        ("Stucco", [
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
        ]),
        ("Exterior Trim / Siding", [
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
        ]),
        ("Walls", [
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
        ]),
        ("Ceilings", [
            "None",
            "Ceiling sheetrock crack",
            "Ceiling separation",
            "Ceiling buckling",
            "Ceiling pulled from joists",
            "Ceiling detached from framing",
            "Ceiling distress near stairs",
            "Previous ceiling repair"
        ]),
        ("Flooring", [
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
        ]),
        ("Interior Trim / Cabinets / Counters", [
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
        ]),
        ("Doors / Windows", [
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
        ]),
        ("Floor Slope / Levelness", [
            "None",
            "Visible floor slope",
            "Measured floor slope",
            "Significant floor slope",
            "Uneven floor",
            "Overall tilt indicator",
            "Localized deflection indicator",
            "Counter slope",
            "Level reading shown"
        ]),
        ("Garage / Porch Slope", [
            "None",
            "Garage reverse slope",
            "Garage drains toward interior",
            "Porch reverse slope",
            "Porch flat / inadequate slope",
            "Patio inadequate slope",
            "Exterior slab drains toward house",
            "Potential water accumulation at house"
        ]),
        ("Roof / Roofing", [
            "None",
            "Roof overview",
            "Roof drainage feature",
            "Gutter present",
            "Downspout present",
            "Limited gutter coverage",
            "Roof runoff discharge location",
            "Roof covering context"
        ]),
        ("Attic / Framing", [
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
        ]),
        ("Stairs", [
            "None",
            "Excessive riser height",
            "Non-uniform riser heights",
            "Stair geometry issue",
            "Stair safety issue",
            "Stair movement / distortion",
            "Stair finish distress"
        ]),
        ("Prior Repair / Patch", [
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
        ]),
        ("Soil / Backfill", [
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
        ]),
        ("Trees / Vegetation", [
            "None",
            "Mature tree near foundation",
            "Removed tree area",
            "Prior tree location",
            "Tree root zone near foundation",
            "Vegetation near foundation",
            "Flower bed near foundation",
            "Landscape border near foundation",
            "Vegetation / moisture context"
        ]),
        ("General Exterior Context", [
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
        ]),
        ("General Interior Context", [
            "None",
            "Room overview",
            "Hallway overview",
            "Interior orientation photo",
            "General finish context",
            "No visible distress"
        ]),
        ("Poor / Unclear Photo", [
            "None",
            "Poor lighting",
            "Blurry photo",
            "Too close / no context",
            "No scale",
            "Obstructed view",
            "Location unclear",
            "Distress unclear",
            "Cannot determine condition"
        ])
    ]

    /// Canonical primary names in guide order. Used for sorting in the
    /// filter UI, the photo-row chip strip, and the batch summary.
    static let primaries: [String] = entries.map { $0.primary }

    /// Lowercased primary lookup set — fast membership tests when
    /// recognising a user-typed string against the controlled list.
    static let primariesLowercased: Set<String> = Set(primaries.map { $0.lowercased() })

    /// Lowercased primary → ordered secondaries (case-preserved) for
    /// validator lookups. Lowercasing the key tolerates capitalisation
    /// drift in Claude's responses; the secondary values stay in their
    /// canonical casing for display.
    private static let secondariesByPrimaryLC: [String: [String]] = {
        Dictionary(uniqueKeysWithValues:
            entries.map { ($0.primary.lowercased(), $0.secondaries) })
    }()

    /// Lowercased (primary, secondary) set for fast membership tests in
    /// the validator. "None" is universal — every primary admits it.
    private static let validPairsLC: Set<String> = {
        var out: Set<String> = []
        for e in entries {
            for sec in e.secondaries {
                out.insert(pairKey(primary: e.primary, secondary: sec))
            }
        }
        return out
    }()

    /// Secondaries listed under `primary` (case-insensitive), or nil if
    /// the primary isn't in the controlled vocabulary.
    static func secondaries(for primary: String) -> [String]? {
        secondariesByPrimaryLC[primary.lowercased()]
    }

    /// True when `secondary` is verbatim under `primary` in the vocabulary
    /// (case-insensitive on both sides). "None" always validates.
    static func isValid(secondary: String, under primary: String) -> Bool {
        let s = secondary.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased() == "none" { return true }
        return validPairsLC.contains(pairKey(primary: primary, secondary: s))
    }

    /// True when `primary` is one of the 23 controlled categories.
    static func isValidPrimary(_ primary: String) -> Bool {
        primariesLowercased.contains(primary.lowercased())
    }

    /// 0-based rank of `primary` in canonical order, or `Int.max` for an
    /// unknown name. Drives sort order in the filter UI and summaries.
    static func primaryRank(_ primary: String) -> Int {
        let lc = primary.lowercased()
        return primaries.firstIndex(where: { $0.lowercased() == lc }) ?? Int.max
    }

    private static func pairKey(primary: String, secondary: String) -> String {
        primary.lowercased() + "|" + secondary.lowercased()
    }
}
