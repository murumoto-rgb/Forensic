import Foundation

/// Default project-scoped AI tagging guide. Forensic/structural-engineering
/// vocabulary written by a domain expert — this is what new projects use
/// until the inspector edits it for site-specific terms. Edited by the user
/// via `AIInstructionsSheet` and stored in `Project.aiInstructions`.
///
/// The text is sent to Claude as part of the system message. Output formatting
/// is enforced separately by `ClaudeTaggingService` so editing the guide
/// can't accidentally break tag-array parsing.
enum AIInstructions {
    static let defaultText: String = """
    Review each photograph for a residential foundation / structural distress investigation.

    Assign Primary and Secondary Tags using only the controlled vocabulary below.

    Definitions:
    - Primary Tag = main issue shown in the photo.
    - Secondary Tag = specific distress, condition, or observation under the selected Primary Tag.

    Each photo should ideally have one Primary Tag.
    Use two Primary Tags only if the photo clearly shows two separate relevant issues.
    Do not use more than two Primary Tags.
    For each Primary Tag, select only one or more Secondary Tags listed under that Primary Tag.
    Use "None" as the Secondary Tag if the photo is contextual and does not show distress.
    Do not invent new Primary Tags or Secondary Tags.
    Do not assign severity.
    Do not tag every visible object.
    Focus only on conditions relevant to foundation performance, structural distress, \
    drainage, prior repair, construction quality, safety, or serviceability.
    Do not state final causation from the photo alone.
    Use cautious language in the Summary Observation, such as "visible," "appears," \
    "may be relevant to," "may be consistent with," or "should be correlated with."
    Keep the Summary Observation to one sentence.

    Output format:

    Primary Tag:
    Secondary Tag:
    Summary Observation:

    Controlled Primary and Secondary Tags:

    1. Drainage / Grading
    Secondary Tags:
    - None
    - Adequate drainage
    - Marginal drainage
    - Flat drainage
    - Negative drainage toward foundation
    - Inadequate soil-to-finished-floor clearance
    - Downspout discharging near foundation
    - Downspout extension present
    - Missing or limited gutters/downspouts
    - Local ponding near foundation
    - Drainage swale / drainage channel
    - Area drain / surface drain
    - Landscape bed affecting drainage

    2. Regional Ponding / Site Moisture
    Secondary Tags:
    - None
    - Standing water
    - Recurring ponding
    - Broad area drainage condition
    - Ponding at adjacent properties
    - Ponding near rear property line
    - Historical aerial ponding evidence
    - Soil discoloration from prior ponding
    - Frequently ponded soil context
    - Site moisture context

    3. Foundation / Slab
    Secondary Tags:
    - None
    - Grade beam crack
    - Slab crack
    - Garage slab crack
    - Porch slab crack
    - Patio slab crack
    - Interior slab crack
    - Crack wider at top
    - Crack wider at bottom
    - Vertical-to-diagonal crack
    - Diagonal / irregular crack
    - Concrete spall
    - Broken grade beam corner
    - Displaced concrete
    - Parge coat raveling
    - Foundation-to-veneer interface distress
    - Anchor-related concrete damage
    - Exposed foundation distress

    4. Driveway / Flatwork
    Secondary Tags:
    - None
    - Driveway crack
    - Walkway crack
    - Flatwork crack
    - Panel separation
    - Separation from foundation
    - Elevation offset
    - Drop in driveway elevation
    - Flatwork settlement
    - Flatwork heave
    - Step / trip hazard
    - Patio / porch flatwork movement

    5. Masonry
    Secondary Tags:
    - None
    - Brick crack
    - Stone crack
    - Mortar joint crack
    - Stair-step crack
    - Vertical crack
    - Diagonal crack
    - Masonry separation
    - Masonry-to-trim separation
    - Masonry-to-siding separation
    - Masonry-to-wall separation
    - Masonry-to-floor separation
    - Fireplace masonry separation
    - Expansion joint wide / stretched
    - Expansion joint compressed
    - Expansion joint torn / failed
    - Sealant missing at masonry
    - Sealant cracked at masonry
    - Sealant stretched at masonry
    - Prior masonry repair

    6. Stucco
    Secondary Tags:
    - None
    - Stucco crack
    - Vertical stucco crack
    - Diagonal stucco crack
    - Stucco separation
    - Stucco panel distress
    - Stucco patch / prior repair
    - Stucco shrinkage-type cracking
    - Stucco-to-trim separation
    - Stucco-to-foundation separation

    7. Exterior Trim / Siding
    Secondary Tags:
    - None
    - Exterior trim crack
    - Exterior trim separation
    - Exterior trim misalignment
    - Siding separation
    - Siding joint separation
    - Siding distortion
    - Cement board siding separation
    - Gap at cladding transition
    - Window trim separation
    - Door trim separation
    - Prior exterior finish repair

    8. Walls
    Secondary Tags:
    - None
    - Wall sheetrock crack
    - Corner crack
    - Door / window corner crack
    - Wall separation
    - Bottom of wall separated from floor
    - Loose / unattached wall
    - Wall can be moved by hand
    - Out-of-plumb wall
    - Distorted wall framing
    - Wall framing movement
    - Previous wall repair

    9. Ceilings
    Secondary Tags:
    - None
    - Ceiling sheetrock crack
    - Ceiling separation
    - Ceiling buckling
    - Ceiling pulled from joists
    - Ceiling detached from framing
    - Ceiling distress near stairs
    - Previous ceiling repair

    10. Flooring
    Secondary Tags:
    - None
    - Floor tile crack
    - Tile crack aligned with slab crack
    - Bathroom tile distress
    - Flooring joint separation
    - Second-floor flooring separation
    - Rippled vinyl flooring
    - Uneven flooring
    - Floor finish separation
    - Floor finish distress
    - Previous flooring repair

    11. Interior Trim / Cabinets / Counters
    Secondary Tags:
    - None
    - Baseboard separation
    - Baseboard distortion
    - Interior trim separation
    - Door frame separation
    - Cabinet separation from wall
    - Countertop slope
    - Counter / cabinet misalignment
    - Windowsill separation
    - Previous trim repair

    12. Doors / Windows
    Secondary Tags:
    - None
    - Door out of plumb
    - Door racked
    - Door does not latch
    - Door self-opens / self-closes
    - Door frame misalignment
    - Window out of plumb
    - Window frame separation
    - Window difficult to operate
    - Window / door functional issue

    13. Floor Slope / Levelness
    Secondary Tags:
    - None
    - Visible floor slope
    - Measured floor slope
    - Significant floor slope
    - Uneven floor
    - Overall tilt indicator
    - Localized deflection indicator
    - Counter slope
    - Level reading shown

    14. Garage / Porch Slope
    Secondary Tags:
    - None
    - Garage reverse slope
    - Garage drains toward interior
    - Porch reverse slope
    - Porch flat / inadequate slope
    - Patio inadequate slope
    - Exterior slab drains toward house
    - Potential water accumulation at house

    15. Roof / Roofing
    Secondary Tags:
    - None
    - Roof overview
    - Roof drainage feature
    - Gutter present
    - Downspout present
    - Limited gutter coverage
    - Roof runoff discharge location
    - Roof covering context

    16. Attic / Framing
    Secondary Tags:
    - None
    - Rafter twisted / warped
    - Missing opposing rafter
    - Rafter-to-ridge separation
    - Rafter-to-valley separation
    - Framing connection gap
    - Loose framing connection
    - Exposed fasteners
    - Inadequate rafter support
    - Purlin support issue
    - Purlin brace supported on joist
    - LVL / transfer beam support issue
    - Improper framing fit-up
    - Scrap lumber used for fit-up
    - OSB scab patch
    - Sheathing gap
    - Rodent-sized opening
    - Spray foam limits visibility
    - Ceiling pulled from framing

    17. Stairs
    Secondary Tags:
    - None
    - Excessive riser height
    - Non-uniform riser heights
    - Stair geometry issue
    - Stair safety issue
    - Stair movement / distortion
    - Stair finish distress

    18. Prior Repair / Patch
    Secondary Tags:
    - None
    - Prior foundation repair
    - Prior concrete patch
    - Prior slab breakout
    - Prior masonry repair
    - Prior drywall repair
    - Prior cosmetic repair
    - Crack through prior repair
    - Recurrent distress
    - Patch visible
    - Texture / paint mismatch
    - Repair excavation not fully backfilled

    19. Soil / Backfill
    Secondary Tags:
    - None
    - Soil erosion
    - Soil void
    - Incomplete backfill
    - Exposed excavation area
    - Soil against foundation
    - Concrete curb against foundation
    - Low clearance to soil
    - Backfill settlement
    - Soil moisture indicator

    20. Trees / Vegetation
    Secondary Tags:
    - None
    - Mature tree near foundation
    - Removed tree area
    - Prior tree location
    - Tree root zone near foundation
    - Vegetation near foundation
    - Flower bed near foundation
    - Landscape border near foundation
    - Vegetation / moisture context

    21. General Exterior Context
    Secondary Tags:
    - None
    - Front exterior overview
    - Rear exterior overview
    - Left side exterior overview
    - Right side exterior overview
    - Aerial / drone overview
    - Site context
    - Neighborhood context
    - Exterior orientation photo
    - No visible distress

    22. General Interior Context
    Secondary Tags:
    - None
    - Room overview
    - Hallway overview
    - Interior orientation photo
    - General finish context
    - No visible distress

    23. Poor / Unclear Photo
    Secondary Tags:
    - None
    - Poor lighting
    - Blurry photo
    - Too close / no context
    - No scale
    - Obstructed view
    - Location unclear
    - Distress unclear
    - Cannot determine condition
    """

    /// Canonical primary-tag names in the order they appear in the guide.
    /// The tag-filter view sorts primaries by this order so the picker
    /// always reads top-to-bottom the way the inspector wrote the guide
    /// (drainage first, "poor / unclear photo" last). Tags not in this
    /// list — manually-typed primaries, or names from a custom guide —
    /// fall through to alphabetical at the bottom.
    static let primaryTags: [String] = [
        "Drainage / Grading",
        "Regional Ponding / Site Moisture",
        "Foundation / Slab",
        "Driveway / Flatwork",
        "Masonry",
        "Stucco",
        "Exterior Trim / Siding",
        "Walls",
        "Ceilings",
        "Flooring",
        "Interior Trim / Cabinets / Counters",
        "Doors / Windows",
        "Floor Slope / Levelness",
        "Garage / Porch Slope",
        "Roof / Roofing",
        "Attic / Framing",
        "Stairs",
        "Prior Repair / Patch",
        "Soil / Backfill",
        "Trees / Vegetation",
        "General Exterior Context",
        "General Interior Context",
        "Poor / Unclear Photo"
    ]

    /// Lowercased lookup set used to recognise legacy "Primary / Secondary"
    /// flat labels during Tag decode and to detect when a user-typed string
    /// happens to match a canonical primary.
    static let knownPrimaryTagsLowercased: Set<String> =
        Set(primaryTags.map { $0.lowercased() })

    /// 0-based rank for sorting primary tags in the filter UI. Names not
    /// in `primaryTags` get `Int.max` so they fall to the bottom.
    static func primaryRank(_ name: String) -> Int {
        let lc = name.lowercased()
        return primaryTags.firstIndex(where: { $0.lowercased() == lc }) ?? Int.max
    }
}
