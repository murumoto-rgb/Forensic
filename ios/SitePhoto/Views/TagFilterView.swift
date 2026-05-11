import SwiftUI
import UIKit

/// Tag-driven photo browser. Tags live in a primary→secondary hierarchy
/// (see `ControlledVocabulary`); the filter UI shows one collapsible section per
/// primary, with the primary chip filtering "anything under this category"
/// and each secondary chip filtering for that exact tag. Selection works
/// at either level and across categories — AND requires every selected
/// criterion to match, OR requires at least one.
struct TagFilterView: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sitephoto.tagConfidenceThreshold")
    private var tagConfidenceThreshold: Double = 0.5

    @State private var selected: Set<Criterion> = []
    @State private var matchMode: MatchMode = .all
    @State private var taggingPhoto: PhotoTarget?
    /// Primary tag names whose secondary chip strip is collapsed. We store
    /// the *collapsed* set rather than the expanded set so the default
    /// (everything expanded) needs no per-primary bookkeeping.
    @State private var collapsedPrimaries: Set<String> = []

    enum MatchMode: String, CaseIterable, Identifiable {
        case all   // AND — photo must match every selected criterion
        case any   // OR  — photo must match at least one
        var id: String { rawValue }
        var label: String { self == .all ? "All (AND)" : "Any (OR)" }
    }

    /// One tappable filter chip. `.primary` matches photos that carry the
    /// primary tag itself OR any secondary under that primary. `.secondary`
    /// matches only photos with that exact (parent, label) coordinate.
    enum Criterion: Hashable {
        case primary(String)
        case secondary(parent: String, label: String)
    }

    private struct PhotoTarget: Identifiable {
        let id: UUID
    }

    private var project: Project? { store.project(withID: projectID) }

    /// Hierarchical tag groups (primaries with their secondaries) with
    /// counts, sorted in canonical guide order. Drives the filter chip
    /// layout and the empty state.
    private var groups: [ProjectStore.TagGroup] {
        guard let project else { return [] }
        return store.tagsUsedHierarchically(in: project,
                                             minConfidence: tagConfidenceThreshold)
    }

    /// Filtered photo list based on the current criterion selection + mode.
    private var matches: [Photo] {
        guard let project else { return [] }
        guard !selected.isEmpty else { return [] }
        let crits = Array(selected)
        return project.photos.filter { photo in
            switch matchMode {
            case .all: return crits.allSatisfy { photoMatches(photo, $0) }
            case .any: return crits.contains { photoMatches(photo, $0) }
            }
        }
    }

    /// True when `photo` satisfies `criterion` at the user's confidence
    /// threshold. Tags below the threshold are ignored so the results match
    /// what the user actually sees on the photo rows.
    private func photoMatches(_ photo: Photo, _ criterion: Criterion) -> Bool {
        let visible = photo.tags.filter { $0.confidence >= tagConfidenceThreshold }
        switch criterion {
        case .primary(let name):
            let lc = name.lowercased()
            return visible.contains { tag in
                (tag.parentTag == nil && tag.label.lowercased() == lc) ||
                (tag.parentTag?.lowercased() == lc)
            }
        case .secondary(let parent, let label):
            let pLC = parent.lowercased()
            let lLC = label.lowercased()
            return visible.contains { tag in
                tag.parentTag?.lowercased() == pLC &&
                tag.label.lowercased() == lLC
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modeHeader
                Divider()
                tagPickerArea
                Divider()
                resultsArea
            }
            .navigationTitle("Filter by Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !selected.isEmpty {
                        Button("Clear") { selected.removeAll() }
                    }
                }
            }
            .sheet(item: $taggingPhoto) { target in
                PhotoTagEditorSheet(projectID: projectID, photoID: target.id)
                    .environment(store)
            }
        }
    }

    @ViewBuilder
    private var modeHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Match", selection: $matchMode) {
                ForEach(MatchMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(matchMode == .all
                 ? "Photos must match every selected tag."
                 : "Photos that match any of the selected tags.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var tagPickerArea: some View {
        if groups.isEmpty {
            ContentUnavailableView(
                "No tags above threshold",
                systemImage: "tag.slash",
                description: Text("Tag some photos, lower the confidence threshold in Settings, or run AI tagging to populate this list.")
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.primary) { group in
                        primarySection(group)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 320)
        }
    }

    @ViewBuilder
    private func primarySection(_ group: ProjectStore.TagGroup) -> some View {
        let crit = Criterion.primary(group.primary)
        let isSelected = selected.contains(crit)
        let isCollapsed = collapsedPrimaries.contains(group.primary.lowercased())
        let totalCount = group.primaryCount + group.secondaries.reduce(0) { $0 + $1.count }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    toggle(crit)
                } label: {
                    HStack(spacing: 6) {
                        Text(group.primary)
                            .font(.callout.weight(.semibold))
                        Text("\(totalCount)")
                            .font(.caption.monospaced())
                            .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.15),
                                in: Capsule())
                    .foregroundStyle(isSelected ? .white : Color.accentColor)
                }
                .buttonStyle(.plain)

                if !group.secondaries.isEmpty {
                    Button {
                        let key = group.primary.lowercased()
                        if isCollapsed { collapsedPrimaries.remove(key) }
                        else           { collapsedPrimaries.insert(key) }
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCollapsed ? "Expand secondaries" : "Collapse secondaries")
                }
                Spacer()
            }

            if !isCollapsed && !group.secondaries.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(group.secondaries, id: \.label) { sec in
                        let scrit = Criterion.secondary(parent: group.primary, label: sec.label)
                        let secSelected = selected.contains(scrit)
                        Button {
                            toggle(scrit)
                        } label: {
                            HStack(spacing: 4) {
                                Text(sec.label)
                                    .font(.caption)
                                Text("\(sec.count)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(secSelected ? .white.opacity(0.85) : .secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(secSelected ? Color.accentColor.opacity(0.85)
                                                    : Color.accentColor.opacity(0.10),
                                        in: Capsule())
                            .foregroundStyle(secSelected ? .white : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    private func toggle(_ criterion: Criterion) {
        if selected.contains(criterion) { selected.remove(criterion) }
        else                            { selected.insert(criterion) }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if selected.isEmpty {
            ContentUnavailableView(
                "Pick a tag to begin",
                systemImage: "tag",
                description: Text("Tap a primary category to filter every photo under it, or pick a specific secondary tag.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if matches.isEmpty {
            ContentUnavailableView(
                "No photos match",
                systemImage: "photo.on.rectangle.angled",
                description: Text("No photos in this project carry \(matchMode == .all ? "all" : "any") of these tags.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(matches.count) photo\(matches.count == 1 ? "" : "s") match")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                              spacing: 8) {
                        ForEach(matches) { photo in
                            PhotoTile(photo: photo, project: project!, store: store)
                                .onTapGesture {
                                    taggingPhoto = PhotoTarget(id: photo.id)
                                }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct PhotoTile: View {
    let photo: Photo
    let project: Project
    let store: ProjectStore
    @AppStorage("sitephoto.tagConfidenceThreshold")
    private var tagConfidenceThreshold: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                thumbnail
                    .aspectRatio(4/3, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .clipped()
                Text("#\(photo.sequenceNumber)")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
            // Bottom strip: up to two tag labels so you can see *why* the
            // photo matched without opening it. Secondaries render with a
            // tiny "Primary →" prefix so the hierarchy is legible.
            let visibleTags = photo.tags
                .filter { $0.confidence >= tagConfidenceThreshold }
                .prefix(2)
            if !visibleTags.isEmpty {
                Text(visibleTags.map(displayTag).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
            }
        }
    }

    private func displayTag(_ t: Tag) -> String {
        if let parent = t.parentTag, !parent.isEmpty {
            return "\(parent) › \(t.label)"
        }
        return t.label
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = store.thumbnailURL(for: photo, in: project),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
        }
    }
}
