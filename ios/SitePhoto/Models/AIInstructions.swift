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
    Review each photo and assign it to one or more of the following \
    observation buckets. Do not create new buckets. Do not use detailed \
    tags. Select only the most important bucket or buckets needed to \
    categorize the photo.

    Use no more than 2 buckets per photo unless the photo clearly shows \
    multiple unrelated conditions.

    Observation Buckets:

    1. Drainage / grading issue
    2. Regional ponding / site moisture context
    3. Foundation or slab crack / concrete distress
    4. Driveway / flatwork movement
    5. Masonry cracking or separation
    6. Stucco cracking or separation
    7. Exterior trim / siding separation
    8. Interior wall or ceiling cracking
    9. Interior trim / flooring / cabinet separation
    10. Wall framing / wall attachment distress
    11. Door or window operation issue
    12. Floor slope / unevenness
    13. Garage / porch reverse slope
    14. Roof / attic framing issue
    15. Stair geometry / stair safety issue
    16. Prior repair / patch / recurring distress
    17. Soil erosion / backfill issue
    18. Tree / vegetation / site moisture context
    19. General exterior context
    20. General interior context
    21. No visible distress
    22. Poor / unclear photo

    For each photo, output only:

    Observation Bucket(s):
    Severity:
    Summary Observation:

    Severity must be one of:
    None / Minor / Moderate / Significant / Severe / Cannot Determine

    Summary Observation:
    Provide one concise sentence describing what the photo shows and why \
    it may be relevant to a foundation investigation. Use cautious, \
    observation-based language. Do not state final causation from the \
    photo alone.

    Rules:
    - Do not invent additional categories.
    - Do not tag every visible object.
    - Focus only on conditions relevant to foundation performance, \
    structural distress, drainage, prior repair, construction quality, \
    safety, or serviceability.
    - Use "Masonry cracking or separation" for brick, stone, mortar \
    joints, masonry veneer, masonry corners, masonry expansion joints, \
    masonry-to-trim gaps, and masonry-to-wall/floor separations such as \
    fireplace masonry separation.
    - Use "Stucco cracking or separation" only for stucco cladding, \
    stucco cracks, stucco panel distress, stucco separation, or stucco \
    repair/patch conditions.
    - Use "Regional ponding / site moisture context" for drone views, \
    aerial views, recurring ponding, broad area drainage patterns, or \
    standing water affecting multiple lots.
    - Use "Drainage / grading issue" for localized grading, downspouts, \
    surface slope, poor clearance between soil and finished floor, or \
    water accumulation immediately near the foundation.
    - Use "Foundation or slab crack / concrete distress" for visible \
    foundation cracks, grade beam cracks, slab cracks, concrete spalls, \
    broken concrete, or anchor-related concrete damage.
    - Use "Wall framing / wall attachment distress" for loose walls, \
    wall bottoms separating from the floor, distorted wall framing, or \
    apparent wall-to-foundation attachment issues.
    - Use "Garage / porch reverse slope" when a garage slab, porch, or \
    exterior slab appears to drain toward the house or interior.
    - Use "Stair geometry / stair safety issue" for stair riser height, \
    stair uniformity, tread/riser irregularity, or visible stair \
    movement/distortion.
    - If the photo is mostly contextual, use General Exterior Context or \
    General Interior Context.
    - If distress is not clearly visible, use No Visible Distress.
    - If the photo quality or angle prevents reliable review, use Poor / \
    Unclear Photo.
    - Use cautious categorization. Do not state or imply final causation \
    from the photo alone.
    - Use no more than 2 observation buckets per photo unless clearly \
    necessary.
    - Keep the Summary Observation to one sentence.
    - In the Summary Observation, use phrases such as "visible," \
    "appears," "may be relevant to," "may be consistent with," or \
    "should be correlated with."
    """
}
