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
    2. Foundation or slab crack
    3. Driveway / flatwork movement
    4. Masonry cracking or separation
    5. Exterior trim / siding separation
    6. Interior wall or ceiling cracking
    7. Interior trim / flooring / cabinet separation
    8. Door or window operation issue
    9. Floor slope / unevenness
    10. Roof / attic framing issue
    11. Prior repair / patch / recurring distress
    12. Soil erosion / backfill issue
    13. Tree / vegetation / site moisture context
    14. General exterior context
    15. General interior context
    16. No visible distress
    17. Poor / unclear photo

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
    structural distress, drainage, prior repair, or serviceability.
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
