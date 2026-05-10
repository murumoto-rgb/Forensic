import Foundation

/// One "Primary Investigation Type" in the app-wide bucket library —
/// e.g. *Foundation Investigation*, *Roofing Investigation*. Each
/// category holds a list of pre-filled **observation buckets** that the
/// engineer can drop into a project one-by-one rather than rebuilding
/// the same bucket list from scratch every job.
///
/// Categories and their entries are fully editable: rename, recolor,
/// reorder, add new ones, delete, all from the Library Manager. The
/// list survives across projects and iCloud sessions because it lives
/// alongside `branding.json` at the storage root.
struct BucketLibraryCategory: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var entries: [Entry]

    init(id: UUID = UUID(), name: String, entries: [Entry]) {
        self.id = id
        self.name = name
        self.entries = entries
    }

    struct Entry: Identifiable, Codable, Hashable, Sendable {
        let id: UUID
        var name: String
        var colorHex: String

        init(id: UUID = UUID(), name: String, colorHex: String) {
            self.id = id
            self.name = name
            self.colorHex = colorHex
        }
    }
}

extension BucketLibraryCategory {
    /// Default seeds populated on first launch so the picker has useful
    /// content out of the box. The user can rename / extend / delete any
    /// of these — they're starting points, not protected entries.
    static let defaultSeeds: [BucketLibraryCategory] = [
        BucketLibraryCategory(name: "Foundation Investigation", entries: [
            .init(name: "Site conditions",          colorHex: "#D4820A"),
            .init(name: "Drainage / Grading",       colorHex: "#0EA5E9"),
            .init(name: "Foundation cracks",        colorHex: "#C0392B"),
            .init(name: "Slab evidence",            colorHex: "#475569"),
            .init(name: "Interior distress",        colorHex: "#9333EA"),
            .init(name: "Exterior distress",        colorHex: "#E11D48"),
            .init(name: "Trees / Vegetation",       colorHex: "#16A34A"),
            .init(name: "Reference photos",         colorHex: "#525B6F")
        ]),
        BucketLibraryCategory(name: "Framing Investigation", entries: [
            .init(name: "Walls",                    colorHex: "#22896F"),
            .init(name: "Attic / Framing",          colorHex: "#9333EA"),
            .init(name: "Roof framing",             colorHex: "#D4820A"),
            .init(name: "Connections / Hardware",   colorHex: "#0EA5E9"),
            .init(name: "Distortion / Movement",    colorHex: "#C0392B"),
            .init(name: "Previous repairs",         colorHex: "#475569")
        ]),
        BucketLibraryCategory(name: "Roofing Investigation", entries: [
            .init(name: "Roof overview",            colorHex: "#22896F"),
            .init(name: "Shingles / Covering",      colorHex: "#D4820A"),
            .init(name: "Flashing",                 colorHex: "#9333EA"),
            .init(name: "Gutters / Downspouts",     colorHex: "#0EA5E9"),
            .init(name: "Ventilation",              colorHex: "#16A34A"),
            .init(name: "Storm damage",             colorHex: "#C0392B")
        ]),
        BucketLibraryCategory(name: "Stucco Investigation", entries: [
            .init(name: "Cracks",                   colorHex: "#C0392B"),
            .init(name: "Separations",              colorHex: "#D4820A"),
            .init(name: "Bulging / Delamination",   colorHex: "#9333EA"),
            .init(name: "Stains / Moisture",        colorHex: "#0EA5E9"),
            .init(name: "Sealant",                  colorHex: "#22896F")
        ]),
        BucketLibraryCategory(name: "Moisture Intrusion", entries: [
            .init(name: "Visible stains",           colorHex: "#0EA5E9"),
            .init(name: "Plumbing leaks",           colorHex: "#22896F"),
            .init(name: "Roof / Ceiling intrusion", colorHex: "#9333EA"),
            .init(name: "Exterior intrusion",       colorHex: "#D4820A"),
            .init(name: "HVAC / Mechanical",        colorHex: "#475569"),
            .init(name: "Mold indicators",          colorHex: "#C0392B")
        ])
    ]
}

/// Disk shape of the legacy bucketTemplates.json file. Old entries
/// lacked stable UUIDs; this struct lets us decode the previous payload
/// once and migrate it forward into `BucketLibraryCategory` (assigning
/// fresh UUIDs to each entry) on first launch after the rework lands.
struct LegacyBucketTemplate: Codable {
    let id: UUID
    let name: String
    let entries: [LegacyEntry]

    struct LegacyEntry: Codable {
        let name: String
        let colorHex: String
    }

    func upgraded() -> BucketLibraryCategory {
        BucketLibraryCategory(
            id: id,
            name: name,
            entries: entries.map { .init(name: $0.name, colorHex: $0.colorHex) }
        )
    }
}
