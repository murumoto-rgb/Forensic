import Foundation
import CoreGraphics

// MARK: - Cluster fanning
//
// Self-contained, easy-to-revert experimental layout pass. Detects sets of
// primary markers whose drawn circles would overlap in plan-pixel space and
// fans them around their cluster centroid for rendering. Tails (any marker
// sharing a `groupKey` with a primary) move by the same offset so a stack
// stays glued to its primary.
//
// To remove this feature:
//   1. Delete this file.
//   2. In PlanViewerView, remove the two "MARK: cluster-fanning" blocks
//      and replace `let markers = fanResult.adjusted` with the original
//      `let markers = buildMarkers(...)` call site.
// No other code references this type.

enum ClusterFanning {

    struct LeaderLine: Hashable {
        let from: CGPoint   // true plan-pixel position
        let to:   CGPoint   // displayed (fanned) position
    }

    struct Result<M> {
        let adjusted:    [M]
        let leaderLines: [LeaderLine]
    }

    /// Apply the fanning transform to a generic marker array.
    /// - `groupKey`: returns a key that's identical for a primary and its
    ///   tails — they move together.
    /// - `position`: returns the marker's plan-pixel center.
    /// - `isPrimary`: only primaries participate in cluster detection.
    /// - `setPosition`: produces a new marker with the displayed center.
    /// - `collisionRadius`: plan-pixel distance below which two primaries
    ///   are considered to overlap.
    /// - `fanRadius`: plan-pixel distance from cluster centroid to each
    ///   fanned bubble. Defaults to collisionRadius / 2.
    static func apply<M>(
        markers: [M],
        groupKey: (M) -> String,
        position: (M) -> CGPoint,
        isPrimary: (M) -> Bool,
        setPosition: (M, CGPoint) -> M,
        collisionRadius: Double,
        fanRadius: Double? = nil
    ) -> Result<M> {
        let r = fanRadius ?? (collisionRadius / 2)

        let primaries = markers.indices.filter { isPrimary(markers[$0]) }
        guard primaries.count >= 2 else {
            return Result(adjusted: markers, leaderLines: [])
        }

        // Union-find over primary indices.
        var parent = [Int: Int]()
        for i in primaries { parent[i] = i }

        func find(_ x: Int) -> Int {
            var root = x
            while parent[root]! != root { root = parent[root]! }
            var cur = x
            while parent[cur]! != root {
                let next = parent[cur]!
                parent[cur] = root
                cur = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        let collisionSqr = collisionRadius * collisionRadius
        for i in primaries {
            for j in primaries where j > i {
                let pi = position(markers[i])
                let pj = position(markers[j])
                let dx = pi.x - pj.x, dy = pi.y - pj.y
                if dx*dx + dy*dy < collisionSqr { union(i, j) }
            }
        }

        // Bucket primaries by their cluster root.
        var clusters = [Int: [Int]]()
        for i in primaries {
            clusters[find(i), default: []].append(i)
        }

        var offsetByKey = [String: CGPoint]()
        var leaderLines = [LeaderLine]()

        for (_, members) in clusters where members.count > 1 {
            // Deterministic order by index so the fan layout doesn't reshuffle
            // between renders.
            let sorted = members.sorted()
            let n = Double(sorted.count)
            let sumX = sorted.reduce(0.0) { $0 + position(markers[$1]).x }
            let sumY = sorted.reduce(0.0) { $0 + position(markers[$1]).y }
            let centroid = CGPoint(x: sumX / n, y: sumY / n)

            for (k, idx) in sorted.enumerated() {
                // Place bubble k at angle (-π/2 + k·2π/n), so the first
                // member sits "north" of the centroid.
                let angle = -Double.pi / 2 + Double(k) * 2 * .pi / n
                let display = CGPoint(
                    x: centroid.x + cos(angle) * r,
                    y: centroid.y + sin(angle) * r
                )
                let truePos = position(markers[idx])
                offsetByKey[groupKey(markers[idx])] = CGPoint(
                    x: display.x - truePos.x,
                    y: display.y - truePos.y
                )
                leaderLines.append(LeaderLine(from: truePos, to: display))
            }
        }

        // Apply offsets to every marker (primary + tails) by its groupKey.
        let adjusted = markers.map { m -> M in
            guard let offset = offsetByKey[groupKey(m)] else { return m }
            let p = position(m)
            return setPosition(m, CGPoint(x: p.x + offset.x, y: p.y + offset.y))
        }

        return Result(adjusted: adjusted, leaderLines: leaderLines)
    }
}
