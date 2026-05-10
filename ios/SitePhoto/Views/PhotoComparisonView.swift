import SwiftUI
import UIKit

/// Side-by-side (well — swipeable carousel) view of a reshoot lineage:
/// the original photo and every reshoot made of it, in capture order
/// (oldest → newest). Used when the engineer revisits a site and wants
/// to compare the same wall / crack / feature across visits.
///
/// Opens from any photo participating in the chain. The view walks the
/// chain via `ProjectStore.reshootChain(for:in:)`, so jumping in from
/// either the original or a reshoot lands on the same lineup.
struct PhotoComparisonView: View {
    let projectID: UUID
    let anchorPhotoID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIndex: Int = 0
    @State private var loadedImages: [UUID: UIImage] = [:]

    private var project: Project? { store.project(withID: projectID) }
    private var anchor: Photo? {
        project?.photos.first(where: { $0.id == anchorPhotoID })
    }
    private var chain: [Photo] {
        guard let project, let anchor else { return [] }
        return store.reshootChain(for: anchor, in: project)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if chain.isEmpty {
                    EmptyStateView(
                        icon: "rectangle.on.rectangle",
                        title: "No reshoots yet",
                        message: "Tap \"Reshoot This Photo\" from a photo's menu to capture a follow-up at the same location."
                    )
                } else {
                    carousel
                    captionPanel
                }
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let idx = chain.firstIndex(where: { $0.id == anchorPhotoID }) {
                    selectedIndex = idx
                }
                preloadImages()
            }
        }
    }

    // MARK: - Carousel

    @ViewBuilder
    private var carousel: some View {
        TabView(selection: $selectedIndex) {
            ForEach(Array(chain.enumerated()), id: \.element.id) { idx, photo in
                ZStack {
                    Color.black
                    if let image = loadedImages[photo.id] {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().tint(.white)
                    }
                    VStack {
                        HStack {
                            badge(text: chainLabel(for: photo, index: idx))
                                .padding(8)
                            Spacer()
                        }
                        Spacer()
                    }
                }
                .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Caption panel

    @ViewBuilder
    private var captionPanel: some View {
        let photo = chain[safe: selectedIndex]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    selectedIndex = max(0, selectedIndex - 1)
                } label: {
                    Image(systemName: "chevron.left.circle.fill").font(.title2)
                }
                .disabled(selectedIndex == 0)
                Spacer()
                Text(positionLabel)
                    .font(.subheadline.monospaced())
                Spacer()
                Button {
                    selectedIndex = min(chain.count - 1, selectedIndex + 1)
                } label: {
                    Image(systemName: "chevron.right.circle.fill").font(.title2)
                }
                .disabled(selectedIndex >= chain.count - 1)
            }
            if let photo {
                HStack(spacing: 8) {
                    Text("#\(photo.sequenceNumber)")
                        .font(.headline.monospaced())
                    Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if let caption = photo.effectiveCaption {
                    Text(caption)
                        .font(.callout)
                        .lineLimit(3)
                }
                if let observation = photo.effectiveObservation {
                    Text(observation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func badge(text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.65), in: Capsule())
            .foregroundStyle(.white)
    }

    private var positionLabel: String {
        guard !chain.isEmpty else { return "" }
        return "\(selectedIndex + 1) of \(chain.count)"
    }

    /// Tag the original as "Original" and reshoots by ordinal so the
    /// engineer can tell at a glance which capture they're looking at
    /// without comparing dates.
    private func chainLabel(for photo: Photo, index: Int) -> String {
        if index == 0 { return "Original" }
        return "Reshoot \(index)"
    }

    private func preloadImages() {
        guard let project else { return }
        for photo in chain where loadedImages[photo.id] == nil {
            let url = store.photosFolder(for: project).appending(path: photo.imageFilename)
            Task {
                await store.ensureDownloaded(url)
                guard let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data) else { return }
                await MainActor.run {
                    loadedImages[photo.id] = image
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
