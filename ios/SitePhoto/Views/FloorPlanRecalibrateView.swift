import SwiftUI

/// Re-calibrate the floor plan's scale (pixels-per-foot) without replacing the image.
/// Photos stay at their existing pixel positions on the plan; their feet readouts
/// re-derive against the new scale.
struct FloorPlanRecalibrateView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pointA: CGPoint?
    @State private var pointB: CGPoint?
    @State private var distanceFeetText = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let img = planImage {
                    instructionBar
                    RecalibrateCanvas(
                        image: img,
                        pointA: $pointA,
                        pointB: $pointB
                    )
                    .background(.black)
                    .frame(maxHeight: .infinity)
                    distancePanel
                } else {
                    ContentUnavailableView(
                        "Plan unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Set up the floor plan first.")
                    )
                }
            }
            .navigationTitle("Re-calibrate Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            pointA = nil
                            pointB = nil
                            distanceFeetText = ""
                        } label: {
                            Label("Reset Points", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var planImage: UIImage? {
        guard let proj = store.project(withID: projectID),
              let url = store.floorPlanURL(for: proj),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private var instructionBar: some View {
        HStack {
            Text(instruction)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var instruction: String {
        if pointA == nil { return "Tap calibration Point A on the plan." }
        if pointB == nil { return "Tap Point B (a known distance from A)." }
        return "Enter the real distance between A and B in feet."
    }

    private var distancePanel: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Distance (feet)", text: $distanceFeetText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button {
                    save()
                } label: {
                    if saving { ProgressView().controlSize(.small) }
                    else { Text("Save") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || saving)
            }
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Text("Photo positions on the plan stay where they are. The X / Y readouts in feet update against the new scale.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var canSave: Bool {
        guard pointA != nil, pointB != nil else { return false }
        guard let d = Double(distanceFeetText), d > 0 else { return false }
        return true
    }

    private func save() {
        guard let project = store.project(withID: projectID),
              let a = pointA, let b = pointB,
              let d = Double(distanceFeetText), d > 0 else { return }
        let pixelDist = hypot(b.x - a.x, b.y - a.y)
        guard pixelDist > 0 else {
            error = "Points A and B must be distinct."
            return
        }
        let pxPerFoot = pixelDist / d

        saving = true
        store.recalibrateScale(project, pixelsPerFoot: pxPerFoot, calibrationDistanceFeet: d)
        dismiss()
    }
}

private struct RecalibrateCanvas: View {
    let image: UIImage
    @Binding var pointA: CGPoint?
    @Binding var pointB: CGPoint?

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
                    marker(text: "A", color: .orange,
                           at: CGPoint(x: originX + a.x * scale, y: originY + a.y * scale))
                }
                if let b = pointB {
                    marker(text: "B", color: .blue,
                           at: CGPoint(x: originX + b.x * scale, y: originY + b.y * scale))
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
                        if pointA == nil {
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
    private func marker(text: String, color: Color, at point: CGPoint) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 22, height: 22)
            Circle().stroke(.white, lineWidth: 2).frame(width: 22, height: 22)
            Text(text).font(.caption2.bold()).foregroundStyle(.white)
        }
        .position(point)
    }
}
