import PhotosUI
import SwiftUI

struct FloorPlanSetupView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var pointA: CGPoint?
    @State private var pointB: CGPoint?
    @State private var distanceFeetText = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let image {
                    instructionBar
                    CalibrationCanvas(
                        image: image,
                        pointA: $pointA,
                        pointB: $pointB
                    )
                    .background(.black)
                    .frame(maxHeight: .infinity)
                    if pointA != nil && pointB != nil {
                        distanceEntry
                    }
                } else {
                    initialPicker
                }
            }
            .navigationTitle("Floor Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                if image != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                resetForReplace()
                            } label: { Label("Replace Image", systemImage: "photo") }

                            Button {
                                pointA = nil
                                pointB = nil
                                distanceFeetText = ""
                            } label: { Label("Reset Points", systemImage: "arrow.counterclockwise") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .onChange(of: pickerItem) { _, newItem in
                guard newItem != nil else { return }
                Task { await loadImage(newItem) }
            }
        }
    }

    private var instructionBar: some View {
        HStack {
            Text(instruction)
                .font(.callout)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding()
        .background(.ultraThinMaterial)
    }

    private var instruction: String {
        if pointA == nil { return "Tap calibration Point A on the plan." }
        if pointB == nil { return "Tap Point B (a known distance from A)." }
        return "Enter the real distance between A and B in feet."
    }

    private var initialPicker: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
            Text("Import a floor plan")
                .font(.title3.bold())
            Text("Pick an image of the floor plan. You'll calibrate it by tapping two points and entering the real distance between them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("Choose Image", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
            Spacer()
            if let err = error {
                Text(err).foregroundStyle(.red).font(.caption).padding(.bottom)
            }
        }
        .padding()
    }

    private var distanceEntry: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Distance (feet)", text: $distanceFeetText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button {
                    save()
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || saving)
            }
            if let err = error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var canSave: Bool {
        guard pointA != nil, pointB != nil else { return false }
        guard let d = Double(distanceFeetText), d > 0 else { return false }
        return imageData != nil
    }

    private func resetForReplace() {
        pickerItem = nil
        image = nil
        imageData = nil
        pointA = nil
        pointB = nil
        distanceFeetText = ""
        error = nil
    }

    private func loadImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else {
                error = "Could not load that image."
                return
            }
            image = img
            // Re-encode as JPEG so we control format and size on disk.
            if let jpeg = img.jpegData(compressionQuality: 0.9) {
                imageData = jpeg
            } else {
                imageData = data
            }
            error = nil
        } catch {
            self.error = "Could not load image: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let project = store.project(withID: projectID) else { return }
        guard let imageData,
              let a = pointA, let b = pointB,
              let d = Double(distanceFeetText), d > 0 else { return }
        let dx = b.x - a.x
        let dy = b.y - a.y
        let pixelDist = sqrt(dx * dx + dy * dy)
        guard pixelDist > 0 else {
            error = "Points A and B must be distinct."
            return
        }
        let pixelsPerFoot = pixelDist / d

        saving = true
        do {
            try store.saveFloorPlan(
                to: project,
                imageData: imageData,
                anchorPixelX: Double(a.x),
                anchorPixelY: Double(a.y),
                pixelsPerFoot: pixelsPerFoot,
                calibrationDistanceFeet: d,
                northDeg: 180
            )
            dismiss()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
            saving = false
        }
    }
}

private struct CalibrationCanvas: View {
    let image: UIImage
    @Binding var pointA: CGPoint?
    @Binding var pointB: CGPoint?

    @State private var dragLocation: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let imageSize = image.size
            let scale = min(geo.size.width / max(1, imageSize.width),
                            geo.size.height / max(1, imageSize.height))
            let displayedW = imageSize.width * scale
            let displayedH = imageSize.height * scale
            let originX = (geo.size.width - displayedW) / 2
            let originY = (geo.size.height - displayedH) / 2

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: displayedW, height: displayedH)
                    .offset(x: originX, y: originY)

                if let a = pointA, let b = pointB {
                    Path { path in
                        path.move(to: CGPoint(x: originX + a.x * scale, y: originY + a.y * scale))
                        path.addLine(to: CGPoint(x: originX + b.x * scale, y: originY + b.y * scale))
                    }
                    .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }

                if let a = pointA {
                    marker(text: "A", color: .orange,
                           x: originX + a.x * scale, y: originY + a.y * scale)
                }
                if let b = pointB {
                    marker(text: "B", color: .blue,
                           x: originX + b.x * scale, y: originY + b.y * scale)
                }

                if let drag = dragLocation {
                    LoupeOverlay(
                        image: image,
                        finger: drag,
                        imageOriginX: originX,
                        imageOriginY: originY,
                        fitScale: scale,
                        canvasSize: geo.size
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        dragLocation = value.location
                    }
                    .onEnded { value in
                        defer { dragLocation = nil }
                        let inImage = CGPoint(
                            x: (value.location.x - originX) / scale,
                            y: (value.location.y - originY) / scale
                        )
                        guard inImage.x >= 0, inImage.x <= imageSize.width,
                              inImage.y >= 0, inImage.y <= imageSize.height else { return }
                        if pointA == nil {
                            pointA = inImage
                        } else if pointB == nil {
                            pointB = inImage
                        } else {
                            // Both already set — start over with new A.
                            pointA = inImage
                            pointB = nil
                        }
                    }
            )
        }
    }

    @ViewBuilder
    private func marker(text: String, color: Color, x: CGFloat, y: CGFloat) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 22, height: 22)
            Circle().stroke(.white, lineWidth: 2).frame(width: 22, height: 22)
            Text(text)
                .font(.caption2.bold())
                .foregroundStyle(.white)
        }
        .position(x: x, y: y)
    }
}
