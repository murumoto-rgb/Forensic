import PhotosUI
import SwiftUI

struct FloorPlanReplaceView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var pointA: CGPoint?
    @State private var pointB: CGPoint?
    @State private var distanceFeetText = ""
    @State private var origin: CGPoint?
    @State private var saving = false
    @State private var error: String?

    private enum Step { case pickImage, calibrate, distance, origin }

    private var step: Step {
        if image == nil { return .pickImage }
        if pointA == nil || pointB == nil { return .calibrate }
        if Double(distanceFeetText).map({ $0 <= 0 }) ?? true { return .distance }
        return .origin
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let img = image {
                    instructionBar
                    ReplaceCanvas(
                        image: img,
                        pointA: $pointA,
                        pointB: $pointB,
                        origin: $origin,
                        canSetOrigin: step == .origin
                    )
                    .background(.black)
                    .frame(maxHeight: .infinity)

                    if step == .distance || step == .origin {
                        distancePanel
                    }
                } else {
                    initialPicker
                }
            }
            .navigationTitle("Replace Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                if image != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            save()
                        } label: {
                            if saving {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Save")
                            }
                        }
                        .disabled(!canSave || saving)
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
            Text(stepText)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            Text(stepLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var stepText: String {
        switch step {
        case .pickImage: return "Choose the new plan image."
        case .calibrate:
            if pointA == nil { return "Tap calibration Point A on the new plan." }
            return "Tap Point B (a known distance from A)."
        case .distance: return "Enter the real distance between A and B in feet."
        case .origin:   return "Tap the origin (0, 0). Existing photos will land at the same physical spot."
        }
    }

    private var stepLabel: String {
        switch step {
        case .pickImage: return "1 / 4"
        case .calibrate: return "2 / 4"
        case .distance:  return "3 / 4"
        case .origin:    return "4 / 4"
        }
    }

    private var initialPicker: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
            Text("Replace floor plan")
                .font(.title3.bold())
            Text("Pick the new plan, calibrate it (tap A & B + feet), then tap the origin. Photos move to the matching physical positions on the new plan.")
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

    private var distancePanel: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("Distance (feet)", text: $distanceFeetText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                if let _ = origin {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Origin set").font(.caption.bold())
                }
            }
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var canSave: Bool {
        guard let _ = pointA, let _ = pointB else { return false }
        guard let d = Double(distanceFeetText), d > 0 else { return false }
        guard origin != nil else { return false }
        return imageData != nil
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
            imageData = img.jpegData(compressionQuality: 0.9) ?? data
            error = nil
        } catch {
            self.error = "Could not load image: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let project = store.project(withID: projectID) else { return }
        guard let data = imageData,
              let a = pointA, let b = pointB,
              let d = Double(distanceFeetText), d > 0,
              let o = origin else { return }
        let pixelDist = hypot(b.x - a.x, b.y - a.y)
        guard pixelDist > 0 else {
            error = "Points A and B must be distinct."
            return
        }
        let pxPerFoot = pixelDist / d

        saving = true
        do {
            try store.replaceFloorPlan(
                in: project,
                imageData: data,
                pixelsPerFoot: pxPerFoot,
                calibrationDistanceFeet: d,
                anchorPixelX: Double(o.x),
                anchorPixelY: Double(o.y),
                northDeg: project.floorPlan?.northDeg ?? 0
            )
            dismiss()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
            saving = false
        }
    }
}

private struct ReplaceCanvas: View {
    let image: UIImage
    @Binding var pointA: CGPoint?
    @Binding var pointB: CGPoint?
    @Binding var origin: CGPoint?
    let canSetOrigin: Bool

    @State private var dragLocation: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let imgSize = image.size
            let scale = min(geo.size.width / max(1, imgSize.width),
                            geo.size.height / max(1, imgSize.height))
            let dispW = imgSize.width * scale
            let dispH = imgSize.height * scale
            let originX = (geo.size.width - dispW) / 2
            let originY = (geo.size.height - dispH) / 2

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: dispW, height: dispH)
                    .offset(x: originX, y: originY)

                if let a = pointA, let b = pointB {
                    Path { p in
                        p.move(to: CGPoint(x: originX + a.x * scale, y: originY + a.y * scale))
                        p.addLine(to: CGPoint(x: originX + b.x * scale, y: originY + b.y * scale))
                    }
                    .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }

                if let a = pointA {
                    pointMarker(text: "A", color: .orange,
                                at: CGPoint(x: originX + a.x * scale, y: originY + a.y * scale))
                }
                if let b = pointB {
                    pointMarker(text: "B", color: .blue,
                                at: CGPoint(x: originX + b.x * scale, y: originY + b.y * scale))
                }
                if let o = origin {
                    originMarker(at: CGPoint(x: originX + o.x * scale, y: originY + o.y * scale))
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
                    .onChanged { value in dragLocation = value.location }
                    .onEnded { value in
                        defer { dragLocation = nil }
                        let inImage = CGPoint(
                            x: (value.location.x - originX) / scale,
                            y: (value.location.y - originY) / scale
                        )
                        guard inImage.x >= 0, inImage.x <= imgSize.width,
                              inImage.y >= 0, inImage.y <= imgSize.height else { return }
                        if canSetOrigin {
                            origin = inImage
                        } else if pointA == nil {
                            pointA = inImage
                        } else if pointB == nil {
                            pointB = inImage
                        } else {
                            pointA = inImage
                            pointB = nil
                        }
                    }
            )
        }
    }

    @ViewBuilder
    private func pointMarker(text: String, color: Color, at point: CGPoint) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 22, height: 22)
            Circle().stroke(.white, lineWidth: 2).frame(width: 22, height: 22)
            Text(text).font(.caption2.bold()).foregroundStyle(.white)
        }
        .position(point)
    }

    @ViewBuilder
    private func originMarker(at point: CGPoint) -> some View {
        ZStack {
            Circle().stroke(Color.green, lineWidth: 3).frame(width: 28, height: 28)
            Path { p in
                p.move(to: CGPoint(x: -16, y: 0)); p.addLine(to: CGPoint(x: 16, y: 0))
                p.move(to: CGPoint(x: 0, y: -16)); p.addLine(to: CGPoint(x: 0, y: 16))
            }
            .stroke(Color.green, lineWidth: 2)
            .frame(width: 32, height: 32)
        }
        .position(point)
    }
}
