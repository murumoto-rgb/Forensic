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

    /// Explicit `CodingKeys` so the custom `init(from:)` + `encode(to:)`
    /// pair below compiles. Swift only auto-synthesizes `CodingKeys`
    /// when at most one of init/encode is custom; providing both kills
    /// synthesis. Keys match property names exactly — same on-disk and
    /// on-wire field names the previous synthesized version used.
    private enum CodingKeys: String, CodingKey {
        case contextIDs
        case primariesByContext
        case deselectedSecondariesByPrimary
    }

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
        self.primariesByContext = Self.decodeUUIDDict(
            in: c, key: .primariesByContext)
        self.deselectedSecondariesByPrimary = Self.decodeUUIDDict(
            in: c, key: .deselectedSecondariesByPrimary)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contextIDs, forKey: .contextIDs)
        try c.encode(Self.encodeUUIDDict(primariesByContext),
                     forKey: .primariesByContext)
        try c.encode(Self.encodeUUIDDict(deselectedSecondariesByPrimary),
                     forKey: .deselectedSecondariesByPrimary)
    }

    // MARK: - Codable helpers for the [UUID: Set<UUID>] sub-dictionaries
    //
    // Foundation's default Codable for `[UUID: Set<UUID>]` encodes as
    // a flat JSON *array* of alternating UUID strings and arrays
    // (because JSON objects can only have string keys; Foundation
    // falls back to alternating-array form for non-String-keyed
    // Swift dictionaries). That round-trips fine through Foundation
    // but is unparseable by the server's `z.record(uuid, …)` zod
    // schema, which expects a proper JSON object.
    //
    // To fix the wire format, we explicitly encode as
    // `[String: [String]]` (JSON object) using lowercase UUID
    // strings as keys. Decode tries the new shape first, falls back
    // to the legacy array form so on-disk manifests written by
    // earlier builds still load. The first save after this update
    // upgrades the on-disk format automatically.

    private static func encodeUUIDDict(_ dict: [UUID: Set<UUID>]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (key, value) in dict {
            result[key.uuidString.lowercased()] =
                value.map { $0.uuidString.lowercased() }
        }
        return result
    }

    private static func decodeUUIDDict(
        in container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> [UUID: Set<UUID>] {
        // Prefer the new String-keyed JSON-object form.
        if let stringKeyed = try? container.decodeIfPresent(
            [String: [String]].self, forKey: key) {
            var result: [UUID: Set<UUID>] = [:]
            for (k, v) in stringKeyed {
                guard let kUUID = UUID(uuidString: k) else { continue }
                let uuids = v.compactMap(UUID.init(uuidString:))
                result[kUUID] = Set(uuids)
            }
            return result
        }
        // Legacy: Foundation's flat-array form for `[UUID: Set<UUID>]`.
        if let legacy = try? container.decodeIfPresent(
            [UUID: Set<UUID>].self, forKey: key) {
            return legacy
        }
        return [:]
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
