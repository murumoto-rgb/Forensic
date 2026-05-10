import Foundation
import SwiftUI
import UIKit

/// How floor-plan markers are tinted on screen and in the PDF. Defaults to
/// `status` (the historical single-green look) so older projects render the
/// same way until the user picks a different mode from the Plan toolbar.
enum PlanColorMode: String, CaseIterable, Codable, Sendable {
    case status
    case bucket
    case primaryTag

    var displayName: String {
        switch self {
        case .status:     return "Default"
        case .bucket:     return "Bucket"
        case .primaryTag: return "Primary Tag"
        }
    }

    var iconName: String {
        switch self {
        case .status:     return "circle.fill"
        case .bucket:     return "folder.fill"
        case .primaryTag: return "tag.fill"
        }
    }

    /// Stored mode loaded from UserDefaults. Used by `PDFExportService`,
    /// which isn't a SwiftUI view and can't take an `@AppStorage` binding.
    static var stored: PlanColorMode {
        let raw = UserDefaults.standard.string(forKey: storageKey)
        return raw.flatMap(PlanColorMode.init(rawValue:)) ?? .status
    }

    static let storageKey = "sitephoto.plan.colorMode"
}

/// Shared resolver that turns a photo + mode + project into a marker color.
/// Two entry points so SwiftUI (`Color`) and CoreGraphics-based PDF drawing
/// (`CGColor`) both work without duplicating the mapping logic.
enum PlanMarkerColors {
    /// SwiftUI `Color` for the on-screen floor-plan bubble.
    static func color(for photo: Photo,
                       mode: PlanColorMode,
                       project: Project) -> Color {
        switch mode {
        case .status:
            return .green
        case .bucket:
            guard let id = photo.bucketID,
                  let bucket = project.buckets.first(where: { $0.id == id }) else {
                return Color(white: 0.55)
            }
            return bucket.color
        case .primaryTag:
            return primaryTagColor(for: photo)
        }
    }

    /// `CGColor` for the PDF floor-plan bubble. Mirrors `color(for:mode:project:)`
    /// so screen and paper renderings stay in sync.
    static func cgColor(for photo: Photo,
                         mode: PlanColorMode,
                         project: Project) -> CGColor {
        UIColor(color(for: photo, mode: mode, project: project)).cgColor
    }

    /// Find the highest-priority primary tag on the photo (lowest
    /// `primaryRank`, since rank 0 = first in the canonical guide). Looks at
    /// both standalone primaries (parentTag == nil) and the parents of
    /// secondaries. Falls back to a neutral grey when the photo carries no
    /// recognised primary.
    ///
    /// Returned hue is `rank / 23` so all 23 controlled primaries get a
    /// distinct, evenly-spaced colour around the wheel. Saturation +
    /// brightness chosen to stay readable on most floor-plan backgrounds.
    private static func primaryTagColor(for photo: Photo) -> Color {
        var bestRank: Int = .max
        for tag in photo.tags {
            let candidate = tag.parentTag ?? tag.label
            let rank = ControlledVocabulary.primaryRank(candidate)
            if rank < bestRank {
                bestRank = rank
            }
        }
        guard bestRank < Int.max else { return Color(white: 0.55) }
        let total = max(1, ControlledVocabulary.primaries.count)
        let hue = Double(bestRank) / Double(total)
        return Color(hue: hue, saturation: 0.78, brightness: 0.85)
    }
}
