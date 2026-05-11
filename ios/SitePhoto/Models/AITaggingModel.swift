import Foundation

/// User-selectable Claude model for AI photo tagging. Stored as the
/// enum's `rawValue` under `UserDefaults` key `sitephoto.aiModel`.
/// Sonnet is the careful default; Haiku is opt-in for engineers who
/// prioritise speed on initial sweeps and don't mind shorter captions.
enum AITaggingModel: String, CaseIterable, Identifiable, Sendable {
    case sonnet
    case haiku

    var id: String { rawValue }

    /// Model identifier sent to Anthropic. Updated here when a newer
    /// generation ships so the call sites don't have to change.
    var modelIdentifier: String {
        switch self {
        case .sonnet: return "claude-sonnet-4-6"
        case .haiku:  return "claude-haiku-4-5"
        }
    }

    var displayName: String {
        switch self {
        case .sonnet: return "Claude Sonnet 4.6"
        case .haiku:  return "Claude Haiku 4.5"
        }
    }

    var subtitle: String {
        switch self {
        case .sonnet: return "Careful default — best for high-stakes tagging."
        case .haiku:  return "Roughly 2× faster and 3–4× cheaper. May produce shorter captions and miss subtle distress."
        }
    }

    /// UserDefaults key shared by the Settings picker and the AI
    /// tagging entry points. Centralised here so a typo can't drift
    /// the read- and write-sides apart.
    static let userDefaultsKey = "sitephoto.aiModel"

    /// Resolve whichever model the engineer last picked, falling back
    /// to `.sonnet` for fresh installs / unrecognised stored values.
    static var current: AITaggingModel {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return AITaggingModel(rawValue: raw) ?? .sonnet
    }
}
