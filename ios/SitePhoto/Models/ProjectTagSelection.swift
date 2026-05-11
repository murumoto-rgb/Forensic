import Foundation

/// Per-project AI tagging scope. Picks a subset of the app-wide
/// `TagLibrary` so the AI prompt for this project lists only the
/// vocabulary that's actually relevant to the job — a foundation +
/// framing investigation doesn't need the AI considering "Stucco" tags.
///
/// Storage shape:
/// - `contextIDs` keeps the engineer-chosen order so the prompt's
///   vocabulary block matches the picker's display order.
/// - `primariesByContext` maps each picked context to its picked primary
///   tag IDs.
/// - `deselectedSecondariesByPrimary` is *inverted* on purpose: it
///   tracks which secondaries the engineer toggled OFF inside a picked
///   primary. The default for any picked primary is "all secondaries
///   included", which means library additions automatically join the
///   project's vocabulary without the engineer re-picking every primary.
struct ProjectTagSelection: Codable, Hashable, Sendable {
    var contextIDs: [UUID]
    var primariesByContext: [UUID: Set<UUID>]
    var deselectedSecondariesByPrimary: [UUID: Set<UUID>]

    init(contextIDs: [UUID] = [],
         primariesByContext: [UUID: Set<UUID>] = [:],
         deselectedSecondariesByPrimary: [UUID: Set<UUID>] = [:]) {
        self.contextIDs = contextIDs
        self.primariesByContext = primariesByContext
        self.deselectedSecondariesByPrimary = deselectedSecondariesByPrimary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.contextIDs = try c.decodeIfPresent([UUID].self,
                                                 forKey: .contextIDs) ?? []
        self.primariesByContext = try c.decodeIfPresent([UUID: Set<UUID>].self,
                                                         forKey: .primariesByContext) ?? [:]
        self.deselectedSecondariesByPrimary = try c.decodeIfPresent([UUID: Set<UUID>].self,
                                                         forKey: .deselectedSecondariesByPrimary) ?? [:]
    }

    /// True when nothing's picked. Drives the "Pick at least one
    /// investigation context first" guard in the AI tagging runner.
    var isEmpty: Bool { contextIDs.isEmpty }

    /// Convenience for callers that want to know whether a given primary
    /// is selected within its context (after the context itself has been
    /// confirmed picked).
    func isPrimarySelected(_ primaryID: UUID, in contextID: UUID) -> Bool {
        primariesByContext[contextID]?.contains(primaryID) ?? false
    }

    func isSecondaryActive(_ secondaryID: UUID, under primaryID: UUID) -> Bool {
        !(deselectedSecondariesByPrimary[primaryID]?.contains(secondaryID) ?? false)
    }
}
