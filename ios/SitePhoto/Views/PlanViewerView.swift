import SwiftUI

struct PlanViewerView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhoto: Photo?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                planArea

                if let selected = selectedPhoto {
                    PhotoPreviewBar(photo: selected, projectID: projectID) {
                        withAnimation(.easeOut(duration: 0.15)) {
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scale = 1
                            lastScale = 1
                            offset = .zero
                            lastOffset = .zero
                        }
                    } label: {
                        Label("Reset View", systemImage: "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.iconOnly)
                    }
                }
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

        let markers = buildMarkers(project: project)

        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: dispW, height: dispH)
                .offset(x: originX, y: originY)

            // Direction arrows under bubbles so they don't obscure the number.
            ForEach(markers.filter { $0.isPrimary && $0.bearing != nil }) { marker in
                ArrowShape(bearingDegrees: marker.bearing!, length: arrowLength)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 1, height: 1)
                    .position(
                        x: originX + marker.x * fit,
                        y: originY + marker.y * fit
                    )
                ArrowHead(bearingDegrees: marker.bearing!, length: arrowLength)
                    .fill(Color.green)
                    .frame(width: 1, height: 1)
                    .position(
                        x: originX + marker.x * fit,
                        y: originY + marker.y * fit
                    )
            }

            ForEach(markers) { marker in
                BubbleMark(marker: marker)
                    .position(
                        x: originX + marker.x * fit,
                        y: originY + marker.y * fit
                    )
                    .contentShape(Circle().inset(by: -8))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedPhoto = marker.photo
                        }
                    }
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .scaleEffect(scale, anchor: .center)
        .offset(offset)
        .gesture(
            SimultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(0.5, min(8, lastScale * value))
                    }
                    .onEnded { _ in
                        lastScale = scale
                    },
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    }
            )
        )
    }

    private var arrowLength: CGFloat { 56 }

    // MARK: - Marker layout

    private func buildMarkers(project: Project) -> [PlanMarker] {
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

            // Trail in opposite direction of arrow (or straight down if no heading).
            let layoutBearing = bearing ?? 0
            let oppRad = (layoutBearing + 90) * .pi / 180
            let dx = cos(oppRad)
            let dy = sin(oppRad)

            let primaryR: Double = 13
            let secR: Double = 9
            let firstGap = primaryR + secR - 2
            let stepGap = secR * 2 - 2

            let tail = sorted.filter { $0.id != primary.id }
            for (i, t) in tail.enumerated() {
                let dist = firstGap + Double(i) * stepGap
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

    var body: some View {
        let radius: CGFloat = marker.isPrimary ? 18 : 13
        ZStack {
            Circle()
                .fill(Color.green)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .stroke(.white, lineWidth: 2)
                .frame(width: radius * 2, height: radius * 2)
            Text("\(marker.photo.sequenceNumber)")
                .font(.system(size: radius * 1.1, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(width: radius * 1.6, height: radius * 1.6)
        }
    }
}

/// Draws a line from the center in the bearing direction.
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

/// Triangular arrowhead at the tip of the bearing line.
private struct ArrowHead: Shape {
    let bearingDegrees: Double
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angRad = (bearingDegrees - 90) * .pi / 180
        let tip = CGPoint(
            x: center.x + cos(angRad) * length,
            y: center.y + sin(angRad) * length
        )
        let back = angRad + .pi
        let baseR: CGFloat = 14
        let leftX = tip.x + cos(back + 0.42) * baseR
        let leftY = tip.y + sin(back + 0.42) * baseR
        let rightX = tip.x + cos(back - 0.42) * baseR
        let rightY = tip.y + sin(back - 0.42) * baseR

        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: leftX, y: leftY))
        p.addLine(to: CGPoint(x: rightX, y: rightY))
        p.closeSubpath()
        return p
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
        .onTapGesture {
            onDismiss()
        }
    }
}
