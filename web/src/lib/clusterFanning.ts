/**
 * Spatial cluster detection for floor-plan primary pins.
 *
 * Direct TypeScript port of
 * `ios/SitePhoto/Views/ClusterFanning.swift::detectPrimaryClusters`
 * (see Build #5.26.1). Same union-find algorithm, same collision
 * predicate (distance² < radius²), same ordering invariants — so a
 * project that's clean under iOS is clean under web, and a project
 * that clusters under iOS clusters under web at equivalent scales.
 *
 * "Primary pin" = a photo with no groupID, or the lead photo of its
 * groupID — i.e. exactly what `FloorPlanCanvas` already renders as a
 * single PhotoPin. Cluster detection runs over that already-collapsed
 * set; it does NOT see non-primary group members. (This matches iOS,
 * which collapses group leads first and then clusters them.)
 *
 * Output: one cluster per primary input item. Singletons (no overlap)
 * come back as one-member clusters; that lets the caller iterate a
 * single list and treat singletons + multi-clusters uniformly.
 *
 * The members within each cluster are returned in the SAME order they
 * appear in the input array — important because the upstream input is
 * a `.filter()`'d projection of `project.photos`, which is itself a
 * stable order (sequence number); preserving input order makes the
 * cluster lead deterministic and the popover list ordered.
 */

export interface PrimaryCluster<T> {
  members: T[];
  centroidX: number;
  centroidY: number;
}

export function detectPrimaryClusters<T>(
  items: T[],
  position: (item: T) => { x: number; y: number },
  collisionRadius: number
): Array<PrimaryCluster<T>> {
  if (items.length === 0) return [];

  // Union-find on indices into `items`. Path-compression `find` and
  // size-agnostic `union` (same shape as the Swift original — simple,
  // O(N·α(N)) for typical project sizes; we're never above a few
  // thousand pins, well within any practical bound).
  const parent = new Array<number>(items.length);
  for (let i = 0; i < items.length; i++) parent[i] = i;
  // All `parent[...]` accesses are guaranteed defined because we
  // populated every index 0..items.length-1 above, and every index
  // we pass in below is in that same range. We use `as number` to
  // satisfy TS's noUncheckedIndexedAccess without runtime overhead.
  function find(x: number): number {
    let root = x;
    while ((parent[root] as number) !== root) root = parent[root] as number;
    // Path compression: rewire everything along the chain to root.
    let cur = x;
    while ((parent[cur] as number) !== root) {
      const next = parent[cur] as number;
      parent[cur] = root;
      cur = next;
    }
    return root;
  }
  function union(a: number, b: number) {
    const ra = find(a);
    const rb = find(b);
    if (ra !== rb) parent[ra] = rb;
  }

  // Distance² test against radius² avoids per-pair sqrt — same trick
  // the iOS code uses. O(N²) over primaries; fine at our scale.
  const rsq = collisionRadius * collisionRadius;
  for (let i = 0; i < items.length; i++) {
    const pi = position(items[i] as T);
    for (let j = i + 1; j < items.length; j++) {
      const pj = position(items[j] as T);
      const dx = pi.x - pj.x;
      const dy = pi.y - pj.y;
      if (dx * dx + dy * dy < rsq) union(i, j);
    }
  }

  // Bucket indices by root, preserving input order of the FIRST member
  // so the resulting clusters array is stable across re-renders.
  const bucketByRoot = new Map<number, number[]>();
  const rootOrder: number[] = [];
  for (let i = 0; i < items.length; i++) {
    const r = find(i);
    let bucket = bucketByRoot.get(r);
    if (!bucket) {
      bucket = [];
      bucketByRoot.set(r, bucket);
      rootOrder.push(r);
    }
    bucket.push(i);
  }

  return rootOrder.map((root): PrimaryCluster<T> => {
    const memberIdx = bucketByRoot.get(root)!;
    // memberIdx entries come from iterating 0…items.length-1, so the
    // `items[i]` access is always defined. We assert it for TS's
    // benefit (noUncheckedIndexedAccess is on).
    const members: T[] = memberIdx.map((i) => items[i] as T);
    let sumX = 0;
    let sumY = 0;
    for (const idx of memberIdx) {
      const p = position(items[idx] as T);
      sumX += p.x;
      sumY += p.y;
    }
    const n = memberIdx.length;
    return {
      members,
      centroidX: sumX / n,
      centroidY: sumY / n,
    };
  });
}
