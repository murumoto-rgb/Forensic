import SwiftUI
import UIKit

/// Wide spreadsheet-style view of every photo in the project — thumbnail,
/// sequence number, capture time, location inference, bucket, tags,
/// observation snippet, and favorite. Sortable by tapping any column
/// header. Useful when triaging a project with 100+ photos before the
/// report write-up, since the standard photo list optimises for editing
/// one photo at a time.
///
/// Reuses the same filter state the Photos section already exposes —
/// tag filters, bucket filters, recommended-use filters, needs-review,
/// favorites, and the search field — so toggling between list and
/// spreadsheet views keeps the active filter set.
struct PhotoSheetView: View {
    let projectID: UUID
    let photos: [Photo]

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var sortColumn: SortColumn = .sequence
    @State private var sortAscending: Bool = true
    @State private var openingTag: Photo?

    enum SortColumn: String, CaseIterable, Identifiable {
        case sequence, captured, location, bucket, tags, observation, favorite
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sequence: return "#"
            case .captured: return "Captured"
            case .location: return "Location"
            case .bucket: return "Bucket"
            case .tags: return "Tags"
            case .observation: return "Observation"
            case .favorite: return "★"
            }
        }
        var width: CGFloat {
            switch self {
            case .sequence: return 44
            case .captured: return 130
            case .location: return 140
            case .bucket: return 130
            case .tags: return 200
            case .observation: return 240
            case .favorite: return 36
            }
        }
    }

    private var project: Project? { store.project(withID: projectID) }
    private var sorted: [Photo] {
        let base = photos
        let ordered = base.sorted { lhs, rhs in
            switch sortColumn {
            case .sequence:
                return lhs.sequenceNumber < rhs.sequenceNumber
            case .captured:
                return lhs.timestamp < rhs.timestamp
            case .location:
                return locationText(lhs).localizedCaseInsensitiveCompare(locationText(rhs)) == .orderedAscending
            case .bucket:
                return bucketLabel(lhs).localizedCaseInsensitiveCompare(bucketLabel(rhs)) == .orderedAscending
            case .tags:
                return tagsLine(lhs).localizedCaseInsensitiveCompare(tagsLine(rhs)) == .orderedAscending
            case .observation:
                return (lhs.effectiveObservation ?? "")
                    .localizedCaseInsensitiveCompare(rhs.effectiveObservation ?? "")
                    == .orderedAscending
            case .favorite:
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite && !rhs.isFavorite }
                return lhs.sequenceNumber < rhs.sequenceNumber
            }
        }
        return sortAscending ? ordered : Array(ordered.reversed())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if photos.isEmpty {
                    EmptyStateView(
                        icon: "tablecells",
                        title: "No photos match",
                        message: "Adjust the filter chips in the Photos list and reopen the Photo Sheet."
                    )
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            headerRow
                            Divider()
                            ForEach(sorted) { photo in
                                photoRow(photo)
                                Divider()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Photo Sheet · \(photos.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $openingTag) { photo in
                PhotoTagEditorSheet(projectID: projectID, photoID: photo.id)
                    .environment(store)
            }
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Thumbnail column — fixed, no sort.
            Text("Photo")
                .font(.caption.bold())
                .frame(width: 64, height: 34, alignment: .leading)
                .padding(.horizontal, 8)
            ForEach(SortColumn.allCases) { col in
                Button {
                    if sortColumn == col {
                        sortAscending.toggle()
                    } else {
                        sortColumn = col
                        sortAscending = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(col.label)
                            .font(.caption.bold())
                        if sortColumn == col {
                            Image(systemName: sortAscending
                                  ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .frame(width: col.width, height: 34, alignment: .leading)
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private func photoRow(_ photo: Photo) -> some View {
        Button {
            openingTag = photo
        } label: {
            HStack(spacing: 0) {
                thumbnail(for: photo)
                    .frame(width: 64, height: 48)
                    .clipped()
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, 8)
                cell(text: "#\(photo.sequenceNumber)",
                      width: SortColumn.sequence.width,
                      bold: true)
                cell(text: photo.timestamp.formatted(date: .abbreviated, time: .shortened),
                      width: SortColumn.captured.width)
                cell(text: locationText(photo),
                      width: SortColumn.location.width)
                bucketCell(photo: photo, width: SortColumn.bucket.width)
                cell(text: tagsLine(photo),
                      width: SortColumn.tags.width)
                cell(text: photo.effectiveObservation ?? "",
                      width: SortColumn.observation.width,
                      italic: photo.userObservation == nil)
                HStack {
                    if photo.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                .frame(width: SortColumn.favorite.width, height: 56)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cell(text: String, width: CGFloat, bold: Bool = false, italic: Bool = false) -> some View {
        let font: Font = {
            if bold { return .callout.bold() }
            if italic { return .callout.italic() }
            return .callout
        }()
        Text(text.isEmpty ? "—" : text)
            .font(font)
            .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
            .lineLimit(2)
            .frame(width: width, height: 56, alignment: .leading)
            .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func bucketCell(photo: Photo, width: CGFloat) -> some View {
        if let bucket = bucketFor(photo) {
            HStack(spacing: 4) {
                Circle().fill(bucket.color).frame(width: 8, height: 8)
                Text(bucket.name)
                    .font(.callout)
                    .lineLimit(1)
            }
            .frame(width: width, height: 56, alignment: .leading)
            .padding(.horizontal, 6)
        } else {
            cell(text: "", width: width)
        }
    }

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
        }
    }

    // MARK: - Helpers

    private func locationText(_ photo: Photo) -> String {
        photo.aiAnalysis?.locationInferred ?? ""
    }

    private func tagsLine(_ photo: Photo) -> String {
        let threshold = UserDefaults.standard.double(forKey: "sitephoto.tagConfidenceThreshold")
        let active = photo.tags.filter { $0.confidence >= threshold }
        return active
            .map { tag in
                if let parent = tag.parentTag {
                    return "\(parent) / \(tag.label)"
                }
                return tag.label
            }
            .joined(separator: " · ")
    }

    private func bucketFor(_ photo: Photo) -> Bucket? {
        guard let id = photo.bucketID,
              let bucket = project?.buckets.first(where: { $0.id == id }) else {
            return nil
        }
        return bucket
    }

    private func bucketLabel(_ photo: Photo) -> String {
        bucketFor(photo)?.name ?? ""
    }
}
