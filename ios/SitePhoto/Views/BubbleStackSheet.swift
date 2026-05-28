import SwiftUI
import UIKit

/// Modal sheet shown when the engineer taps a stack-badge bubble on the
/// floor plan — replaces the previous cluster-fanning rosette which moved
/// bubbles away from their placed positions. Lists every photo whose
/// `planPixelX/Y` falls inside the same overlap cluster, with thumbnails
/// + sequence numbers + caption previews. Tapping a row dismisses the
/// sheet and hands the photo ID off to the caller via `onSelect` so the
/// viewer can open its photo editor (or the group picker can record a
/// pick) without this sheet needing to know which surface invoked it.
struct BubbleStackSheet: View {
    let projectID: UUID
    let photoIDs: [UUID]
    /// Verb shown next to each row (e.g. "Edit", "Pick"). Lets the
    /// viewer and the picker share the same sheet without one knowing
    /// about the other's vocabulary.
    let actionLabel: String
    /// Invoked with the chosen photo ID after the sheet dismisses. The
    /// caller is responsible for opening whatever surface they want
    /// (editor, picker confirmation, etc).
    let onSelect: (UUID) -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var project: Project? { store.project(withID: projectID) }

    /// Resolve the photo IDs against the current project, in
    /// sequence-number order so the stack reads top-to-bottom in the
    /// same order the engineer would expect on the photo list.
    private var photos: [Photo] {
        guard let project else { return [] }
        let byID: [UUID: Photo] = Dictionary(uniqueKeysWithValues:
            project.photos.map { ($0.id, $0) }
        )
        return photoIDs
            .compactMap { byID[$0] }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(photos, id: \.id) { photo in
                        Button {
                            let id = photo.id
                            dismiss()
                            // Defer onSelect so the dismiss animation
                            // starts first — otherwise the caller's
                            // sheet opens behind the still-visible
                            // stack sheet on iPad.
                            DispatchQueue.main.async { onSelect(id) }
                        } label: {
                            row(photo)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("These photos all share the same spot on this plan. Tap to \(actionLabel.lowercased()). To split them apart, open one and use Locate to give it a new position.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("\(photos.count) photos at this spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ photo: Photo) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: photo)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(photo.sequenceNumber)")
                    .font(.headline)
                if let caption = captionPreview(for: photo) {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(timestampString(for: photo))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(actionLabel)
                .font(.callout)
                .foregroundStyle(.tint)
        }
        .contentShape(Rectangle())
    }

    /// Reuses the same thumbnail-URL + UIImage(data:) pattern other
    /// list views in the app rely on (`TagFilterView`, `BatchTagSummary`,
    /// `PhotoGroupPickerSheet`). Synchronous `Data(contentsOf:)` is fine
    /// here — the stack sheets are short lists (typically < 10 photos).
    @ViewBuilder
    private func thumbnail(for photo: Photo) -> some View {
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
                .background(Color(.secondarySystemBackground))
        }
    }

    private func captionPreview(for photo: Photo) -> String? {
        if let user = photo.userCaption?.trimmingCharacters(in: .whitespacesAndNewlines),
           !user.isEmpty {
            return user
        }
        let ai = photo.aiAnalysis?.captionDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (ai?.isEmpty ?? true) ? nil : ai
    }

    private func timestampString(for photo: Photo) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: photo.timestamp)
    }
}
