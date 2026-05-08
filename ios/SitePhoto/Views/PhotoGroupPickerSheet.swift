import SwiftUI

/// Lists every located photo in the project as a tap-to-pick row, used by the
/// Locate / Change-Location flow's "Group with another photo" option.
struct PhotoGroupPickerSheet: View {
    let projectID: UUID
    /// Photo IDs to omit from the list — typically the photo currently being
    /// (re)located, plus any pending captures that haven't been saved yet.
    let excludingPhotoIDs: Set<UUID>
    let onSelect: (UUID) -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if eligible.isEmpty {
                    ContentUnavailableView(
                        "No located photos yet",
                        systemImage: "mappin.slash",
                        description: Text("Locate at least one photo on the plan first, then you can stack new photos onto it.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(eligible) { photo in
                                Button {
                                    onSelect(photo.id)
                                    dismiss()
                                } label: {
                                    row(for: photo)
                                }
                                .buttonStyle(.plain)
                            }
                        } footer: {
                            Text("The new photo will share this photo's location and join its group as a stacked tail bubble.")
                        }
                    }
                }
            }
            .navigationTitle("Group With…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var eligible: [Photo] {
        guard let project = store.project(withID: projectID) else { return [] }
        return project.photos
            .filter { $0.positionSource != .none && !excludingPhotoIDs.contains($0.id) }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    @ViewBuilder
    private func row(for photo: Photo) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: photo)
                .frame(width: 64, height: 48)
                .clipped()
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(photo.sequenceNumber)")
                        .font(.headline.monospaced())
                    if photo.groupID != nil {
                        Text(photo.isPrimary ? "GROUP★" : "GROUP")
                            .font(.caption2.bold().monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.blue)
                    }
                }
                if let lx = photo.localXFeet, let ly = photo.localYFeet {
                    Text(String(format: "X %.1f ft · Y %.1f ft", lx, ly))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func thumbnail(for photo: Photo) -> some View {
        if let project = store.project(withID: projectID),
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
}
