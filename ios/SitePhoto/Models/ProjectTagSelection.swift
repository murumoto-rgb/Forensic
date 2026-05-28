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

    /// Return a copy with every context, primary, and secondary ID
    /// that no longer resolves in `library` removed. Used to clean up
    /// stale references left over after a library reshape — e.g. the
    /// "Restore to default seed" action in the Tag Library Manager,
    /// a manual delete of a context/primary, or an app-update vocab
    /// change. Pruning is safe (never adds references, only removes
    /// dangling ones) and is the only path that touches stored
    /// selections at app launch — the seed-version migration that
    /// used to overwrite selections was removed in d7d306c.
    func pruning(against library: TagLibrary) -> ProjectTagSelection {
        let liveContextIDs = Set(library.contexts.map(\.id))
        let livePrimariesByContext: [UUID: Set<UUID>] = Dictionary(
            uniqueKeysWithValues: library.contexts.map { ($0.id, Set($0.primaries.map(\.id))) }
        )
        let liveSecondariesByPrimary: [UUID: Set<UUID>] = Dictionary(
            uniqueKeysWithValues: library.contexts
                .flatMap(\.primaries)
                .map { ($0.id, Set($0.secondaries.map(\.id))) }
        )

        var prunedContextIDs: [UUID] = []
        var prunedPrimariesByContext: [UUID: Set<UUID>] = [:]
        for contextID in contextIDs where liveContextIDs.contains(contextID) {
            prunedContextIDs.append(contextID)
            if let livePrimaries = livePrimariesByContext[contextID] {
                let picked = (primariesByContext[contextID] ?? [])
                    .intersection(livePrimaries)
                if !picked.isEmpty {
                    prunedPrimariesByContext[contextID] = picked
                }
            }
        }

        var prunedDeselected: [UUID: Set<UUID>] = [:]
        for (primaryID, deselectedSecIDs) in deselectedSecondariesByPrimary {
            guard let liveSecs = liveSecondariesByPrimary[primaryID] else { continue }
            let stillValid = deselectedSecIDs.intersection(liveSecs)
            if !stillValid.isEmpty {
                prunedDeselected[primaryID] = stillValid
            }
        }

        return ProjectTagSelection(
            contextIDs: prunedContextIDs,
            primariesByContext: prunedPrimariesByContext,
            deselectedSecondariesByPrimary: prunedDeselected
        )
    }
}
