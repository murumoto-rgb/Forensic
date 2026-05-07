import SwiftUI

struct FloorPlanOriginView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var marked: CGPoint?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Tap on the plan to set the origin (0, 0). All measurements are made from this point. The current origin is shown in red.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .background(.ultraThinMaterial)

                if let img = planImage {
                    OriginCanvas(
                        image: img,
                        existing: existingOrigin,
                        marked: $marked
                    )
                    .background(.black)
                    .frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Plan unavailable", systemImage: "exclamationmark.triangle")
                }

                if let err = error {
                    Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }
            }
            .navigationTitle("Set Origin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(marked == nil)
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

    private var existingOrigin: CGPoint? {
        guard let plan = store.project(withID: projectID)?.floorPlan else { return nil }
        return CGPoint(x: plan.anchorPixelX, y: plan.anchorPixelY)
    }

    private func save() {
        guard let project = store.project(withID: projectID),
              let p = marked else { return }
        store.updateFloorPlanOrigin(project,
                                    anchorPixelX: Double(p.x),
                                    anchorPixelY: Double(p.y))
        dismiss()
    }
}

private struct OriginCanvas: View {
    let image: UIImage
    let existing: CGPoint?
    @Binding var marked: CGPoint?

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

                if let e = existing {
                    crosshair(at: CGPoint(x: originX + e.x * scale, y: originY + e.y * scale),
                              color: .red.opacity(0.8))
                }
                if let m = marked {
                    crosshair(at: CGPoint(x: originX + m.x * scale, y: originY + m.y * scale),
                              color: .green)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { tap in
                let inImage = CGPoint(
                    x: (tap.x - originX) / scale,
                    y: (tap.y - originY) / scale
                )
                guard inImage.x >= 0, inImage.x <= imgSize.width,
                      inImage.y >= 0, inImage.y <= imgSize.height else { return }
                marked = inImage
            }
        }
    }

    @ViewBuilder
    private func crosshair(at point: CGPoint, color: Color) -> some View {
        ZStack {
            Circle().stroke(color, lineWidth: 3).frame(width: 28, height: 28)
            Path { p in
                p.move(to: CGPoint(x: -16, y: 0))
                p.addLine(to: CGPoint(x: 16, y: 0))
                p.move(to: CGPoint(x: 0, y: -16))
                p.addLine(to: CGPoint(x: 0, y: 16))
            }
            .stroke(color, lineWidth: 2)
            .frame(width: 32, height: 32)
            Text("(0, 0)")
                .font(.caption2.bold().monospaced())
                .foregroundStyle(color)
                .padding(.horizontal, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .offset(x: 22, y: -16)
        }
        .position(point)
    }
}
