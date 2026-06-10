// Split out of ProjectDetailView.swift (Build #6.23.1 — iOS
// decomposition part 1). File-scope support types moved verbatim;
// the only change is dropping the file-scope `fileprivate`/`private`
// (these are now internal, same module). No behavior change.

import SwiftUI

struct PhotoRow: View {
    let photo: Photo
    let project: Project
    let store: ProjectStore
    var onLocate: (() -> Void)? = nil
    var onTag: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil
    var onReshoot: (() -> Void)? = nil
    var onCompare: (() -> Void)? = nil
    @AppStorage("sitephoto.tagConfidenceThreshold")
    private var tagConfidenceThreshold: Double = 0.5

    /// Compact timestamp formatter cached once per view type — used on
    /// every row, so allocating a new `DateFormatter` per render would
    /// noticeably affect scroll performance on big project lists. The
    /// `h:mm a` token respects the user's locale's AM/PM marker; 24-hour
    /// locales render `13:12`-style automatically.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy '@' h:mm a"
        return f
    }()

    /// Tags above the visibility threshold, sorted to read top-to-bottom
    /// the same way they appear in the AI guide: primaries in canonical
    /// order, secondaries grouped under their primary. The chip itself
    /// only shows the label string — combining "Primary / Secondary" would
    /// make every chip wide and lose the visual hierarchy.
    private var visibleTags: [Tag] {
        let kept = photo.tags.filter { $0.confidence >= tagConfidenceThreshold }
        return kept.sorted { lhs, rhs in
            let lParent = lhs.parentTag ?? lhs.label
            let rParent = rhs.parentTag ?? rhs.label
            let lr = ControlledVocabulary.primaryRank(lParent)
            let rr = ControlledVocabulary.primaryRank(rParent)
            if lr != rr { return lr < rr }
            if lParent.lowercased() != rParent.lowercased() {
                return lParent.lowercased() < rParent.lowercased()
            }
            // Same primary bucket — primary itself first, then secondaries.
            let lIsPrimary = lhs.parentTag == nil
            let rIsPrimary = rhs.parentTag == nil
            if lIsPrimary != rIsPrimary { return lIsPrimary }
            return lhs.label.lowercased() < rhs.label.lowercased()
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onTag?()
            } label: {
                thumbnail
                    .frame(width: 144, height: 108)
                    .clipped()
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(photo.sequenceNumber)")
                        .font(.headline.monospaced())
                        .layoutPriority(1)
                    if photo.groupID != nil {
                        // Stacked-folders glyph mirrors the group-picker
                        // toolbar; filled variant marks the lead so it
                        // still reads at a glance.
                        Image(systemName: photo.isPrimary
                              ? "rectangle.stack.fill"
                              : "rectangle.stack")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                    let livePending = photo.pendingSuggestions.filter { $0.source == .claude }
                    if !livePending.isEmpty {
                        badge(text: "AI \(livePending.count)", color: .purple)
                    }
                }
                Text(Self.timestampFormatter.string(from: photo.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let bucket = bucketFor(photo) {
                    bucketBadge(bucket)
                }
            }
            Spacer()
            VStack(spacing: 6) {
                if let onToggleFavorite {
                    Button {
                        onToggleFavorite()
                    } label: {
                        Image(systemName: photo.isFavorite ? "star.fill" : "star")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(photo.isFavorite ? .yellow : .secondary)
                    .accessibilityLabel(photo.isFavorite
                                         ? "Remove from favorites"
                                         : "Add to favorites")
                }
                if let onTag {
                    Button {
                        onTag()
                    } label: {
                        Image(systemName: visibleTags.isEmpty ? "tag" : "tag.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.purple)
                    .accessibilityLabel("Edit Tags")
                }
                if let onLocate, project.floorPlan != nil {
                    let isUnlocated = photo.positionSource == .none
                    Button {
                        onLocate()
                    } label: {
                        Image(systemName: "location")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    // Grey when the photo has no plan position yet; blue
                    // once it's been placed. Same tap target either way —
                    // RelocateSheet handles both "set initial" and
                    // "change existing" via its pre-fill logic.
                    .tint(isUnlocated ? .secondary : .blue)
                    .accessibilityLabel(isUnlocated ? "Add Location" : "Change Location")
                }
                if onReshoot != nil || onCompare != nil {
                    rowOverflowMenu
                }
            }
        }
    }

    /// Tiny `…` menu sitting under the per-row action stack. Keeps the
    /// reshoot / comparison entry points discoverable without crowding
    /// the row with two more icon buttons.
    @ViewBuilder
    private var rowOverflowMenu: some View {
        Menu {
            if let onReshoot {
                Button {
                    onReshoot()
                } label: {
                    Label("Reshoot This Photo", systemImage: "camera.rotate")
                }
            }
            if let onCompare, hasReshootLineage {
                Button {
                    onCompare()
                } label: {
                    Label("Compare with Reshoots", systemImage: "rectangle.on.rectangle.angled")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.secondary)
        .accessibilityLabel("More actions")
    }

    /// True when the photo is the root of a reshoot lineage *or* is itself
    /// a reshoot of something else — either way the compare view has more
    /// than one frame to show.
    private var hasReshootLineage: Bool {
        if photo.reshootsPhotoID != nil { return true }
        return project.photos.contains(where: { $0.reshootsPhotoID == photo.id })
    }

    private var thumbnail: some View {
        // Build #6.4.1: async cached load — the old synchronous
        // Data(contentsOf:) + UIImage(data:) here ran a disk read +
        // JPEG decode on the MainActor for every visible row.
        CachedThumbnail(url: store.thumbnailURL(for: photo, in: project))
    }

    @ViewBuilder
    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold().monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    /// Resolve the photo's bucket against the project's defined buckets.
    /// Returns nil for unbucketed photos or for stale references whose
    /// bucket has since been deleted (ProjectStore.deleteBucket nilifies
    /// these on save, but a freshly-decoded manifest could still carry an
    /// orphan reference).
    private func bucketFor(_ photo: Photo) -> Bucket? {
        guard let id = photo.bucketID else { return nil }
        return project.buckets.first(where: { $0.id == id })
    }

    @ViewBuilder
    private func bucketBadge(_ bucket: Bucket) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(bucket.color)
                .frame(width: 7, height: 7)
            Text(bucket.name)
                .font(.caption2.bold())
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(bucket.color.opacity(0.2), in: Capsule())
        .foregroundStyle(bucket.color)
    }

}

#Preview {
    let store = ProjectStore()
    let location = LocationService()
    let p = Project(name: "Demo project")
    let saved = store.save(p)
    return NavigationStack {
        ProjectDetailView(projectID: saved.id)
            .environment(store)
            .environment(location)
    }
}

// ---------------------------------------------------------------------
// Conditional search bar (Build #5.128.1)
// ---------------------------------------------------------------------

