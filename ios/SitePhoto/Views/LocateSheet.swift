import SwiftUI

enum LocateStep {
    case position
    case direction
}

struct LocateSheet: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Binding var pendingPhotos: [CapturedPhoto]

    @State private var step: LocateStep = .position
    @State private var planPoint: CGPoint?
    @State private var heading: Double?
    @State private var showingMoreCamera = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                instructionBar

                if let img = planImage {
                    PlanLocateCanvas(
                        image: img,
                        planPoint: $planPoint,
                        heading: $heading,
                        step: $step
                    )
                    .background(.black)
                    .frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Plan unavailable",
                        systemImage: "exclamationmark.triangle"
                    )
                    .frame(maxHeight: .infinity)
                }

                actionBar
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step == .direction {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") {
                            planPoint = nil
                            heading = nil
                            step = .position
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showingMoreCamera) {
                CameraView(
                    onCapture: { captured in
                        pendingPhotos.append(captured)
                        showingMoreCamera = false
                    },
                    onCancel: { showingMoreCamera = false }
                )
            }
        }
        .interactiveDismissDisabled(true)
    }

    // MARK: - Subviews

    private var instructionBar: some View {
        HStack {
            Text(instructionText)
                .font(.callout)
            Spacer()
            Text(countLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var instructionText: String {
        switch step {
        case .position:
            return "Tap on the plan to set the photo location."
        case .direction:
            return "Drag from the pin in the direction the camera was facing."
        }
    }

    private var countLabel: String {
        let n = pendingPhotos.count
        return "\(n) photo\(n == 1 ? "" : "s")"
    }

    private var navTitle: String {
        pendingPhotos.count > 1 ? "Locate Batch" : "Locate Photo"
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if let err = error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(role: .destructive) {
                    discard()
                } label: {
                    Label("Discard All", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .controlSize(.large)

                Spacer()

                Button {
                    showingMoreCamera = true
                } label: {
                    Label(
                        pendingPhotos.count == 1 ? "Photo at Same Spot" : "Another Photo",
                        systemImage: "plus.circle"
                    )
                }
                .controlSize(.large)
            }

            HStack {
                Menu {
                    Button("Skip Location (no plan position)") {
                        save(skipLocation: true)
                    }
                    if planPoint != nil {
                        Button("Skip Direction (no arrow)") {
                            save(skipDirection: true)
                        }
                    }
                } label: {
                    Label("Skip…", systemImage: "forward")
                }
                .disabled(pendingPhotos.isEmpty)

                Spacer()

                Button {
                    save()
                } label: {
                    Label(saveLabel, systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSave)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var saveLabel: String {
        pendingPhotos.count > 1 ? "Save All" : "Save"
    }

    private var canSave: Bool {
        !pendingPhotos.isEmpty && planPoint != nil
    }

    // MARK: - Plan image lookup

    private var planImage: UIImage? {
        guard let proj = store.project(withID: projectID),
              let url = store.floorPlanURL(for: proj),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Actions

    private func discard() {
        pendingPhotos = []
        planPoint = nil
        heading = nil
        step = .position
        dismiss()
    }

    private func save(skipLocation: Bool = false, skipDirection: Bool = false) {
        guard let project = store.project(withID: projectID) else { return }
        guard let plan = project.floorPlan else { return }
        guard !pendingPhotos.isEmpty else { dismiss(); return }

        let useLoc = !skipLocation && planPoint != nil
        let useHeading = useLoc && !skipDirection && heading != nil
        let groupID: UUID? = pendingPhotos.count > 1 ? UUID() : nil

        var current = project
        for (i, captured) in pendingPhotos.enumerated() {
            var photoLoc: ProjectStore.PhotoLocation?
            if useLoc, let pt = planPoint {
                photoLoc = ProjectStore.PhotoLocation(
                    planPixelX: Double(pt.x),
                    planPixelY: Double(pt.y),
                    localXFeet: (Double(pt.x) - plan.anchorPixelX) / plan.pixelsPerFoot,
                    localYFeet: (Double(pt.y) - plan.anchorPixelY) / plan.pixelsPerFoot,
                    headingDegrees: (i == 0 && useHeading) ? heading : nil,
                    groupID: groupID,
                    isPrimary: i == 0
                )
            }
            do {
                current = try store.addPhoto(to: current, captured: captured, location: photoLoc)
            } catch {
                self.error = "Could not save: \(error.localizedDescription)"
                return
            }
        }

        pendingPhotos = []
        planPoint = nil
        heading = nil
        step = .position
        dismiss()
    }
}

// MARK: - Plan canvas

struct PlanLocateCanvas: View {
    let image: UIImage
    @Binding var planPoint: CGPoint?
    @Binding var heading: Double?
    @Binding var step: LocateStep

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

                if let pp = planPoint {
                    let pinView = CGPoint(
                        x: originX + pp.x * scale,
                        y: originY + pp.y * scale
                    )

                    if let h = heading {
                        directionArrow(at: pinView, headingDegrees: h)
                    }

                    pinMarker(at: pinView)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { tap in
                guard step == .position else { return }
                let inImage = CGPoint(
                    x: (tap.x - originX) / scale,
                    y: (tap.y - originY) / scale
                )
                guard inImage.x >= 0, inImage.x <= imgSize.width,
                      inImage.y >= 0, inImage.y <= imgSize.height else { return }
                planPoint = inImage
                step = .direction
            }
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { value in
                        guard step == .direction, let pp = planPoint else { return }
                        let inImage = CGPoint(
                            x: (value.location.x - originX) / scale,
                            y: (value.location.y - originY) / scale
                        )
                        let dx = inImage.x - pp.x
                        let dy = inImage.y - pp.y
                        guard dx * dx + dy * dy > 25 else { return }
                        let angRad = atan2(dy, dx)
                        // Plan-frame angle (CW from page-up). Storing in plan-frame
                        // means changes to the floor plan's northDeg never rotate
                        // existing photo arrows - the drag direction is preserved.
                        let h = (angRad * 180 / .pi + 90).truncatingRemainder(dividingBy: 360)
                        heading = h < 0 ? h + 360 : h
                    }
            )
        }
    }

    @ViewBuilder
    private func pinMarker(at point: CGPoint) -> some View {
        ZStack {
            Circle().fill(.green).frame(width: 22, height: 22)
            Circle().stroke(.white, lineWidth: 3).frame(width: 22, height: 22)
        }
        .position(point)
    }

    @ViewBuilder
    private func directionArrow(at pin: CGPoint, headingDegrees: Double) -> some View {
        let angRad = (headingDegrees - 90) * .pi / 180
        let length: CGFloat = 64
        let tip = CGPoint(
            x: pin.x + cos(angRad) * length,
            y: pin.y + sin(angRad) * length
        )

        Path { p in
            p.move(to: pin)
            p.addLine(to: tip)
        }
        .stroke(.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))

        Path { p in
            let back = angRad + .pi
            let baseR: CGFloat = 16
            let leftX = tip.x + cos(back + 0.42) * baseR
            let leftY = tip.y + sin(back + 0.42) * baseR
            let rightX = tip.x + cos(back - 0.42) * baseR
            let rightY = tip.y + sin(back - 0.42) * baseR
            p.move(to: tip)
            p.addLine(to: CGPoint(x: leftX, y: leftY))
            p.addLine(to: CGPoint(x: rightX, y: rightY))
            p.closeSubpath()
        }
        .fill(.green)
    }
}
