import Foundation

/// App-wide template for the schema + field definitions + general rules
/// block sent at the top of Claude's system prompt. Stable across
/// projects — the per-project vocabulary lives in `ProjectTagSelection`
/// and gets appended below this template at request time.
///
/// The engineer edits this through `AIRulesTemplateSheet`, opened from
/// the new "AI Tagging" section of `SettingsSheet`. Persisted at
/// `storageRoot/aiRulesTemplate.txt` (plain text — easier to spot-check
/// in the Files app than a JSON-wrapped string).
///
/// The v2 default below is structured for consistent forensic-residential
/// tagging:
///   * an explicit 6-step decision workflow Claude follows per photo
///   * core rules emphasising visible-only observations (no causation,
///     no severity, no "tilt indicator" interpretations)
///   * field definitions matching the JSON schema
///   * a disambiguation guide for the close calls (Grade Beam vs Slabs,
///     Masonry vs Foundation, Stucco vs Trim, Framing vs Roofing,
///     Flooring vs Slope)
///   * six worked examples covering all five photo classes the workflow
///     names (close-up distress, clean overview, attic-framing,
///     measurement, aerial/historical, poor-quality)
///
/// The vocabulary referenced by the disambiguation guide and examples
/// is shipped in `TagLibrary.defaultSeeds` — keep the two in sync.
enum AIRulesTemplate {
    static let defaultText: String = """
    Return exactly one JSON object per photo. Do not include prose, markdown, code fences, or explanation. Start with `{` and end with `}`.

    Use only the primary and secondary tags listed in the controlled vocabulary below. Do not invent, merge, abbreviate, or paraphrase tag names.

    Output JSON shape

    {
      "photo_id": "",
      "primary_tags": [],
      "secondary_tags_by_primary": {},
      "tag_confidences": {},
      "location_inferred": "",
      "scale_present": "",
      "measurement_visible": null,
      "summary_observation": "",
      "caption_draft": "",
      "recommended_use": "",
      "confidence": "",
      "confidence_note": "",
      "reviewer_flag": ""
    }

    Required workflow before tagging

    1. Identify the photo type:
       - context/overview — establishes location, elevation, room, attic, yard, or exterior side.
       - close-up distress — shows a crack, separation, displacement, stain, spall, distorted material, poor connection, or other condition.
       - measurement/readout — shows a level, ruler, tape, crack comparator, ZipLevel, or other measurement.
       - aerial/historical — shows trees, site changes, drainage patterns, or site context from above.
       - poor/obstructed — too blurry, too dark, too close, or obstructed to reliably classify.
    2. Identify the main visible component, not the presumed cause. Examples: grade beam, garage slab, driveway, brick veneer, sheetrock wall, ceiling, tile floor, door, attic framing, roofing, downspout, soil, pool deck.
    3. Identify only visible conditions. Do not infer final cause, assign severity, or diagnose foundation movement from a single photograph unless the visual evidence itself is the item being tagged.
    4. Select one primary tag by default. Use two primary tags only when two clearly distinct report-worthy conditions are visible in the same photo. Never use more than two.
    5. For each primary tag, select one to four secondary tags. Use `None` only for context photos or when the primary is visible but no specific distress secondary is clearly shown.
    6. If the correct issue category is absent from the vocabulary, return `primary_tags: []`, leave `secondary_tags_by_primary` and `tag_confidences` empty, set `confidence` to `Low`, and explain the vocabulary gap in `reviewer_flag`.

    Core rules

    - Context photos are valuable. Tag them with a context primary and `None` as the secondary. Do not force a distress tag on clean overview photos.
    - Prefer the component actually shown. For example, tag a crack in brick veneer as `Masonry Veneer`, not `Foundation / Grade Beam`, unless the concrete grade beam crack is visible.
    - Prefer directly visible geometry over mechanism. Use `Flat drainage`, `Negative drainage toward foundation`, `Downspout discharging near foundation`, or `Local ponding evidence`, not causal statements.
    - Do not state `caused by`, `due to`, `resulting from`, `settlement`, `heave`, or `soil movement` in `summary_observation` or `caption_draft` unless those words are visible text in the photo. The report writer can connect the photographs to engineering opinions later.
    - Do not tag normal objects just because they appear in the frame. A roof in an exterior elevation is not `Roofing / Roof Covering` unless the photo shows roofing distress or the roof is the intentional subject.
    - Do not assign severity labels such as minor, moderate, severe, extensive, or significant in the tags or captions. Describe what is visible.
    - When the photo includes both a measurement tool and the measured condition, tag the condition as primary. Add `Measurement / Instrument Readout` as a second primary only when the readout/tool is important to the photograph.
    - If a finding is only barely visible, use a general secondary and lower confidence rather than a very specific secondary.

    Field definitions

    - photo_id: exact photo filename or identifier supplied by the user/app. If none is supplied, use an empty string.
    - primary_tags: zero, one, or two primary tags from the controlled vocabulary.
    - secondary_tags_by_primary: an object keyed by each primary tag. Each value is an array of secondary tags listed under that primary. Use `["None"]` for context photos or where no specific secondary is visible.
    - tag_confidences: object mapping every emitted primary tag and every non-`None` secondary tag to a number from 0 to 1. Use 0.90–1.00 for clear visual evidence, 0.70–0.89 for probable evidence, and 0.50–0.69 for partial/obstructed/low-quality evidence. Do not include a confidence for `None`.
    - location_inferred: choose one value from the location list below. Use `Unknown` when location cannot be inferred from visible cues.
    - scale_present: choose `Yes`, `Relative`, or `No`. Use `Yes` for a ruler, tape, crack gauge, level readout, ZipLevel screen, comparator, coin, or clearly usable hand/finger scale. Use `Relative` for doors, windows, bricks, siding laps, baseboards, or other common objects that imply scale but do not provide a measurement.
    - measurement_visible: transcribe the visible measurement exactly as shown, including units and signs. If multiple readings are visible, include the most relevant reading or a short comma-separated transcription. Use `null` when no measurement is visible.
    - summary_observation: one factual sentence describing what is visible. No final causation and no severity. Example: `Vertical crack visible in the exterior concrete grade beam below the brick veneer.`
    - caption_draft: one short neutral report caption, maximum 18 words. Example: `Crack in exterior concrete grade beam below brick veneer.`
    - recommended_use: choose `Body figure`, `Appendix only`, `Context/locator`, or `Re-shoot recommended`.
    - confidence: choose `High`, `Medium`, or `Low` for the overall tag selection.
    - confidence_note: use an empty string for `High`. For `Medium` or `Low`, give one short reason such as `obstructed crack tip`, `dim lighting`, `partial view`, or `ambiguous component`.
    - reviewer_flag: use only for items needing engineer review, such as safety/egress concerns, contradictory measurement visibility, likely vocabulary gap, or poor image quality. Keep this rare.

    Location values

    Use exactly one of these values: `Exterior - Front`, `Exterior - Rear`, `Exterior - Left`, `Exterior - Right`, `Exterior - Unknown elevation`, `Interior - Living/Family`, `Interior - Kitchen`, `Interior - Bedroom`, `Interior - Bathroom`, `Interior - Hallway`, `Interior - Stairs`, `Interior - Other room`, `Garage`, `Porch/Patio`, `Attic`, `Crawlspace`, `Site/Yard`, `Pool/Gazebo`, `Aerial`, `Unknown`.

    Disambiguation guide

    - `Foundation / Grade Beam` vs `Concrete Slabs - Garage / Porch / Patio / Interior`: use `Foundation / Grade Beam` for exposed vertical perimeter concrete, brick ledge, parge coat, or exterior foundation face. Use `Concrete Slabs` for horizontal garage slabs, porch/patio slabs, or interior slab cracks.
    - `Driveway and Flatwork` vs `Concrete Slabs`: use `Driveway and Flatwork` for exterior non-structural pavement such as driveway, sidewalk, walkway, pool deck, and hardscape. Use `Concrete Slabs` for garage, porch, patio, or interior slab areas connected to the house.
    - `Masonry Veneer` vs `Foundation / Grade Beam`: use `Masonry Veneer` when the visible distress is in brick/stone/mortar. Use `Foundation / Grade Beam` only when the concrete foundation or foundation-to-veneer interface is visible.
    - `Stucco / Exterior Finish` vs `Exterior Trim / Siding / Soffit`: use `Stucco / Exterior Finish` for stucco field cracking, stucco termination, weep screed, or stucco-to-window conditions. Use `Exterior Trim / Siding / Soffit` for trim boards, frieze boards, soffits, and cement-board siding.
    - `Interior Wall Finish` vs `Interior Ceiling Finish`: choose based on the surface containing the main crack/separation. If both are visible and report-worthy, use both primaries.
    - `Flooring` vs `Floor Slope / Levelness`: use `Flooring` for cracks, loose tile, flooring separation, or rippled floor finishes. Use `Floor Slope / Levelness` only when slope/levelness is visually or measurably the main subject.
    - `Roof / Attic Framing` vs `Roofing / Roof Covering`: use framing for rafters, purlins, braces, trusses, sheathing, OSB, fasteners, and attic structural connections. Use roofing for shingles, metal panels, roof coverings, roof edges, flashing, and roof-surface conditions.
    - `Moisture Intrusion / Staining` can be paired with another component tag when staining is visible on the component. Example: moisture-stained ceiling tile can be `Interior Ceiling Finish` plus `Moisture Intrusion / Staining`.
    - `Prior Repair / Patch` should be a second tag when the photo primarily documents a crack or distress passing through a repaired area. Use it alone only when the repair/patch itself is the subject.
    - `Measurement / Instrument Readout` is a second tag unless the photo is only a readout/tool with no visible condition.

    Worked examples

    Example 1 — Exterior grade beam crack (close-up distress):

    {
      "photo_id": "IMG_0042.jpg",
      "primary_tags": ["Foundation / Grade Beam"],
      "secondary_tags_by_primary": {"Foundation / Grade Beam": ["Grade beam crack", "Vertical crack"]},
      "tag_confidences": {"Foundation / Grade Beam": 0.95, "Grade beam crack": 0.94, "Vertical crack": 0.90},
      "location_inferred": "Exterior - Unknown elevation",
      "scale_present": "Relative",
      "measurement_visible": null,
      "summary_observation": "Vertical crack visible in the exterior concrete grade beam below the veneer.",
      "caption_draft": "Vertical crack in exterior concrete grade beam.",
      "recommended_use": "Body figure",
      "confidence": "High",
      "confidence_note": "",
      "reviewer_flag": ""
    }

    Example 2 — Clean exterior overview (context/overview):

    {
      "photo_id": "IMG_0101.jpg",
      "primary_tags": ["General Exterior Context"],
      "secondary_tags_by_primary": {"General Exterior Context": ["Front elevation overview"]},
      "tag_confidences": {"General Exterior Context": 0.96, "Front elevation overview": 0.92},
      "location_inferred": "Exterior - Front",
      "scale_present": "Relative",
      "measurement_visible": null,
      "summary_observation": "Front exterior elevation showing the entry, veneer, roofline, and adjacent grade.",
      "caption_draft": "Front exterior elevation overview.",
      "recommended_use": "Context/locator",
      "confidence": "High",
      "confidence_note": "",
      "reviewer_flag": ""
    }

    Example 3 — Attic framing connection (close-up distress):

    {
      "photo_id": "IMG_0220.jpg",
      "primary_tags": ["Roof / Attic Framing"],
      "secondary_tags_by_primary": {"Roof / Attic Framing": ["Loose / untight framing connection", "Exposed fasteners"]},
      "tag_confidences": {"Roof / Attic Framing": 0.91, "Loose / untight framing connection": 0.84, "Exposed fasteners": 0.89},
      "location_inferred": "Attic",
      "scale_present": "Relative",
      "measurement_visible": null,
      "summary_observation": "Attic framing connection shows a visible gap with exposed fasteners.",
      "caption_draft": "Gap and exposed fasteners at attic framing connection.",
      "recommended_use": "Body figure",
      "confidence": "High",
      "confidence_note": "",
      "reviewer_flag": ""
    }

    Example 4 — Measurement-only photo (measurement/readout):

    {
      "photo_id": "IMG_0307.jpg",
      "primary_tags": ["Measurement / Instrument Readout"],
      "secondary_tags_by_primary": {"Measurement / Instrument Readout": ["Digital level visible", "Measurement number visible"]},
      "tag_confidences": {"Measurement / Instrument Readout": 0.94, "Digital level visible": 0.93, "Measurement number visible": 0.88},
      "location_inferred": "Unknown",
      "scale_present": "Yes",
      "measurement_visible": "1.8%",
      "summary_observation": "Digital level display shows a 1.8% reading.",
      "caption_draft": "Digital level display showing slope reading.",
      "recommended_use": "Appendix only",
      "confidence": "High",
      "confidence_note": "",
      "reviewer_flag": ""
    }

    Example 5 — Historical aerial image (aerial/historical):

    {
      "photo_id": "IMG_0450.jpg",
      "primary_tags": ["Aerial / Historical Site Context"],
      "secondary_tags_by_primary": {"Aerial / Historical Site Context": ["Historical aerial image", "Tree removal context"]},
      "tag_confidences": {"Aerial / Historical Site Context": 0.92, "Historical aerial image": 0.90, "Tree removal context": 0.78},
      "location_inferred": "Aerial",
      "scale_present": "No",
      "measurement_visible": null,
      "summary_observation": "Historical aerial image of the site showing a tree present in a location that is now cleared.",
      "caption_draft": "Historical aerial showing prior tree at front-yard location.",
      "recommended_use": "Appendix only",
      "confidence": "Medium",
      "confidence_note": "tree species and exact date not determinable from image",
      "reviewer_flag": ""
    }

    Example 6 — Blurry/partial photo (poor/obstructed):

    {
      "photo_id": "IMG_0512.jpg",
      "primary_tags": ["Photo Quality / Re-shoot"],
      "secondary_tags_by_primary": {"Photo Quality / Re-shoot": ["Blurry image", "Distress cropped off"]},
      "tag_confidences": {"Photo Quality / Re-shoot": 0.86, "Blurry image": 0.88, "Distress cropped off": 0.74},
      "location_inferred": "Unknown",
      "scale_present": "No",
      "measurement_visible": null,
      "summary_observation": "Image is blurry and a possible crack at the edge of the frame is not fully captured.",
      "caption_draft": "Image quality limits identification of the subject condition.",
      "recommended_use": "Re-shoot recommended",
      "confidence": "Low",
      "confidence_note": "blurry, distress not fully framed",
      "reviewer_flag": "re-shoot of suspected crack at right edge of frame"
    }

    Final checks before returning

    - Every primary tag and every non-`None` secondary tag has an entry in `tag_confidences` with keys spelled exactly as in `primary_tags` / `secondary_tags_by_primary`. An empty `tag_confidences` object whenever you emitted at least one tag is a schema violation.
    - Every secondary tag appears verbatim under its chosen primary in the controlled vocabulary below. If not, replace with the closest exact match or `None`.
    - Use the exact primary tag names as listed in the controlled vocabulary below. Do not prefix them with numbers, dashes, or any other characters.
    - Re-read `summary_observation` and `caption_draft`. If either contains `caused by`, `due to`, `resulting from`, `settlement`, `heave`, `soil movement`, or a severity word (minor, moderate, severe, extensive, significant), revise to remove the engineering interpretation and describe only what is visible.
    """
}
