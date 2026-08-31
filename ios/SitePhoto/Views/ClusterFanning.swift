import Foundation
import CoreGraphics

// MARK: - Cluster fanning + arrow shortening
//
// Self-contained, easy-to-revert experimental layout pass.
//
// Two transforms:
//
//  1. apply(...)   — fans clusters of overlapping primary markers around
//                    their cluster centroid for rendering. Tails inherit
//                    their primary's offset so a stack stays glued together.
//
//  2. arrowLengthAdjustments(...) — per-primary-marker, returns a shortened
//                    arrow length when the default-length arrow would cut
//                    through some other bubble in the layout.
//
// To remove this feature:
//   • Delete this file.
//   • In PlanViewerView, remove the three "MARK: cluster-fanning" blocks
//     and replace `let markers = fanResult.adjusted` with the original
//     buildMarkers(...) call site (and `arrowLengthFor(marker)` calls
//     with the static `arrowLengthView`).
// No other file references this type.

enum ClusterFanning {
    private struct Cell: Hashable { let x: Int; let y: Int }

    struct LeaderLine: Hashable {
        let from: CGPoint
        let to:   CGPoint
    }

    struct Result<M> {
        let adjusted:    [M]
        let leaderLines: [LeaderLine]
    }

    /// One cluster of overlapping primary markers, with the centroid
    /// already computed so the caller can render a single representative
    /// at that point without recomputing.
    ///
    /// `members` order matches the input markers' order — stable across
    /// renders so SwiftUI ForEach keeps view identity steady.
    struct PrimaryCluster<M> {
        let members: [M]
        let centroid: CGPoint
    }

    /// Detect clusters of overlapping primary markers WITHOUT applying
    /// any displacement. Returns one entry per primary in `markers` —
    /// singletons (no overlap) come back as a one-member cluster, real
    /// overlap groups come back with their members. Use this when the
    /// caller wants to render a stack badge / popover at the cluster
    /// centroid instead of fanning the members onto a rosette.
    ///
    /// `collisionRadius` and the union-find logic match what `apply(...)`
    /// uses, so a project that's clean under one will be clean under the
    /// other.
    static func detectPrimaryClusters<M>(
        markers: [M],
        position: (M) -> CGPoint,
        isPrimary: (M) -> Bool,
        collisionRadius: Double
    ) -> [PrimaryCluster<M>] {
        let primaryIdx = markers.indices.filter { isPrimary(markers[$0]) }
        guard !primaryIdx.isEmpty else { return [] }

        // Union-find — same shape as apply(...).
        var parent = [Int: Int]()
        for i in primaryIdx { parent[i] = i }
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
        let positions = Dictionary(uniqueKeysWithValues: primaryIdx.map { ($0, position(markers[$0])) })
        // Neighbor cells contain every possible collision, including across
        // zero/negative coordinates. Exact distance still decides membership.
        // Extremely large/nonfinite imported coordinates use the bounded old
        // pair scan instead of trapping during Double-to-Int conversion.
        let canIndex = collisionRadius.isFinite && collisionRadius > 0 && positions.values.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && abs($0.x / collisionRadius) < 1e12 && abs($0.y / collisionRadius) < 1e12
        }
        if canIndex {
            var cells: [Cell: [Int]] = [:]
            for i in primaryIdx {
                let pi = positions[i]!
                let cell = Cell(x: Int(floor(pi.x / collisionRadius)), y: Int(floor(pi.y / collisionRadius)))
                for dx in -1...1 { for dy in -1...1 {
                    for j in cells[Cell(x: cell.x + dx, y: cell.y + dy)] ?? [] {
                        let pj = positions[j]!
                        let x = pi.x - pj.x, y = pi.y - pj.y
                        if x * x + y * y < collisionSqr { union(i, j) }
                    }
                } }
                cells[cell, default: []].append(i)
            }
        } else {
            for i in primaryIdx { for j in primaryIdx where j > i {
                let pi = positions[i]!, pj = positions[j]!
                let dx = pi.x - pj.x, dy = pi.y - pj.y
                if dx * dx + dy * dy < collisionSqr { union(i, j) }
            } }
        }

        // Group by root, preserving the input ordering of the first
        // member so the resulting array is stable across re-renders.
        var bucketByRoot: [Int: [Int]] = [:]
        var rootOrder: [Int] = []
        for i in primaryIdx {
            let r = find(i)
            if bucketByRoot[r] == nil {
                bucketByRoot[r] = []
                rootOrder.append(r)
            }
            bucketByRoot[r]!.append(i)
        }

        return rootOrder.map { root -> PrimaryCluster<M> in
            let memberIdx = bucketByRoot[root]!
            let members = memberIdx.map { markers[$0] }
            let n = Double(memberIdx.count)
            let sumX = memberIdx.reduce(0.0) { $0 + position(markers[$1]).x }
            let sumY = memberIdx.reduce(0.0) { $0 + position(markers[$1]).y }
            let centroid = CGPoint(x: sumX / n, y: sumY / n)
            return PrimaryCluster(members: members, centroid: centroid)
        }
    }

    /// Fan clusters of overlapping primaries around their centroid.
    ///
    /// - `sortKey`: a stable, render-independent key (e.g. photo sequence
    ///   number) used to lay out fan members in a consistent order.
    ///   Sorting by input-array index is unstable because `buildMarkers`
    ///   iterates a Dictionary; switching to a property-based key makes
    ///   the layout deterministic across re-renders (zoom, pan, etc).
    /// - `collisionRadius`: plan-pixel distance below which two primaries
    ///   are considered overlapping for *cluster detection*. Callers may
    ///   pass a value larger than the actual bubble (e.g. floored at the
    ///   default scale) so tight clusters of small bubbles still get
    ///   detected.
    /// - `bubbleRadius`: plan-pixel radius of the *rendered* primary
    ///   bubble. Used to compute the fan layout — chord length between
    ///   neighbours, minimum fan radius. Decoupling this from
    ///   `collisionRadius` lets cluster detection be generous without
    ///   blowing the fan radius out beyond the visible bubble size,
    ///   which would scatter small bubbles far away from the plan with
    ///   long leader lines bridging the gap.
    /// - `minSpacing`: minimum edge-to-edge gap between fanned bubbles.
    ///   Typically scales with `bubbleRadius` so the gap looks
    ///   proportional at any bubble size.
    static func apply<M, K: Comparable>(
        markers: [M],
        sortKey: (M) -> K,
        groupKey: (M) -> String,
        position: (M) -> CGPoint,
        isPrimary: (M) -> Bool,
        setPosition: (M, CGPoint) -> M,
        collisionRadius: Double,
        bubbleRadius: Double,
        minSpacing: Double
    ) -> Result<M> {
        let bubbleR = bubbleRadius

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
                if dx * dx + dy * dy < collisionSqr { union(i, j) }
            }
        }

        var clusters = [Int: [Int]]()
        for i in primaries {
            clusters[find(i), default: []].append(i)
        }

        var offsetByKey  = [String: CGPoint]()
        var leaderLines  = [LeaderLine]()

        for (_, members) in clusters where members.count > 1 {
            // Sort by a stable photo-property key, NOT by input array index.
            // Index-based sort permutes between renders because the upstream
            // markers array can come out in different orders.
            let sorted = members.sorted {
                sortKey(markers[$0]) < sortKey(markers[$1])
            }
            let n      = Double(sorted.count)

            // Adaptive fan radius: keep `minSpacing` between adjacent
            // bubbles regardless of N. Centers are evenly spaced on a
            // ring of radius r; 2r·sin(π/N) is the chord length between
            // neighbours, so r = (2·bubbleR + minSpacing) / (2·sin(π/N)).
            let chord = 2 * bubbleR + minSpacing
            let r = max(
                bubbleR + minSpacing / 2,
                chord / (2 * sin(.pi / n))
            )

            let sumX = sorted.reduce(0.0) { $0 + position(markers[$1]).x }
            let sumY = sorted.reduce(0.0) { $0 + position(markers[$1]).y }
            let centroid = CGPoint(x: sumX / n, y: sumY / n)

            for (k, idx) in sorted.enumerated() {
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

        let adjusted = markers.map { m -> M in
            guard let off = offsetByKey[groupKey(m)] else { return m }
            let p = position(m)
            return setPosition(m, CGPoint(x: p.x + off.x, y: p.y + off.y))
        }

        return Result(adjusted: adjusted, leaderLines: leaderLines)
    }

    /// For each primary marker with a heading arrow, returns the longest
    /// arrow length that doesn't cross any other bubble in the layout.
    /// Arrows that don't clash get the full `defaultArrowLength`.
    ///
    /// All distances are in PLAN-PIXEL coordinates.
    static func arrowLengthAdjustments<M>(
        markers: [M],
        id: (M) -> UUID,
        position: (M) -> CGPoint,
        isPrimary: (M) -> Bool,
        bearingDegrees: (M) -> Double?,
        primaryRadius: Double,
        secondaryRadius: Double,
        defaultArrowLength: Double
    ) -> [UUID: Double] {
        var out = [UUID: Double]()
        // Visual breathing room between the arrow tip and the obstacle.
        let margin = max(primaryRadius * 0.18, 4.0)

        // A circle can affect this finite ray only within this conservative
        // radius. Index once, then examine neighboring cells; exact ray/circle
        // math below remains the authority. Dense overlaps can still be O(n²),
        // but ordinary spread-out plans no longer scan every other marker.
        let cellSide = defaultArrowLength + 2 * (max(primaryRadius, secondaryRadius) + margin)
        let positions = markers.map(position)
        let canIndex = cellSide.isFinite && cellSide > 0 && positions.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && abs($0.x / cellSide) < 1e12 && abs($0.y / cellSide) < 1e12
        }
        var cells: [Cell: [Int]] = [:]
        if canIndex {
            for (i, point) in positions.enumerated() {
                cells[Cell(x: Int(floor(point.x / cellSide)), y: Int(floor(point.y / cellSide))), default: []].append(i)
            }
        }

        for (index, m) in markers.enumerated() {
            guard isPrimary(m), let b = bearingDegrees(m) else { continue }

            let A      = positions[index]
            let myID   = id(m)
            let myR    = primaryRadius
            let angRad = (b - 90) * .pi / 180
            let dx     = cos(angRad)
            let dy     = sin(angRad)

            var bestLength = defaultArrowLength

            var candidates: [Int]
            if canIndex {
                let cell = Cell(x: Int(floor(A.x / cellSide)), y: Int(floor(A.y / cellSide)))
                candidates = []
                for x in -1...1 { for y in -1...1 {
                    candidates.append(contentsOf: cells[Cell(x: cell.x + x, y: cell.y + y)] ?? [])
                } }
            } else { candidates = Array(markers.indices) }
            for otherIndex in candidates {
                let other = markers[otherIndex]
                if id(other) == myID { continue }
                let B = positions[otherIndex]
                let R = isPrimary(other) ? primaryRadius : secondaryRadius
                let abx = B.x - A.x
                let aby = B.y - A.y

                // Project AB onto arrow direction.
                let t = abx * dx + aby * dy
                if t < myR { continue }                       // behind / inside us
                if t > defaultArrowLength + R + margin { continue } // out of range

                // Perpendicular distance² from line to B.
                let perpSq = abx * abx + aby * aby - t * t
                let RR = (R + margin) * (R + margin)
                guard perpSq < RR else { continue }

                let entry = t - sqrt(RR - perpSq)
                if entry > myR + margin && entry < bestLength {
                    bestLength = entry
                }
            }

            // Don't shrink so much the arrow disappears into the bubble.
            let minLength = myR + margin * 2
            out[myID] = max(minLength, bestLength)
        }
        return out
    }
}
