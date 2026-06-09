import Foundation

/// The five tabs that make up the project workspace (Build #5.127.1 —
/// iOS information-architecture refactor, PR 1/7).
///
/// The tab enum carries its own metadata (label + SF Symbol) so
/// individual tab files don't re-declare it. Adding a tab is a single
/// edit here plus its body file.
enum ProjectTab: String, CaseIterable, Hashable, Identifiable {
    case photos
    case plan
    case ai
    case export
    case more

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photos: return "Photos"
        case .plan:   return "Plan"
        case .ai:     return "AI"
        case .export: return "Export"
        case .more:   return "More"
        }
    }

    var systemImage: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .plan:   return "map"
        case .ai:     return "wand.and.sparkles"
        case .export: return "square.and.arrow.up"
        case .more:   return "ellipsis.circle"
        }
    }
}
