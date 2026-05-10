import SwiftUI
import UIKit

/// Pick which AI-attributed tags to clear and which photos to clear them
/// from. Defaults to "every AI tag in the project", which mirrors the
/// previous full-clear behaviour for the tag portion. Selecting a subset
/// of tags narrows both the photo list (only photos that carry at least
/// one selected tag remain selectable) and the action (only the selected
/// tags are removed). Manually-typed tags (confidence 1.0) are preserved,
/// and the photo's `aiAnalysis` / legacy AI metadata are left intact —
/// this sheet is now strictly about removing tags.
struct ClearAITagsSheet: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var photoSelection: Set<UUID> = []
    @State private var tagSelectors: Set<ProjectStore.TagSelector> = []
    @State private var didInitTagSelectors: Bool = false
    @State private var confirming: Bool = false

    private var project: Project? { store.project(withID: projectID) }
    private var photos: [Photo] { project?.photos ?? [] }

    /// Hierarchical view of every AI-attributed tag (confidence < 1.0) plus
    /// every pending suggestion currently on a photo. Sorted in canonical
    /// guide order: primaries Drainage / Grading … Poor / Unclear Photo,
    /// then any unknown primaries, with secondaries listed under each.
    private var aiTagGroups: [TagGroup] {
        buildGroups(from: photos)
    }

    /// Flat set of every selectable token surfaced in the chip list.
    /// Used to seed `tagSelectors` on first appearance and to drive
    /// "Select All / None" toggling.
    private var allSelectors: Set<ProjectStore.TagSelector> {
        var out: Set<ProjectStore.TagSelector> = []
        for group in aiTagGroups {
            out.insert(.init(label: group.primary))
            for sec in group.secondaries {
                out.insert(.init(parent: group.primary, label: sec.label))
            }
        }
        return out
    }

    /// Photos eligible for selection: those that carry at least one tag
    /// or pending suggestion matching the current `tagSelectors`. With no
    /// selectors, returns the empty list — there's nothing to clear.
    private var matchingPhotos: [Photo] {
        guard !tagSelectors.isEmpty else { return [] }
        return photos.filter { photo in
            tagsOnPhoto(photo).contains { tag in
                selectorMatches(parent: tag.parent, label: tag.label)
            }
        }
    }

    /// True when the user has every chip checked. Mirrors today's
    /// "clear every AI tag" default.
    private var allTagsSelected: Bool {
        !allSelectors.isEmpty && tagSelectors == allSelectors
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                infoBanner
                Divider()
                if aiTagGroups.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.seal",
                        title: "Nothing to clear",
                        message: "No photo in this project has AI tags or pending suggestions."
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            tagChipsSection
                            Divider()
                            photoListSection
                        }
                    }
                }
                Divider()
                bottomBar
            }
            .navigationTitle("Clear AI Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(
                "Clear \(tagSelectors.count) tag\(tagSelectors.count == 1 ? "" : "s") from \(photoSelection.count) photo\(photoSelection.count == 1 ? "" : "s")?",
                isPresented: $confirming
            ) {
                Button("Clear", role: .destructive) {
                    runClear()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the chosen AI tags (and any pending suggestions for those tags) from the selected photos. Manually-typed tags and the photo's saved AI analysis are preserved. This cannot be undone.")
            }
            .onAppear {
                if !didInitTagSelectors {
                    tagSelectors = allSelectors
                    didInitTagSelectors = true
                }
            }
            // If the user clears tags and the chip set shrinks, drop any
            // selectors that no longer have a matching chip so the "select
            // all" check stays consistent.
            .onChange(of: aiTagGroups) { _, _ in
                tagSelectors.formIntersection(allSelectors)
                photoSelection = photoSelection.intersection(
                    matchingPhotos.map(\.id)
                )
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var infoBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pick the AI tags to clear, then the photos to clear them from.")
                .font(.callout)
            Text("Manually-typed tags are kept. The photo's saved AI analysis (caption, recommended use, etc.) is also preserved — only tags and matching pending suggestions are removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private var tagChipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tags to clear")
                    .font(.subheadline.bold())
                Spacer()
                Button(allTagsSelected ? "Deselect All" : "Select All") {
                    if allTagsSelected {
                        tagSelectors.removeAll()
                    } else {
                        tagSelectors = allSelectors
                    }
                }
                .font(.caption)
            }
            ForEach(aiTagGroups, id: \.primary) { group in
                tagGroupRow(group)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func tagGroupRow(_ group: TagGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                primaryChip(for: group)
                Spacer(minLength: 0)
            }
            if !group.secondaries.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(group.secondaries, id: \.label) { sec in
                        secondaryChip(for: group, secondary: sec)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    /// Larger, accent-coloured chip for a primary tag. Tapping it cascades
    /// to every secondary under the same primary — selecting the primary
    /// auto-checks all its secondary chips, and deselecting clears them
    /// — so the visible chip state always reflects "the whole bucket is
    /// queued for clearing." Tapping a secondary chip independently does
    /// NOT touch the primary; that one-way cascade matches what the user
    /// asked for.
    @ViewBuilder
    private func primaryChip(for group: TagGroup) -> some View {
        let selector = ProjectStore.TagSelector(label: group.primary)
        let on = tagSelectors.contains(selector)
        Button {
            let secondarySelectors = group.secondaries.map {
                ProjectStore.TagSelector(parent: group.primary, label: $0.label)
            }
            if on {
                tagSelectors.remove(selector)
                for s in secondarySelectors { tagSelectors.remove(s) }
            } else {
                tagSelectors.insert(selector)
                for s in secondarySelectors { tagSelectors.insert(s) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                Text(group.primary)
                    .font(.callout.weight(.semibold))
                Text("\(group.primaryCount)")
                    .font(.caption.monospaced())
                    .foregroundStyle(on ? Color.white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                on ? Color.accentColor : Color.accentColor.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(on ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// Smaller, purple chip for a secondary tag. Tapping toggles only
    /// this exact (parent, label) selector — never touches the primary.
    @ViewBuilder
    private func secondaryChip(for group: TagGroup,
                                secondary sec: TagGroup.SecondaryEntry) -> some View {
        let selector = ProjectStore.TagSelector(parent: group.primary, label: sec.label)
        let on = tagSelectors.contains(selector)
        Button {
            if on { tagSelectors.remove(selector) } else { tagSelectors.insert(selector) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.caption2)
                Text(sec.label)
                    .font(.caption)
                Text("\(sec.count)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(on ? Color.white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                on ? Color.purple : Color.purple.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(on ? Color.white : Color.purple)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var photoListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Photos with selected tags")
                    .font(.subheadline.bold())
                Text("(\(matchingPhotos.count))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                let allMatchingSelected = !matchingPhotos.isEmpty
                    && matchingPhotos.allSatisfy { photoSelection.contains($0.id) }
                Button(allMatchingSelected ? "Deselect All" : "Select All") {
                    if allMatchingSelected {
                        photoSelection.subtract(matchingPhotos.map(\.id))
                    } else {
                        photoSelection.formUnion(matchingPhotos.map(\.id))
                    }
                }
                .font(.caption)
                .disabled(matchingPhotos.isEmpty)
            }
            if tagSelectors.isEmpty {
                Text("Pick at least one tag to see matching photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if matchingPhotos.isEmpty {
                Text("No photos carry the selected tags.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(matchingPhotos) { photo in
                        photoRow(photo)
                        Divider()
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func photoRow(_ photo: Photo) -> some View {
        let isSelected = photoSelection.contains(photo.id)
        Button {
            if isSelected {
                photoSelection.remove(photo.id)
            } else {
                photoSelection.insert(photo.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                photoThumbnail(photo)
                    .frame(width: 56, height: 42)
                    .clipped()
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(photo.sequenceNumber)")
                        .font(.subheadline.monospaced())
                    Text(matchedTagsLine(for: photo))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func photoThumbnail(_ photo: Photo) -> some View {
        if let project,
           let url = store.thumbnailURL(for: photo, in: project),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            Text(selectionSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                confirming = true
            } label: {
                Label("Clear Tags", systemImage: "eraser")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(photoSelection.isEmpty || tagSelectors.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Behaviour

    private var selectionSummary: String {
        if tagSelectors.isEmpty {
            return "Pick tags to clear."
        }
        if photoSelection.isEmpty {
            return "Pick photos to clear from."
        }
        return "\(photoSelection.count) of \(matchingPhotos.count) photos · \(tagSelectors.count) tag\(tagSelectors.count == 1 ? "" : "s")"
    }

    private func runClear() {
        guard let project else { return }
        let photoCount = photoSelection.count
        let tagCount = tagSelectors.count
        _ = store.removeTags(project,
                             photoIDs: photoSelection,
                             selectors: tagSelectors)
        photoSelection.removeAll()
        Haptics.confirm()
        toastCenter.post("Cleared \(tagCount) tag\(tagCount == 1 ? "" : "s") from \(photoCount) photo\(photoCount == 1 ? "" : "s")",
                          kind: .success)
    }

    /// True when a tag with these (parent, label) coordinates would be
    /// removed by the current `tagSelectors`. Mirrors the matching logic
    /// in `ProjectStore.removeTags` so the UI's photo list can predict
    /// what the action will touch.
    private func selectorMatches(parent: String?, label: String) -> Bool {
        let lc = label.lowercased()
        for sel in tagSelectors {
            if sel.parent == nil {
                let primaryLC = sel.label.lowercased()
                if parent == nil, primaryLC == lc { return true }
                if let parent, parent.lowercased() == primaryLC { return true }
            } else if let selParent = sel.parent,
                      selParent.lowercased() == (parent?.lowercased() ?? ""),
                      sel.label.lowercased() == lc {
                return true
            }
        }
        return false
    }

    /// Comma-separated list of the tags on `photo` that would be removed
    /// by the current selection. Helps the user verify they're picking
    /// the right photos.
    private func matchedTagsLine(for photo: Photo) -> String {
        let matched = tagsOnPhoto(photo).filter {
            selectorMatches(parent: $0.parent, label: $0.label)
        }
        if matched.isEmpty { return "—" }
        return matched.map { tag in
            tag.parent.map { "\($0) / \(tag.label)" } ?? tag.label
        }.joined(separator: " · ")
    }

    /// Flatten this photo's tags + pending suggestions into a uniform
    /// list of (parent, label) coordinates so the chip-matching logic
    /// only needs to walk one collection. Manually-typed tags
    /// (confidence == 1.0) are excluded — the sheet only operates on
    /// AI-attributed entries.
    private func tagsOnPhoto(_ photo: Photo) -> [(parent: String?, label: String)] {
        var out: [(String?, String)] = []
        for t in photo.tags where t.confidence < 1.0 {
            out.append((t.parentTag, t.label))
        }
        for s in photo.pendingSuggestions {
            out.append((s.parentTag, s.label))
        }
        return out
    }

    /// Build the AI-only tag hierarchy for `photos`. Mirrors the shape of
    /// `ProjectStore.tagsUsedHierarchically` but filters to confidence < 1.0
    /// and pulls in pending suggestions, both of which the public helper
    /// doesn't surface today.
    private func buildGroups(from photos: [Photo]) -> [TagGroup] {
        struct Bucket {
            var displayCounts: [String: Int] = [:]
            var primaryUsed: Bool = false
            var primaryCount: Int = 0
            var secondaries: [String: (display: String, count: Int)] = [:]
        }
        var buckets: [String: Bucket] = [:]

        func bumpDisplay(_ bucket: inout Bucket, _ display: String) {
            bucket.displayCounts[display, default: 0] += 1
        }

        for photo in photos {
            let entries = tagsOnPhoto(photo)
            for (parent, label) in entries {
                if let parent {
                    let pLC = parent.lowercased()
                    var b = buckets[pLC] ?? Bucket()
                    bumpDisplay(&b, parent)
                    let sLC = label.lowercased()
                    let existing = b.secondaries[sLC]
                    b.secondaries[sLC] = (
                        display: existing?.display ?? label,
                        count: (existing?.count ?? 0) + 1
                    )
                    buckets[pLC] = b
                } else {
                    let pLC = label.lowercased()
                    var b = buckets[pLC] ?? Bucket()
                    bumpDisplay(&b, label)
                    b.primaryUsed = true
                    b.primaryCount += 1
                    buckets[pLC] = b
                }
            }
        }

        // Order: known primaries in canonical guide order first, then any
        // unknown primaries alphabetically.
        let canonicalRank: (String) -> Int = { lc in
            ControlledVocabulary.primariesLowercased.contains(lc)
                ? ControlledVocabulary.primaryRank(lc)
                : Int.max
        }
        let sortedKeys = buckets.keys.sorted { lhs, rhs in
            let lr = canonicalRank(lhs)
            let rr = canonicalRank(rhs)
            if lr != rr { return lr < rr }
            return lhs < rhs
        }

        return sortedKeys.map { key in
            let b = buckets[key]!
            let display = b.displayCounts.max { $0.value < $1.value }?.key ?? key
            let secs = b.secondaries.values
                .map { TagGroup.SecondaryEntry(label: $0.display, count: $0.count) }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.label.lowercased() < rhs.label.lowercased()
                }
            return TagGroup(primary: display,
                            primaryUsed: b.primaryUsed,
                            primaryCount: b.primaryCount,
                            secondaries: secs)
        }
    }

    /// Local mirror of `ProjectStore.TagGroup` so this sheet can compute
    /// its own AI-only hierarchy without widening the public API.
    fileprivate struct TagGroup: Hashable {
        let primary: String
        let primaryUsed: Bool
        let primaryCount: Int
        let secondaries: [SecondaryEntry]

        struct SecondaryEntry: Hashable {
            let label: String
            let count: Int
        }
    }
}

// FlowLayout is defined in PhotoTagEditorSheet.swift at module scope; this
// sheet reuses it for the chip rows.
