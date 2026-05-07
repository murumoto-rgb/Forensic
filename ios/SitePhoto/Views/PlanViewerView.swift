import SwiftUI

struct PlanViewerView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage("sitephoto.bubbleScale") private var bubbleScale: Double = 1.5
    @State private var selectedPhoto: Photo?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var blinkPhase: Bool = false
    @State private var blinkTimer: Timer?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                planArea

                if let selected = selectedPhoto {
                    PhotoPreviewBar(photo: selected, projectID: projectID) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            selectedPhoto = nil
                        }
                    }
                    .environment(store)
                    .frame(height: previewHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedPhoto?.id)
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .onChange(of: selectedPhoto?.id) { _, newID in
                if newID != nil { startBlink() } else { stopBlink() }
            }
            .onDisappear { stopBlink() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                resetView()
            } label: {
                Image(systemName: "arrow.up.backward.and.arrow.down.forward")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack {
                Button {
                    bubbleScale = max(0.3, bubbleScale * 0.8)
                } label: {
                    Image(systemName: "minus.circle")
                }
                Button {
                    bubbleScale = min(3.0, bubbleScale * 1.25)
                } label: {
                    Image(systemName: "plus.circle")
                }
                Button("Done") { dismiss() }
            }
        }
    }

    private var previewHeight: CGFloat { 280 }

    @ViewBuilder
    private var planArea: some View {
        if let proj = store.project(withID: projectID),
           let plan = proj.floorPlan,
           let url = store.floorPlanURL(for: proj),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            GeometryReader { geo in
                planContent(geo: geo, project: proj, plan: plan, image: img)
            }
            .background(Color.black)
            .clipped()
        } else {
            ContentUnavailableView(
                "No plan",
                systemImage: "doc.viewfinder",
                description: Text("Set up the floor plan from the project screen.")
            )
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func planContent(geo: GeometryProxy, project: Project, plan: FloorPlan, image: UIImage) -> some View {
        let imgSize = image.size
        let fit = min(geo.size.width / max(1, imgSize.width),
                      geo.size.height / max(1, imgSize.height))
        let dispW = imgSize.width * fit
        let dispH = imgSize.height * fit
        let originX = (geo.size.width - dispW) / 2
        let originY = (geo.size.height - dispH) / 2

        let primaryRview = 18 * bubbleScale
        let secRview = 13 * bubbleScale
        let firstGapView = primaryRview + secRview - 2 * bubbleScale
        let stepGapView = secRview * 2 - 2 * bubbleScale

        let markers = buildMarkers(
            project: project,
            firstGapPlan: firstGapView / fit,
            stepGapPlan: stepGapView / fit
        )

        // Arrow length in plan-pixel space scales with bubble scale and inverse fit.
        let arrowLengthPlan = (primaryRview + 38 * bubbleScale) / fit

        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: dispW, height: dispH)
                .offset(x: originX, y: originY)

            // Direction arrows under bubbles.
            ForEach(markers.filter { $0.isPrimary && $0.bearing != nil }) { marker in
                let bearing = marker.bearing ?? 0
                let centerX = originX + marker.x * fit
                let centerY = originY + marker.y * fit
                let lengthView = arrowLengthPlan * fit
                ArrowShape(bearingDegrees: bearing - plan.northDeg, length: lengthView)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3 * bubbleScale, lineCap: .round))
                    .frame(width: 1, height: 1)
                    .position(x: centerX, y: centerY)
                ArrowHead(bearingDegrees: bearing - plan.northDeg,
                          length: lengthView,
                          baseRadius: 14 * bubbleScale)
                    .fill(Color.green)
                    .frame(width: 1, height: 1)
                    .position(x: centerX, y: centerY)
            }

            ForEach(markers) { marker in
                let radius = marker.isPrimary ? primaryRview : secRview
                let isSelected = marker.photo.id == selectedPhoto?.id
                let blinking = isSelected && blinkPhase
                BubbleMark(
                    marker: marker,
                    radius: radius,
                    blinking: blinking
                )
                .position(
                    x: originX + marker.x * fit,
                    y: originY + marker.y * fit
                )
                .contentShape(Circle().inset(by: -8))
                .onTapGesture {
                    handleBubbleTap(marker, geo: geo, originX: originX, originY: originY, fit: fit)
                }
            }

            // North indicator (top-right, fixed in screen space — note this rotates with the
            // canvas because of scaleEffect; that's intentional, it reads as a compass on the plan).
            if let plan = project.floorPlan {
                NorthIndicator(northDeg: plan.northDeg)
                    .frame(width: 40, height: 40)
                    .position(x: geo.size.width - 32, y: 32)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .scaleEffect(scale, anchor: .center)
        .offset(offset)
        .gesture(
            SimultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in scale = max(0.5, min(8, lastScale * value)) }
                    .onEnded { _ in lastScale = scale },
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in lastOffset = offset }
            )
        )
    }

    private func handleBubbleTap(_ marker: PlanMarker,
                                 geo: GeometryProxy,
                                 originX: CGFloat,
                                 originY: CGFloat,
                                 fit: CGFloat) {
        // Bubble's local position before the scaleEffect / offset.
        let lx = originX + marker.x * fit
        let ly = originY + marker.y * fit
        let geoCx = geo.size.width / 2
        let geoCy = geo.size.height / 2
        // Target screen position: centred horizontally, in the upper quarter of the
        // visible plan area (above where the preview will land).
        let targetX = geo.size.width / 2
        let targetY = max(80, (geo.size.height - previewHeight) / 4)

        // For scaleEffect(s, anchor: .center) followed by offset:
        //   screen = (local - geoCenter) * s + geoCenter + offset
        let newOffsetX = targetX - geoCx - (lx - geoCx) * scale
        let newOffsetY = targetY - geoCy - (ly - geoCy) * scale

        withAnimation(.easeInOut(duration: 0.4)) {
            offset = CGSize(width: newOffsetX, height: newOffsetY)
            lastOffset = offset
            selectedPhoto = marker.photo
        }
    }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.25)) {
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        }
    }

    // MARK: - Blink

    private func startBlink() {
        blinkTimer?.invalidate()
        blinkPhase = false
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.18)) {
                    blinkPhase.toggle()
                }
            }
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkPhase = false
    }

    // MARK: - Marker layout

    private func buildMarkers(project: Project,
                              firstGapPlan: Double,
                              stepGapPlan: Double) -> [PlanMarker] {
        var groups: [String: [Photo]] = [:]
        for photo in project.photos {
            guard photo.planPixelX != nil, photo.planPixelY != nil else { continue }
            let key = photo.groupID?.uuidString ?? photo.id.uuidString
            groups[key, default: []].append(photo)
        }

        var out: [PlanMarker] = []
        for (_, members) in groups {
            let sorted = members.sorted { $0.sequenceNumber < $1.sequenceNumber }
            let primary = sorted.first(where: { $0.isPrimary }) ?? sorted.first!
            let px = primary.planPixelX ?? 0
            let py = primary.planPixelY ?? 0
            let bearing = primary.headingDegrees

            out.append(PlanMarker(
                id: primary.id,
                photo: primary,
                x: px,
                y: py,
                isPrimary: true,
                bearing: bearing
            ))

            // Trail in opposite direction of arrow (south if no heading).
            let layoutBearing = (bearing ?? 0) - (project.floorPlan?.northDeg ?? 0)
            let oppRad = (layoutBearing + 90) * .pi / 180
            let dx = cos(oppRad)
            let dy = sin(oppRad)

            let tail = sorted.filter { $0.id != primary.id }
            for (i, t) in tail.enumerated() {
                let dist = firstGapPlan + Double(i) * stepGapPlan
                out.append(PlanMarker(
                    id: t.id,
                    photo: t,
                    x: px + dx * dist,
                    y: py + dy * dist,
                    isPrimary: false,
                    bearing: nil
                ))
            }
        }
        return out
    }
}

// MARK: - Helpers

struct PlanMarker: Identifiable {
    let id: UUID
    let photo: Photo
    let x: Double
    let y: Double
    let isPrimary: Bool
    let bearing: Double?
}

private struct BubbleMark: View {
    let marker: PlanMarker
    let radius: CGFloat
    let blinking: Bool

    var body: some View {
        let diameter = radius * 2
        let fillColor: Color = blinking ? .yellow : .green
        ZStack {
            Circle()
                .fill(fillColor)
                .frame(width: diameter, height: diameter)
            Circle()
                .stroke(.white, lineWidth: max(2, radius * 0.12))
                .frame(width: diameter, height: diameter)
            Text("\(marker.photo.sequenceNumber)")
                .font(.system(size: radius * 1.1, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .frame(width: radius * 1.6, height: radius * 1.6)
        }
    }
}

private struct ArrowShape: Shape {
    let bearingDegrees: Double
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angRad = (bearingDegrees - 90) * .pi / 180
        let tip = CGPoint(
            x: center.x + cos(angRad) * length,
            y: center.y + sin(angRad) * length
        )
        var p = Path()
        p.move(to: center)
        p.addLine(to: tip)
        return p
    }
}

private struct ArrowHead: Shape {
    let bearingDegrees: Double
    let length: CGFloat
    let baseRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angRad = (bearingDegrees - 90) * .pi / 180
        let tip = CGPoint(
            x: center.x + cos(angRad) * length,
            y: center.y + sin(angRad) * length
        )
        let back = angRad + .pi
        let leftX = tip.x + cos(back + 0.42) * baseRadius
        let leftY = tip.y + sin(back + 0.42) * baseRadius
        let rightX = tip.x + cos(back - 0.42) * baseRadius
        let rightY = tip.y + sin(back - 0.42) * baseRadius

        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: leftX, y: leftY))
        p.addLine(to: CGPoint(x: rightX, y: rightY))
        p.closeSubpath()
        return p
    }
}

private struct NorthIndicator: View {
    let northDeg: Double
    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.55))
            Image(systemName: "location.north.fill")
                .resizable()
                .scaledToFit()
                .padding(8)
                .foregroundStyle(.white)
                .rotationEffect(.degrees(northDeg))
            Text("N")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .offset(y: -16)
                .rotationEffect(.degrees(northDeg))
        }
    }
}

// MARK: - Preview bar

private struct PhotoPreviewBar: View {
    let photo: Photo
    let projectID: UUID
    let onDismiss: () -> Void

    @Environment(ProjectStore.self) private var store

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black

            if let project = store.project(withID: projectID) {
                let url = store.imageURL(for: photo, in: project)
                if let img = UIImage(contentsOfFile: url.path()) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Photo missing", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("#\(photo.sequenceNumber)")
                    .font(.headline.monospaced())
                    .foregroundStyle(.white)
                Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(8)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .padding(.leading, 12)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
    }
}
