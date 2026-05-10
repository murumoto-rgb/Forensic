import Foundation

/// Reusable, named per-project AI instruction prompt. Engineers tune the
/// AI's tagging / observation style for each investigation type
/// (foundation, roofing, …) and don't want to retype the same guidance
/// into every new project. Templates save a snapshot of the prompt
/// they've built once they're happy with it; the picker lets them drop
/// the prompt back into a new project with one tap.
///
/// Stored app-wide in `aiPromptTemplates.json` alongside the bucket
/// library. Mutations go through `ProjectStore` so the file stays in
/// sync.
struct AIPromptTemplate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var prompt: String

    init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}

extension AIPromptTemplate {
    /// Two starter templates seeded on first launch so the picker has
    /// useful content out of the box. The engineer can rename / edit /
    /// delete any of these. Keep this list modest — the value of
    /// templates is the engineer's own customised prompts, not a
    /// pre-built library.
    static let defaultSeeds: [AIPromptTemplate] = [
        AIPromptTemplate(
            name: "Foundation inspection",
            prompt: """
            Focus on foundation conditions. Tag and describe:
            • Cracks (location, width, pattern: vertical / horizontal / diagonal / stair-step)
            • Slab evidence (heaving, settling, separation, exposed rebar)
            • Drainage and grading near the structure (slope direction, ponding, downspout discharge)
            • Interior distress (drywall cracks, door / window racking, floor slope)
            • Exterior distress (separations at trim, brick veneer cracks, displaced concrete)
            • Trees and large vegetation within 20 ft of the foundation

            For each observation, include severity (cosmetic / monitoring / immediate) and any recommended follow-up (monitor, retest after rain, structural eval, etc.).
            """
        ),
        AIPromptTemplate(
            name: "Roof inspection",
            prompt: """
            Focus on roof and roof-system conditions. Tag and describe:
            • Roof covering condition (shingle wear, granule loss, lifting, missing pieces)
            • Flashing (chimney, valleys, sidewalls, vents)
            • Penetrations (plumbing vents, HVAC curbs, skylights)
            • Gutters and downspouts (debris, sag, discharge direction)
            • Ventilation (ridge vents, soffit vents, attic exhaust)
            • Storm-related damage (hail strikes, wind uplift, impact marks)

            For each observation, include severity (cosmetic / monitoring / immediate) and any recommended follow-up (repair, replace, monitor).
            """
        )
    ]
}
