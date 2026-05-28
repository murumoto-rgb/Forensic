import SwiftUI

struct FloorPlanNorthView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var northDeg: Double = 0
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Adjust the north direction. The N-arrow on the plan rotates with the slider; 0° points up, 90° points right.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .background(.ultraThinMaterial)

                if let img = planImage {
                    NorthArrowCanvas(image: img, northDeg: northDeg)
                        .background(.black)
                        .frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Plan unavailable", systemImage: "exclamationmark.triangle")
                }

                VStack(spacing: 6) {
                    HStack {
                        Slider(value: $northDeg, in: 0...359, step: 1)
                        Text("\(Int(northDeg.rounded()))°")
                            .font(.title3.monospaced())
                            .frame(minWidth: 60, alignment: .trailing)
                    }
                    HStack(spacing: 12) {
                        Button("Up (0°)")        { northDeg = 0 }
                        Button("Right (90°)")   { northDeg = 90 }
                        Button("Down (180°)")   { northDeg = 180 }
                        Button("Left (270°)")   { northDeg = 270 }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            .navigationTitle("Set North")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                guard !loaded, let plan = store.project(withID: projectID)?.floorPlan else { return }
                northDeg = plan.northDeg
                loaded = true
            }
        }
    }

    private var planImage: UIImage? {
        guard let proj = store.project(withID: projectID),
              let url = store.floorPlanURL(for: proj),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func save() {
        guard let project = store.project(withID: projectID) else { return }
        store.updateFloorPlanNorth(project, northDeg: northDeg)
        dismiss()
    }
}

private struct NorthArrowCanvas: View {
    let image: UIImage
    let northDeg: Double

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

                arrow
                    .frame(width: 120, height: 120)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private var arrow: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.45))
            VStack(spacing: 0) {
                Image(systemName: "arrowtriangle.up.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 36)
                    .foregroundStyle(.red)
                Text("N")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
            .rotationEffect(.degrees(northDeg))
        }
    }
}
