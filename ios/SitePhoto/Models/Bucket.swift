import Foundation
import SwiftUI

/// A user-defined category that groups photos within a project — a coarser
/// dimension than the AI-driven tag vocabulary, intended for the engineer's
/// own report-building workflow (e.g. "Foundation findings", "Drainage",
/// "Re-shoot list"). Each photo belongs to at most one bucket.
///
/// Buckets are scoped to the project they live in. Folder export uses the
/// `sortOrder` to lay out the directory tree (`01_<name>/`, `02_<name>/`,
/// …) and the photos in `Photo.bucketID == nil` go into a final
/// `99_Unbucketed/` folder.
struct Bucket: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var colorHex: String
    var sortOrder: Int

    init(id: UUID = UUID(),
         name: String,
         colorHex: String = Bucket.palette[0],
         sortOrder: Int) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }

    /// SwiftUI Color resolved from `colorHex`. Falls back to the accent
    /// color if the stored hex string is malformed.
    var color: Color {
        Color(bucketHex: colorHex) ?? .accentColor
    }

    /// Curated palette the bucket manager picks from. Twelve colors gives
    /// good separation across the 10–20 buckets a typical project uses
    /// without overwhelming the picker.
    static let palette: [String] = [
        "#22896F", // accent teal
        "#1A6B5C",
        "#2B7FFF", // blue
        "#0EA5E9", // sky
        "#9333EA", // purple
        "#C026D3", // magenta
        "#D4820A", // amber
        "#F0A020", // gold
        "#C0392B", // red
        "#E11D48", // rose
        "#16A34A", // green
        "#525B6F"  // slate
    ]
}

extension Color {
    /// Parse a `#RRGGBB` string into a SwiftUI Color. Returns nil if the
    /// string isn't six hex digits with an optional leading `#`. Used by
    /// `Bucket.color`; kept private-ish via the labeled initializer so it
    /// doesn't collide with any future generic hex helper.
    init?(bucketHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let rgb = UInt32(s, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >>  8) & 0xFF) / 255.0
        let b = Double( rgb        & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
