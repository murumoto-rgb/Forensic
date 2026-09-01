import Foundation

struct PlanLayoutSnapshot {
    let primaries: [DisplayedPrimary]
    let arrowLengths: [UUID: Double]
}

/// One snapshot per viewer. Pan/zoom affect only drawing transforms, not
/// marker grouping or arrow intersections. Any photo/calibration edit, fit
/// size change, or bubble-size change invalidates this cache.
final class PlanLayoutCache {
    private var projectID: UUID?
    private var revision: UInt64?
    private var fit: Double?
    private var bubbleScale: Double?
    private var snapshot: PlanLayoutSnapshot?

    func value(projectID: UUID, revision: UInt64, fit: Double, bubbleScale: Double,
               build: () -> PlanLayoutSnapshot) -> PlanLayoutSnapshot {
        if self.projectID == projectID, self.revision == revision, self.fit == fit, self.bubbleScale == bubbleScale, let snapshot {
            return snapshot
        }
        let result = build()
        self.projectID = projectID
        self.revision = revision
        self.fit = fit
        self.bubbleScale = bubbleScale
        snapshot = result
        return result
    }
}
