import SwiftUI
import PencilKit
import UIKit

/// PencilKit-based markup editor for a single photo. The engineer draws
/// arrows / circles / call-outs on top of the photo; on save we render
/// the drawing into a transparent PNG at the photo's native resolution
/// (so PDF + folder export can composite it on the full-res image
/// without aliasing) and also persist the raw `PKDrawing` data so a
/// later edit session can resume from the existing strokes.
struct PhotoMarkupView: View {
    let projectID: UUID
    let photoID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var photoImage: UIImage?
    @State private var drawing: PKDrawing = PKDrawing()
    /// Size of the fitted photo + canvas inside the visible area. Updated
    /// from the GeometryReader so we know what scale factor to apply when
    /// rendering the overlay PNG.
    @State private var fittedSize: CGSize = .zero
    @State private var saving: Bool = false
    @State private var loaded: Bool = false
    @State private var confirmingClear: Bool = false

    private var project: Project? { store.project(withID: projectID) }
    private var photo: Photo? {
        project?.photos.first(where: { $0.id == photoID })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = photoImage {
                    GeometryReader { proxy in
                        let aspect = image.size.width / max(1, image.size.height)
                        let fit = Self.fitSize(in: proxy.size, aspect: aspect)
                        ZStack {
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: fit.width, height: fit.height)
                            PencilCanvasRepresentable(drawing: $drawing)
                                .frame(width: fit.width, height: fit.height)
                                .background(Color.clear)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .onAppear { fittedSize = fit }
                        .onChange(of: proxy.size) { _, _ in
                            fittedSize = Self.fitSize(in: proxy.size, aspect: aspect)
                        }
                    }
                    .ignoresSafeArea(.keyboard)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("Markup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(saving || photoImage == nil)
                        .bold()
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button(role: .destructive) {
                            confirmingClear = true
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .disabled(drawing.strokes.isEmpty
                                   && photo?.markupOverlayFilename == nil)
                        Spacer()
                    }
                }
            }
            .task(id: photoID) {
                guard !loaded else { return }
                await loadPhotoAndDrawing()
                loaded = true
            }
            .alert("Clear all markup on this photo?",
                   isPresented: $confirmingClear) {
                Button("Clear", role: .destructive) { clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every stroke and deletes the saved overlay. This cannot be undone.")
            }
        }
    }

    // MARK: - Loading

    private func loadPhotoAndDrawing() async {
        guard let project, let photo else { return }
        let imageURL = store.photosFolder(for: project).appending(path: photo.imageFilename)
        if let data = try? Data(contentsOf: imageURL),
           let img = UIImage(data: data) {
            photoImage = img
        }
        if let drawingURL = store.markupDrawingURL(for: photo, in: project),
           let data = try? Data(contentsOf: drawingURL),
           let existing = try? PKDrawing(data: data) {
            drawing = existing
        }
    }

    // MARK: - Save / clear

    private func save() {
        guard let project, let photoImage,
              fittedSize.width > 0,
              fittedSize.height > 0 else { return }
        saving = true
        defer { saving = false }

        if drawing.strokes.isEmpty {
            // Empty drawing → treat as a clear. Otherwise we'd leave the
            // old overlay on disk because we don't render an empty PNG.
            _ = store.clearMarkup(project, photoID: photoID)
            Haptics.confirm()
            toastCenter.post("Markup cleared", kind: .success)
            dismiss()
            return
        }

        // Render the drawing scaled up to the photo's native pixel size so
        // compositing onto the full-res image stays sharp.
        let scale = photoImage.size.width / fittedSize.width
        let renderRect = CGRect(origin: .zero, size: fittedSize)
        let overlayImage = drawing.image(from: renderRect, scale: scale)
        guard let pngData = overlayImage.pngData() else { return }
        let drawingData = drawing.dataRepresentation()
        _ = store.saveMarkup(project,
                              photoID: photoID,
                              pngData: pngData,
                              drawingData: drawingData)
        Haptics.success()
        toastCenter.post("Markup saved", kind: .success)
        dismiss()
    }

    private func clear() {
        drawing = PKDrawing()
        guard let project else { return }
        _ = store.clearMarkup(project, photoID: photoID)
    }

    // MARK: - Layout

    private static func fitSize(in container: CGSize, aspect: CGFloat) -> CGSize {
        guard container.width > 0, container.height > 0, aspect > 0 else {
            return container
        }
        let containerAspect = container.width / container.height
        if containerAspect > aspect {
            let h = container.height
            return CGSize(width: h * aspect, height: h)
        } else {
            let w = container.width
            return CGSize(width: w, height: w / aspect)
        }
    }
}

/// SwiftUI wrapper around `PKCanvasView`. The view binds the canvas's
/// `PKDrawing` to the parent state so saves and clears stay in sync.
/// The tool picker (pen / pencil / marker / eraser palette) is installed
/// asynchronously after the view attaches to its window — `becomeFirstResponder`
/// only succeeds once UIKit has handed us a non-nil `window`.
struct PencilCanvasRepresentable: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        context.coordinator.canvas = canvas
        // Tool picker has to wait for the canvas to acquire a window. A
        // single-shot async hop is enough on iOS 17.
        DispatchQueue.main.async {
            context.coordinator.attachToolPicker()
        }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing != drawing {
            uiView.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilCanvasRepresentable
        weak var canvas: PKCanvasView?
        // Strong reference so the tool picker doesn't deallocate after
        // makeUIView returns.
        let toolPicker = PKToolPicker()

        init(_ parent: PencilCanvasRepresentable) {
            self.parent = parent
        }

        func attachToolPicker() {
            guard let canvas else { return }
            toolPicker.setVisible(true, forFirstResponder: canvas)
            toolPicker.addObserver(canvas)
            canvas.becomeFirstResponder()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}
