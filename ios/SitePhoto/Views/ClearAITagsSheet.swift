import SwiftUI
import UIKit

/// Multi-select photo list for wiping out the AI-attributed tags + AI
/// metadata (severity, observation, follow-up, pending suggestions) from
/// chosen photos. Manually-typed tags (confidence 1.0) are preserved.
struct ClearAITagsSheet: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<UUID> = []
    @State private var confirming: Bool = false

    private var project: Project? { store.project(withID: projectID) }
    private var photos: [Photo] { project?.photos ?? [] }

    /// Photos that actually have something to clear — AI tags, metadata,
    /// pending suggestions, or a stored schema-2 analysis (which carries
    /// the caption draft, recommended use, etc., and the raw response).
    private func aiResidueCount(for photo: Photo) -> Int {
        let aiTags = photo.tags.filter { $0.confidence < 1.0 }.count
        let pending = photo.pendingSuggestions.count
        let metadata = [photo.aiSeverity, photo.aiObservation, photo.aiFollowUp]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .count
        let analysis = photo.aiAnalysis == nil ? 0 : 1
        return aiTags + pending + metadata + analysis
    }

    private var photosWithResidue: [Photo] {
        photos.filter { aiResidueCount(for: $0) > 0 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                infoBanner
                Divider()
                if photos.isEmpty {
                    ContentUnavailableView(
                        "No photos in this project",
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .frame(maxHeight: .infinity)
                } else if photosWithResidue.isEmpty {
                    ContentUnavailableView(
                        "Nothing to clear",
                        systemImage: "checkmark.seal",
                        description: Text("No photo in this project has AI tags, pending suggestions, or AI findings on it.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    photoList
                }
                Divider()
                bottomBar
            }
            .navigationTitle("Clear AI Tagging")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected {
                            selection.removeAll()
                        } else {
                            selection = Set(photosWithResidue.map { $0.id })
                        }
                    }
                    .disabled(photosWithResidue.isEmpty)
                }
            }
            .alert("Clear AI tagging from \(selection.count) photo\(selection.count == 1 ? "" : "s")?",
                   isPresented: $confirming) {
                Button("Clear", role: .destructive) {
                    runClear()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes AI-attributed tags, pending suggestions, severity, summary observation, and follow-up notes from the selected photos. Manually-typed tags are preserved. This cannot be undone.")
            }
        }
    }

    private var allSelected: Bool {
        !photosWithResidue.isEmpty &&
            selection.count == photosWithResidue.count
    }

    @ViewBuilder
    private var infoBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Removes AI tags + findings from selected photos.")
                .font(.callout)
            Text("Manually-typed tags (confidence 100%) are preserved. AI tags from older versions of the app may also be preserved if their confidence reads as 100% — those would need to be removed manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private var photoList: some View {
        List(selection: $selection) {
            ForEach(photosWithResidue) { photo in
                ClearAITagsRow(photo: photo,
                                 project: project!,
                                 store: store,
                                 residueCount: aiResidueCount(for: photo))
                    .tag(photo.id)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
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
                Label("Clear AI Tagging", systemImage: "eraser")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var selectionSummary: String {
        if selection.isEmpty {
            return "Select photos to clear."
        }
        return "\(selection.count) of \(photosWithResidue.count) selected"
    }

    private func runClear() {
        guard let project else { return }
        _ = store.clearAIInfo(project, photoIDs: selection)
        // Drop selection so the empty-state view appears once everything
        // selected has been wiped.
        selection.removeAll()
    }
}

private struct ClearAITagsRow: View {
    let photo: Photo
    let project: Project
    let store: ProjectStore
    let residueCount: Int

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 56, height: 42)
                .clipped()
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(photo.sequenceNumber)")
                    .font(.subheadline.monospaced())
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var detailLine: String {
        var parts: [String] = []
        let aiTagCount = photo.tags.filter { $0.confidence < 1.0 }.count
        if aiTagCount > 0 {
            parts.append("\(aiTagCount) AI tag\(aiTagCount == 1 ? "" : "s")")
        }
        if !photo.pendingSuggestions.isEmpty {
            parts.append("\(photo.pendingSuggestions.count) pending")
        }
        if let sev = photo.aiSeverity, !sev.isEmpty {
            parts.append("Severity: \(sev)")
        }
        if photo.aiObservation?.isEmpty == false {
            parts.append("has summary")
        }
        if photo.aiAnalysis != nil {
            parts.append("AI analysis")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
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
        }
    }
}
