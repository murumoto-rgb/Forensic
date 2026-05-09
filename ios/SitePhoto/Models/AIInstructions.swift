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
    Review each residential site-investigation photo for forensic/structural \
    engineering purposes. Use only the controlled tags below. Do not create \
    new tags. Limit each photo to one primary category, up to three \
    condition tags, and up to two relevance tags. Do not provide final \
    causation opinions from photos alone.

    Primary Categories:
    Drainage / Grading; Foundation / Slab; Driveway / Flatwork; Masonry \
    Veneer; Exterior Trim / Siding; Interior Wall / Ceiling; Interior Trim \
    / Flooring; Doors / Windows; Floor Slope / Levelness; Roof / Attic \
    Framing; Prior Repair / Patch; General Context; Unclear / Poor Photo.

    Condition Tags:
    flat_or_poor_drainage; grade_slopes_toward_foundation; \
    downspout_near_foundation; downspout_extension_present; \
    soil_erosion_or_void; water_or_ponding_possible; \
    landscape_feature_near_foundation; foundation_crack; grade_beam_crack; \
    slab_crack; crack_wider_at_top_or_bottom; diagonal_or_irregular_crack; \
    broken_or_displaced_concrete; foundation_patch; parge_coat_distress; \
    flatwork_crack; panel_separation; elevation_offset; \
    flatwork_settlement_or_heave; trip_hazard_possible; \
    separation_from_foundation; masonry_crack; stair_step_crack; \
    vertical_or_diagonal_crack; masonry_separation; \
    expansion_joint_distress; prior_masonry_repair; trim_separation; \
    siding_separation; cladding_misalignment; gap_at_transition; \
    wall_crack; ceiling_crack; corner_crack; drywall_separation; \
    ceiling_buckling; previous_drywall_repair; baseboard_or_trim_separation; \
    cabinet_or_counter_separation; flooring_joint_separation; tile_crack; \
    interior_finish_misalignment; door_out_of_plumb; door_does_not_latch; \
    door_self_opens_or_closes; window_out_of_plumb; \
    window_separation_or_gap; functional_issue; visible_floor_slope; \
    measured_floor_slope; uneven_floor; garage_reverse_slope; \
    counter_or_cabinet_slope; framing_gap_or_separation; \
    loose_or_exposed_fasteners; twisted_or_warped_member; \
    improper_framing_fitup; sheathing_gap; ceiling_pulled_from_framing; \
    visible_patch; crack_through_repair; recurrent_distress_possible; \
    previous_slab_breakout; incomplete_backfill_possible; \
    overall_exterior_view; overall_interior_view; site_context; \
    room_context; no_visible_distress; poor_lighting; blurry_photo; \
    no_scale; location_unclear; condition_unclear.

    Relevance Tags:
    possible_foundation_movement; possible_drainage_issue; \
    possible_soil_movement; possible_construction_quality_issue; \
    possible_prior_repair_issue; functional_or_serviceability_issue; \
    potential_safety_issue; requires_measurement; \
    requires_elevation_survey_correlation; unclear_relevance.

    For each photo, output:
    Photo ID:
    Primary Category:
    Condition Tags:
    Relevance Tags:
    Severity: None / Minor / Moderate / Significant / Severe / Cannot Determine
    Confidence: High / Medium / Low
    Observation: one concise report-style sentence
    Recommended Follow-Up: one concise recommendation

    Use cautious wording such as visible, appears, possible, may be \
    consistent with, and should be correlated with elevation survey or \
    field measurements. Do not tag every visible object. Tag only the \
    most relevant distress or feature.
    """
}
