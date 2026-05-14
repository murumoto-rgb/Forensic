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
/// The v3 default below is structured for consistent forensic-residential
/// tagging:
///   * an opening "Triples are atomic" paragraph that tells the model
///     to treat every controlled-vocabulary entry as a single
///     `Context::Primary::Secondary` triple — never to detach a
///     secondary from its primary or its context
///   * an explicit 6-step decision workflow Claude follows per photo
///   * core rules emphasising visible-only observations (no causation,
///     no severity, no "tilt indicator" interpretations)
///   * field definitions matching the JSON schema
///   * a disambiguation guide for the close calls (Grade Beam vs Slabs,
///     Masonry vs Foundation, Stucco vs Trim, Framing vs Roofing,
///     Flooring vs Slope)
///   * worked examples covering the photo classes the workflow names
///     (close-up distress, clean overview, attic-framing, measurement,
///     poor-quality)
///
/// The vocabulary referenced by the disambiguation guide and examples
/// is shipped in `TagLibrary.defaultSeeds` — keep the two in sync.
enum AIRulesTemplate {
    static let defaultText: String = """
    Return exactly one JSON object per photo. Do not include prose, markdown, code fences, or explanation. Start with `{` and end with `}`.

    Use only the primary and secondary tags listed in the controlled vocabulary below. Do not invent, merge, abbreviate, or paraphrase tag names.

    Triples are atomic

    The controlled vocabulary below is a flat list of `Context::Primary::Secondary` triples, one per line. Read every triple as one indivisible choice — the Context and the Primary travel with the Secondary as a single unit. When you select a secondary tag, you are committing to the exact primary and context the triple's `::`-delimited path names. Never detach a secondary from its primary, never pair a secondary with a different primary even if the names look similar, and never refer to a secondary in isolation. Think and decide in triples.

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
       - measurement/readout — shows a level, ruler, tape, crack comparator, ZipLevel, moisture meter, or other measurement.
       - poor/obstructed — too blurry, too dark, too close, or obstructed to reliably classify.
    2. Identify the main visible component, not the presumed cause. Examples: grade beam, garage slab, driveway, brick veneer, sheetrock wall, ceiling, tile floor, door, attic framing, roofing, downspout, soil, pool deck.
    3. Identify only visible conditions. Do not infer final cause, assign severity, or diagnose foundation movement from a single photograph unless the visual evidence itself is the item being tagged.
    4. Select one to four `Context::Primary::Secondary` triples that describe what is visible. The default is one or two triples; use more only when several clearly distinct report-worthy conditions are visible in the same photo. Never exceed four triples total. Every triple you pick is a complete unit — you do not first pick a primary and then a separate secondary, you pick the full triple at once from the controlled vocabulary below.
    5. Group the triples you picked by their primary when filling the JSON. Each unique primary across your chosen triples appears once in `primary_tags`; each triple's secondary appears under that primary's key in `secondary_tags_by_primary`. Do not move a secondary under a primary other than the one named in its triple. If no listed triple describes what is visible, leave the corresponding primary out of `primary_tags` entirely rather than forcing a near-fit triple.
    6. If the correct issue category is absent from the vocabulary, return `primary_tags: []`, leave `secondary_tags_by_primary` and `tag_confidences` empty, set `confidence` to `Low`, and explain the vocabulary gap in `reviewer_flag`.

    Core rules

    - Context photos are valuable. Tag them with a context primary (e.g. `General Exterior Orientation`, `General Interior Orientation`, `General Site Overview`) and the most specific overall-view / context secondary listed under that primary (e.g. `Front elevation overall view`, `Interior overall view`). Do not force a distress tag onto a clean overview photo.
    - Prefer the component actually shown. For example, tag a crack in brick veneer as `Masonry Veneer`, not `Foundation / Grade Beam`, unless the concrete grade beam crack is visible.
    - Prefer directly visible geometry over mechanism. Use `Marginal or flat drainage adjacent to foundation`, `Negative drainage toward foundation`, `Downspout discharging near foundation`, or `Local ponding evidence`, not causal statements.
    - Do not state `caused by`, `due to`, `resulting from`, `settlement`, `heave`, or `soil movement` in `summary_observation` or `caption_draft` unless those words are visible text in the photo. The report writer can connect the photographs to engineering opinions later.
    - Do not tag normal objects just because they appear in the frame. A roof in an exterior elevation is not `Roofing` unless the photo shows roofing distress or the roof is the intentional subject.
    - Do not assign severity labels such as minor, moderate, severe, extensive, or significant in the tags or captions. Describe what is visible.
    - When the photo includes both a measurement tool and the measured condition, tag the condition as primary. Add `Measurement / Instrument Readout` as a second primary only when the readout/tool is important to the photograph.
    - If a finding is only barely visible, use a general secondary and lower confidence rather than a very specific secondary.

    Field definitions

    - photo_id: exact photo filename or identifier supplied by the user/app. If none is supplied, use an empty string.
    - primary_tags: zero, one, or two primary tags from the controlled vocabulary.
    - secondary_tags_by_primary: an object keyed by each primary tag. Each value is an array of one to four secondary tags listed under that primary in the controlled vocabulary. If a primary genuinely has no applicable secondary for the photo, leave that primary out of `primary_tags` rather than emitting an empty array.
    - tag_confidences: object mapping every emitted primary tag and every secondary tag to a number from 0 to 1. Use 0.90–1.00 for clear visual evidence, 0.70–0.89 for probable evidence, and 0.50–0.69 for partial/obstructed/low-quality evidence.
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
    - `Interior Wall and Ceiling Sheetrock Finish` covers cracks, separations, and stains on either wall or ceiling sheetrock — a single primary spans both surfaces. Use `Ceiling sheetrock crack` for the ceiling-specific case and `Wall sheetrock crack` for the wall-specific case; otherwise pick whichever joint / corner secondary best describes the geometry visible.
    - `Flooring` vs `Floor Slope / Levelness`: use `Flooring` for cracks, loose tile, flooring separation, or rippled floor finishes. Use `Floor Slope / Levelness` only when slope/levelness is visually or measurably the main subject.
    - `Attic Framing` vs `Roofing`: use `Attic Framing` for rafters, trusses, sheathing, fasteners, and attic structural connections. Use `Roofing` for shingles, metal panels, roof coverings, and roof-surface conditions.
    - `Moisture Intrusion` can be paired with another component tag when staining is visible on the component. Example: a moisture stain on a ceiling can be tagged as `Interior Wall and Ceiling Sheetrock Finish` plus `Moisture Intrusion`.
    - `Measurement / Instrument Readout` is a second tag unless the photo is only a readout/tool with no visible condition.

    Worked examples

    Example 1 — Exterior grade beam crack (close-up distress). Selected triple: `Foundation Performance Evaluation::Foundation / Grade Beam::Grade beam crack`. One triple is enough here — `summary_observation` and `caption_draft` carry the geometry detail in plain language without needing a second triple.

    {
      "photo_id": "IMG_0042.jpg",
      "primary_tags": ["Foundation / Grade Beam"],
      "secondary_tags_by_primary": {"Foundation / Grade Beam": ["Grade beam crack"]},
      "tag_confidences": {"Foundation / Grade Beam": 0.95, "Grade beam crack": 0.94},
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

    Example 2 — Clean exterior overview (context/overview). The selected triple is `Foundation Performance Evaluation::General Exterior Orientation::Front elevation overall view`.

    {
      "photo_id": "IMG_0101.jpg",
      "primary_tags": ["General Exterior Orientation"],
      "secondary_tags_by_primary": {"General Exterior Orientation": ["Front elevation overall view"]},
      "tag_confidences": {"General Exterior Orientation": 0.96, "Front elevation overall view": 0.92},
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

    Example 3 — Attic framing connection (close-up distress). Selected triples: `Foundation Performance Evaluation::Attic Framing::Loose / untight framing connection (wide joints)` and `Foundation Performance Evaluation::Attic Framing::Exposed fasteners between wood framing members`.

    {
      "photo_id": "IMG_0220.jpg",
      "primary_tags": ["Attic Framing"],
      "secondary_tags_by_primary": {"Attic Framing": ["Loose / untight framing connection (wide joints)", "Exposed fasteners between wood framing members"]},
      "tag_confidences": {"Attic Framing": 0.91, "Loose / untight framing connection (wide joints)": 0.84, "Exposed fasteners between wood framing members": 0.89},
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

    Example 4 — Measurement-only photo (measurement/readout). Selected triples: `Foundation Performance Evaluation::Measurement / Instrument Readout::Digital level visible` and `Foundation Performance Evaluation::Measurement / Instrument Readout::Measurement number visible`. Both sit under the same primary so the `secondary_tags_by_primary` entry has both under the one primary key.

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

    Example 5 — Blurry photo (poor/obstructed). Selected triple: `Foundation Performance Evaluation::Photo Quality / Re-shoot::Blurry image`.

    {
      "photo_id": "IMG_0512.jpg",
      "primary_tags": ["Photo Quality / Re-shoot"],
      "secondary_tags_by_primary": {"Photo Quality / Re-shoot": ["Blurry image"]},
      "tag_confidences": {"Photo Quality / Re-shoot": 0.86, "Blurry image": 0.88},
      "location_inferred": "Unknown",
      "scale_present": "No",
      "measurement_visible": null,
      "summary_observation": "Image is blurry and the subject condition cannot be confidently identified.",
      "caption_draft": "Image quality limits identification of the subject condition.",
      "recommended_use": "Re-shoot recommended",
      "confidence": "Low",
      "confidence_note": "blurry; subject indistinct",
      "reviewer_flag": "re-shoot recommended for this view"
    }

    Final checks before returning

    - Every primary tag and every secondary tag has an entry in `tag_confidences` with keys spelled exactly as in `primary_tags` / `secondary_tags_by_primary`. An empty `tag_confidences` object whenever you emitted at least one tag is a schema violation.
    - Every secondary you emit belongs to the exact primary named in its triple. If no listed triple fits, drop that primary from `primary_tags` rather than substituting a wrong-primary secondary.
    - Cross-check triple integrity: for every secondary you emit, find the exact `Context::Primary::Secondary` line in the controlled vocabulary below. The `Primary` portion of that line MUST be the primary you used in `primary_tags` / `secondary_tags_by_primary`. If it isn't, either (a) change your primary to match the triple, or (b) replace the secondary with a triple whose primary you actually chose. Some secondaries have similarly-named cousins under different primaries (e.g. `Digital level visible` lives in `…::Measurement / Instrument Readout::Digital level visible`, while `Digital level reading shown` lives in `…::Floor Slope / Levelness::Digital level reading shown`) — check the actual triple, do not guess from the name alone.
    - Use the exact primary tag names as written in the triple's middle field. Do not prefix them with numbers, dashes, or any other characters.
    - Re-read `summary_observation` and `caption_draft`. If either contains `caused by`, `due to`, `resulting from`, `settlement`, `heave`, `soil movement`, or a severity word (minor, moderate, severe, extensive, significant), revise to remove the engineering interpretation and describe only what is visible.
    """
}
