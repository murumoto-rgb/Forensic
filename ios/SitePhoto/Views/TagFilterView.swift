import SwiftUI
import UIKit

/// Tag-driven photo browser. Pick one or more tags, choose AND or OR
/// semantics, see every photo in the project that matches. Tap a
/// thumbnail to open its tag editor (and from there, edit/relocate/etc).
struct TagFilterView: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sitephoto.tagConfidenceThreshold")
    private var tagConfidenceThreshold: Double = 0.5

    @State private var selectedTags: Set<String> = []   // lowercase keys
    @State private var matchMode: MatchMode = .all      // AND default
    @State private var taggingPhoto: PhotoTarget?

    enum MatchMode: String, CaseIterable, Identifiable {
        case all   // AND — photo must have every selected tag
        case any   // OR  — photo must have at least one
        var id: String { rawValue }
        var label: String { self == .all ? "All (AND)" : "Any (OR)" }
    }

    private struct PhotoTarget: Identifiable {
        let id: UUID
    }

    private var project: Project? { store.project(withID: projectID) }

    /// Tags surfaced in the chip bar — only those that actually meet the
    /// confidence threshold on at least one photo, sorted by frequency.
    private var availableTags: [String] {
        guard let project else { return [] }
        return store.tagsUsed(in: project, minConfidence: tagConfidenceThreshold)
    }

    /// Set of selected tags lowercased — used to test photo membership.
    private var selectedLC: Set<String> {
        Set(selectedTags.map { $0.lowercased() })
    }

    /// Filtered photo list based on the current tag selection + mode.
    private var matches: [Photo] {
        guard let project else { return [] }
        guard !selectedTags.isEmpty else { return [] }
        let sel = selectedLC
        return project.photos.filter { photo in
            let photoLC = Set(photo.tags
                .filter { $0.confidence >= tagConfidenceThreshold }
                .map { $0.label.lowercased() })
            switch matchMode {
            case .all: return sel.isSubset(of: photoLC)
            case .any: return !sel.isDisjoint(with: photoLC)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modeHeader
                Divider()
                tagChipBar
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
                    if !selectedTags.isEmpty {
                        Button("Clear") { selectedTags.removeAll() }
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
                 ? "Photos must carry every selected tag."
                 : "Photos with any of the selected tags.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var tagChipBar: some View {
        if availableTags.isEmpty {
            ContentUnavailableView(
                "No tags above threshold",
                systemImage: "tag.slash",
                description: Text("Tag some photos, lower the confidence threshold in Settings, or run AI tagging to populate this list.")
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                FlowLayout(spacing: 6) {
                    ForEach(availableTags, id: \.self) { tag in
                        let on = selectedTags.contains(tag)
                        Button {
                            if on { selectedTags.remove(tag) }
                            else  { selectedTags.insert(tag) }
                        } label: {
                            Text(tag)
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(on ? Color.accentColor : Color.accentColor.opacity(0.15),
                                            in: Capsule())
                                .foregroundStyle(on ? .white : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 220)
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if selectedTags.isEmpty {
            ContentUnavailableView(
                "Pick a tag to begin",
                systemImage: "tag",
                description: Text("Select one or more tags above to see matching photos.")
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
            // photo matched without opening it.
            let visibleTags = photo.tags
                .filter { $0.confidence >= tagConfidenceThreshold }
                .prefix(2)
            if !visibleTags.isEmpty {
                Text(visibleTags.map { $0.label }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .lineLimit(1)
            }
        }
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
