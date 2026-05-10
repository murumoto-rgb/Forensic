import Foundation

/// Reusable "starter pack" of bucket definitions the engineer applies to
/// a project. Forensic engagements repeat themes (foundation, framing,
/// roofing, stucco, moisture, …) and each theme has a typical set of
/// report sections — templates let the engineer click once instead of
/// rebuilding the same 6–10 buckets from scratch for every new project.
///
/// Each entry stores just a name + colour. UUIDs are assigned per-bucket
/// at apply time so multiple projects can share a template without
/// aliasing bucket identities.
struct BucketTemplate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var entries: [Entry]

    init(id: UUID = UUID(), name: String, entries: [Entry]) {
        self.id = id
        self.name = name
        self.entries = entries
    }

    struct Entry: Codable, Hashable, Sendable {
        var name: String
        var colorHex: String
    }

    /// How a template is applied to an existing project.
    enum ApplyMode: String, CaseIterable, Sendable {
        /// Wipe the project's current buckets (and clear `Photo.bucketID`
        /// on every photo that pointed at them) before adding the
        /// template's buckets fresh. Destructive — confirm in UI.
        case replace
        /// Append the template's buckets at the end, leaving existing
        /// ones (and their photo assignments) intact. Safe default.
        case append
    }
}

extension BucketTemplate {
    /// Default templates seeded on first launch so the engineer sees the
    /// feature in action immediately rather than starting at "no
    /// templates yet". The user can rename, edit, or delete any of these.
    static let defaultSeeds: [BucketTemplate] = [
        BucketTemplate(name: "Foundation Investigation", entries: [
            .init(name: "Site conditions",          colorHex: "#D4820A"),
            .init(name: "Drainage / Grading",       colorHex: "#0EA5E9"),
            .init(name: "Foundation cracks",        colorHex: "#C0392B"),
            .init(name: "Slab evidence",            colorHex: "#475569"),
            .init(name: "Interior distress",        colorHex: "#9333EA"),
            .init(name: "Exterior distress",        colorHex: "#E11D48"),
            .init(name: "Trees / Vegetation",       colorHex: "#16A34A"),
            .init(name: "Reference photos",         colorHex: "#525B6F")
        ]),
        BucketTemplate(name: "Framing Investigation", entries: [
            .init(name: "Walls",                    colorHex: "#22896F"),
            .init(name: "Attic / Framing",          colorHex: "#9333EA"),
            .init(name: "Roof framing",             colorHex: "#D4820A"),
            .init(name: "Connections / Hardware",   colorHex: "#0EA5E9"),
            .init(name: "Distortion / Movement",    colorHex: "#C0392B"),
            .init(name: "Previous repairs",         colorHex: "#475569")
        ]),
        BucketTemplate(name: "Roofing Investigation", entries: [
            .init(name: "Roof overview",            colorHex: "#22896F"),
            .init(name: "Shingles / Covering",      colorHex: "#D4820A"),
            .init(name: "Flashing",                 colorHex: "#9333EA"),
            .init(name: "Gutters / Downspouts",     colorHex: "#0EA5E9"),
            .init(name: "Ventilation",              colorHex: "#16A34A"),
            .init(name: "Storm damage",             colorHex: "#C0392B")
        ]),
        BucketTemplate(name: "Stucco Investigation", entries: [
            .init(name: "Cracks",                   colorHex: "#C0392B"),
            .init(name: "Separations",              colorHex: "#D4820A"),
            .init(name: "Bulging / Delamination",   colorHex: "#9333EA"),
            .init(name: "Stains / Moisture",        colorHex: "#0EA5E9"),
            .init(name: "Sealant",                  colorHex: "#22896F")
        ]),
        BucketTemplate(name: "Moisture Intrusion", entries: [
            .init(name: "Visible stains",           colorHex: "#0EA5E9"),
            .init(name: "Plumbing leaks",           colorHex: "#22896F"),
            .init(name: "Roof / Ceiling intrusion", colorHex: "#9333EA"),
            .init(name: "Exterior intrusion",       colorHex: "#D4820A"),
            .init(name: "HVAC / Mechanical",        colorHex: "#475569"),
            .init(name: "Mold indicators",          colorHex: "#C0392B")
        ])
    ]
}
