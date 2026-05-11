import SwiftUI
import PDFKit

/// Grid of page thumbnails for a multi-page PDF. Shown after the
/// engineer picks a multi-page PDF as a floor-plan source so they can
/// choose which page to use rather than always defaulting to page 1.
/// Single-page PDFs skip this sheet — `FloorPlanPDFImport.pageCount`
/// gates the presentation in the parent view.
///
/// The sheet returns the chosen 0-based page index via `onPick`. The
/// parent then runs `FloorPlanPDFImport.renderPage(at:from:)` to
/// rasterise just that page (avoids the cost of rendering every page
/// up front).
struct PDFPagePickerSheet: View {
    let url: URL
    let pageCount: Int
    let onPick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var thumbnails: [Int: UIImage] = [:]
    @State private var loadTask: Task<Void, Never>?

    /// Three-column grid feels right on iPhone Pro Max widths and
    /// stays usable on a Mini. SF Symbols would be more compact but
    /// thumbnails are far more useful for picking architectural pages.
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(0..<pageCount, id: \.self) { idx in
                        pageTile(idx)
                    }
                }
                .padding()
            }
            .navigationTitle("Pick a page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        loadTask?.cancel()
                        dismiss()
                    }
                }
            }
            .task {
                await loadThumbnails()
            }
            .onDisappear {
                loadTask?.cancel()
            }
        }
    }

    @ViewBuilder
    private func pageTile(_ index: Int) -> some View {
        Button {
            loadTask?.cancel()
            onPick(index)
            dismiss()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Color.secondary.opacity(0.15)
                    if let img = thumbnails[index] {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(4)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
                Text("Page \(index + 1)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Render thumbnails serially off the main actor so the UI stays
    /// snappy on a 50-page PDF. Cancellable via `loadTask` so picking
    /// a page mid-load doesn't waste cycles on the rest.
    private func loadThumbnails() async {
        loadTask?.cancel()
        let task = Task.detached(priority: .userInitiated) { [url, pageCount] in
            for idx in 0..<pageCount {
                if Task.isCancelled { return }
                let thumb = FloorPlanPDFImport.pageThumbnail(at: idx, from: url)
                await MainActor.run {
                    thumbnails[idx] = thumb
                }
            }
        }
        loadTask = task
        await task.value
    }
}
