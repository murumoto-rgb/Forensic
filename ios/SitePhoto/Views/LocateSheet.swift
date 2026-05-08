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
    @State private var showingGroupPicker = false
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingGroupPicker = true
                    } label: {
                        Label("Group", systemImage: "rectangle.stack")
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
            .sheet(isPresented: $showingGroupPicker) {
                PhotoGroupPickerSheet(
                    projectID: projectID,
                    excludingPhotoIDs: [],
                    fromPhotoID: nil,
                    pendingCount: pendingPhotos.count,
                    onSelect: { leadID in
                        saveAttachedToGroup(leadID: leadID)
                    }
                )
                .environment(store)
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

    /// Save every pending photo at the chosen lead's plan position, joining
    /// the lead's group so they render as stack tails.
    private func saveAttachedToGroup(leadID: UUID) {
        guard var current = store.project(withID: projectID),
              let plan = current.floorPlan,
              let leadIdx = current.photos.firstIndex(where: { $0.id == leadID }),
              let lpx = current.photos[leadIdx].planPixelX,
              let lpy = current.photos[leadIdx].planPixelY,
              !pendingPhotos.isEmpty else {
            dismiss()
            return
        }

        // Make sure the lead has a groupID and is marked as the primary.
        let gid: UUID
        if let existing = current.photos[leadIdx].groupID {
            gid = existing
        } else {
            gid = UUID()
            var leadCopy = current.photos[leadIdx]
            leadCopy.groupID = gid
            leadCopy.isPrimary = true
            current.photos[leadIdx] = leadCopy
            current = store.save(current)
        }

        let lx = (lpx - plan.anchorPixelX) / plan.pixelsPerFoot
        let ly = (lpy - plan.anchorPixelY) / plan.pixelsPerFoot

        for captured in pendingPhotos {
            let loc = ProjectStore.PhotoLocation(
                planPixelX: lpx, planPixelY: lpy,
                localXFeet: lx, localYFeet: ly,
                headingDegrees: nil,
                groupID: gid,
                isPrimary: false
            )
            do {
                current = try store.addPhoto(to: current, captured: captured, location: loc)
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

    // Pinch-zoom + pan state.
    @State private var zoom:       CGFloat = 1
    @State private var lastZoom:   CGFloat = 1
    @State private var pan:        CGSize  = .zero
    @State private var lastPan:    CGSize  = .zero
    /// Which mode the current drag is in. Decided once at drag start —
    /// near the pin → set heading; elsewhere → pan the canvas.
    @State private var dragMode:   DragMode? = nil
    private enum DragMode { case heading, pan }

    var body: some View {
        GeometryReader { geo in
            let imgSize  = image.size
            let baseFit  = min(geo.size.width  / max(1, imgSize.width),
                               geo.size.height / max(1, imgSize.height))
            let baseW    = imgSize.width  * baseFit
            let baseH    = imgSize.height * baseFit
            let baseOX   = (geo.size.width  - baseW) / 2
            let baseOY   = (geo.size.height - baseH) / 2

            // Effective scale = base fit × user zoom. We render the image
            // at its zoomed size directly (no scaleEffect), so all
            // gestures see true layout coordinates and the conversion to
            // image pixels is trivial.
            let effScale = baseFit * zoom
            let effW     = imgSize.width  * effScale
            let effH     = imgSize.height * effScale
            let effOX    = baseOX - (effW - baseW) / 2 + pan.width
            let effOY    = baseOY - (effH - baseH) / 2 + pan.height

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: effW, height: effH)
                    .offset(x: effOX, y: effOY)

                // Tap target sized to the zoomed image. Local coord space
                // is (0…effW, 0…effH), so a tap directly maps to an image
                // pixel via division by effScale — no transform inversion.
                Color.clear
                    .frame(width: effW, height: effH)
                    .offset(x: effOX, y: effOY)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { tap in
                        let inImage = CGPoint(x: tap.x / effScale,
                                              y: tap.y / effScale)
                        guard inImage.x >= 0, inImage.x <= imgSize.width,
                              inImage.y >= 0, inImage.y <= imgSize.height else { return }
                        planPoint = inImage
                        if step == .position { step = .direction }
                    }

                if let pp = planPoint {
                    let pinView = CGPoint(
                        x: effOX + pp.x * effScale,
                        y: effOY + pp.y * effScale
                    )

                    if let h = heading {
                        directionArrow(at: pinView, headingDegrees: h)
                    }

                    pinMarker(at: pinView)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let newZoom = max(1, min(8, lastZoom * value.magnification))
                            // Anchor zoom at the pinch start point: the
                            // image pixel under value.startLocation should
                            // stay there as the zoom changes.
                            //
                            // Derivation: imagePx under X_pinch is
                            //   (X_pinch − imgCenterBase − pan) / (baseFit · zoom)
                            // Holding it constant across (zoom, pan) gives
                            //   pan_new = q·(1 − r) + pan_start·r
                            // where r = magnification, q = X_pinch − imgCenterBase.
                            let imgCenterX = baseOX + baseW / 2
                            let imgCenterY = baseOY + baseH / 2
                            let qx = value.startLocation.x - imgCenterX
                            let qy = value.startLocation.y - imgCenterY
                            let r  = value.magnification
                            pan = CGSize(
                                width:  qx * (1 - r) + lastPan.width  * r,
                                height: qy * (1 - r) + lastPan.height * r
                            )
                            zoom = newZoom
                        }
                        .onEnded { _ in
                            lastZoom = zoom
                            lastPan  = pan
                        },
                    DragGesture(minimumDistance: 6, coordinateSpace: .local)
                        .onChanged { value in
                            // Decide once per drag: started near the pin →
                            // set heading; otherwise → pan the canvas.
                            if dragMode == nil {
                                dragMode = chooseDragMode(
                                    startLocation: value.startLocation,
                                    effOX: effOX, effOY: effOY,
                                    effScale: effScale
                                )
                            }
                            switch dragMode {
                            case .heading:
                                guard let pp = planPoint else { return }
                                // value.location is in ZStack-local layout
                                // coords (no scaleEffect to invert), so
                                // converting to an image pixel is just:
                                let inImage = CGPoint(
                                    x: (value.location.x - effOX) / effScale,
                                    y: (value.location.y - effOY) / effScale
                                )
                                let dx = inImage.x - pp.x
                                let dy = inImage.y - pp.y
                                guard dx * dx + dy * dy > 25 else { return }
                                let angRad = atan2(dy, dx)
                                let h = (angRad * 180 / .pi + 90).truncatingRemainder(dividingBy: 360)
                                heading = h < 0 ? h + 360 : h
                            case .pan:
                                pan = CGSize(
                                    width:  lastPan.width  + value.translation.width,
                                    height: lastPan.height + value.translation.height
                                )
                            case .none:
                                break
                            }
                        }
                        .onEnded { _ in
                            if dragMode == .pan {
                                lastPan = pan
                            }
                            dragMode = nil
                        }
                )
            )
        }
    }

    /// Drag started within finger-tap distance of the pin → heading mode.
    /// Hit zone radius is in screen points (~36 pt) and does NOT need to
    /// scale with zoom because the pin's screen-position is computed live
    /// from the current effective scale.
    private func chooseDragMode(
        startLocation: CGPoint,
        effOX: CGFloat,
        effOY: CGFloat,
        effScale: CGFloat
    ) -> DragMode {
        guard let pp = planPoint else { return .pan }
        let pinScreen = CGPoint(
            x: effOX + pp.x * effScale,
            y: effOY + pp.y * effScale
        )
        let dx = startLocation.x - pinScreen.x
        let dy = startLocation.y - pinScreen.y
        let r: CGFloat = 36
        return (dx * dx + dy * dy) < r * r ? .heading : .pan
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
