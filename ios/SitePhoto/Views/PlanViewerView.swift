import SwiftUI

struct PlanViewerView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage("sitephoto.bubbleScale") private var bubbleScale: Double = 1.5
    @State private var selectedPhotoID: UUID?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var pendingRecenterID: UUID?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                planArea

                if let selectedID = selectedPhotoID,
                   let photo = currentPhoto(for: selectedID) {
                    let allLocated = locatedPhotosOrdered()
                    let idx = allLocated.firstIndex(where: { $0.id == photo.id }) ?? 0
                    PhotoPreviewBar(
                        photo: photo,
                        index: idx,
                        totalCount: allLocated.count,
                        groupCount: currentGroup(for: photo).count,
                        projectID: projectID,
                        onSwipeNext: { navigateAll(direction: +1) },
                        onSwipePrevious: { navigateAll(direction: -1) },
                        onDismiss: { closePreview() }
                    )
                    .environment(store)
                    .frame(height: previewHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedPhotoID)
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
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

        let arrowLengthPlan = (primaryRview + 38 * bubbleScale) / fit
        let arrowLengthView = arrowLengthPlan * fit

        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: dispW, height: dispH)
                .offset(x: originX, y: originY)

            ForEach(markers.filter { $0.isPrimary && $0.bearing != nil }) { marker in
                // Heading is stored in plan-frame (CW from page-up at the time of
                // capture). Changing the plan's northDeg afterwards must NOT
                // rotate existing arrows, so draw with the heading as-is.
                let planFrame = marker.bearing ?? 0
                let centerX = originX + marker.x * fit
                let centerY = originY + marker.y * fit
                ArrowShape(bearingDegrees: planFrame, length: arrowLengthView)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3 * bubbleScale, lineCap: .round))
                    .frame(width: 1, height: 1)
                    .position(x: centerX, y: centerY)
                ArrowHead(bearingDegrees: planFrame,
                          length: arrowLengthView,
                          baseRadius: 14 * bubbleScale)
                    .fill(Color.green)
                    .frame(width: 1, height: 1)
                    .position(x: centerX, y: centerY)
            }

            // Tail bubbles first (under), then leads on top so a tap on a stack hits the lead.
            ForEach(markers.filter { !$0.isPrimary }) { marker in
                bubble(for: marker, radius: secRview)
                    .position(x: originX + marker.x * fit, y: originY + marker.y * fit)
                    .contentShape(Circle().inset(by: -8))
                    .onTapGesture {
                        select(photo: marker.photo, geo: geo, originX: originX, originY: originY, fit: fit)
                    }
            }
            ForEach(markers.filter { $0.isPrimary }) { marker in
                bubble(for: marker, radius: primaryRview)
                    .position(x: originX + marker.x * fit, y: originY + marker.y * fit)
                    .contentShape(Circle().inset(by: -8))
                    .onTapGesture {
                        select(photo: marker.photo, geo: geo, originX: originX, originY: originY, fit: fit)
                    }
            }

            NorthIndicator(northDeg: plan.northDeg)
                .frame(width: 56, height: 56)
                .position(x: geo.size.width - 38, y: 38)
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
        .onChange(of: pendingRecenterID) { _, newID in
            guard let id = newID,
                  let marker = markers.first(where: { $0.photo.id == id }) else { return }
            recenter(on: marker, geo: geo, originX: originX, originY: originY, fit: fit)
            pendingRecenterID = nil
        }
    }

    @ViewBuilder
    private func bubble(for marker: PlanMarker, radius: CGFloat) -> some View {
        let isSelected = marker.photo.id == selectedPhotoID
        let fill: Color = isSelected ? Color(red: 0.92, green: 0.27, blue: 0.20) : .green
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: radius * 2, height: radius * 2)
            Text("\(marker.photo.sequenceNumber)")
                .font(.system(size: radius * 1.1, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .frame(width: radius * 1.6, height: radius * 1.6)
        }
    }

    // MARK: - Selection / centering

    private func select(photo: Photo, geo: GeometryProxy, originX: CGFloat, originY: CGFloat, fit: CGFloat) {
        // Always pick the LEAD of the group when the user taps on the cluster
        // (the tap may land on a tail since the tap bubbles overlap visually).
        let target = leadOfGroup(containing: photo) ?? photo

        // Compute marker position for the target — the lead always sits at its
        // own planPixel coords, no offset.
        let targetMarker = PlanMarker(
            id: target.id,
            photo: target,
            x: target.planPixelX ?? 0,
            y: target.planPixelY ?? 0,
            isPrimary: true,
            bearing: target.headingDegrees
        )

        recenter(on: targetMarker, geo: geo, originX: originX, originY: originY, fit: fit)
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedPhotoID = target.id
        }
    }

    private func recenter(on marker: PlanMarker, geo: GeometryProxy, originX: CGFloat, originY: CGFloat, fit: CGFloat) {
        let lx = originX + marker.x * fit
        let ly = originY + marker.y * fit
        let geoCx = geo.size.width / 2
        let geoCy = geo.size.height / 2
        let targetX = geo.size.width / 2
        let targetY = max(80, (geo.size.height - previewHeight) / 4)
        let newX = targetX - geoCx - (lx - geoCx) * scale
        let newY = targetY - geoCy - (ly - geoCy) * scale

        withAnimation(.easeInOut(duration: 0.4)) {
            offset = CGSize(width: newX, height: newY)
            lastOffset = offset
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

    private func closePreview() {
        withAnimation(.easeOut(duration: 0.18)) {
            selectedPhotoID = nil
        }
    }

    private func advance(in group: [Photo], from idx: Int, by delta: Int) {
        guard !group.isEmpty else { return }
        let count = group.count
        let next = ((idx + delta) % count + count) % count
        let nextPhoto = group[next]
        selectedPhotoID = nextPhoto.id
        pendingRecenterID = nextPhoto.id
    }

    /// Navigate across every located photo in the project, sorted by sequence number.
    private func navigateAll(direction: Int) {
        let all = locatedPhotosOrdered()
        guard !all.isEmpty else { return }
        let count = all.count

        let currentIdx: Int
        if let id = selectedPhotoID, let i = all.firstIndex(where: { $0.id == id }) {
            currentIdx = i
        } else {
            currentIdx = 0
        }
        let nextIdx = ((currentIdx + direction) % count + count) % count
        let nextPhoto = all[nextIdx]
        selectedPhotoID = nextPhoto.id
        pendingRecenterID = nextPhoto.id
    }

    /// Every located photo in the project, sorted by sequence number.
    private func locatedPhotosOrdered() -> [Photo] {
        guard let project = store.project(withID: projectID) else { return [] }
        return project.photos
            .filter { $0.planPixelX != nil && $0.planPixelY != nil }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    // MARK: - Project lookups

    private func currentPhoto(for id: UUID) -> Photo? {
        store.project(withID: projectID)?.photos.first(where: { $0.id == id })
    }

    /// All photos in `photo`'s group, sorted by sequence number. If ungrouped, returns [photo].
    private func currentGroup(for photo: Photo) -> [Photo] {
        guard let project = store.project(withID: projectID) else { return [photo] }
        if let gid = photo.groupID {
            return project.photos
                .filter { $0.groupID == gid }
                .sorted { $0.sequenceNumber < $1.sequenceNumber }
        }
        return [photo]
    }

    private func leadOfGroup(containing photo: Photo) -> Photo? {
        let group = currentGroup(for: photo)
        return group.first(where: { $0.isPrimary }) ?? group.first
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

            // Heading is plan-frame (independent of northDeg). Tail trails
            // opposite the arrow direction so it stays consistent regardless
            // of how north is set later.
            let planFrameBearing = bearing ?? 0
            let oppRad = (planFrameBearing + 90) * .pi / 180
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
        VStack(spacing: 2) {
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
                    .offset(y: -14)
                    .rotationEffect(.degrees(northDeg))
            }
            Text(String(format: "%.0f°", northDeg))
                .font(.caption2.bold().monospaced())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
        }
    }
}

// MARK: - Preview bar with swipe-through-group

private struct PhotoPreviewBar: View {
    let photo: Photo
    let index: Int          // 0-based index within ALL located photos in the project
    let totalCount: Int     // total number of located photos in the project
    let groupCount: Int     // number of photos in this photo's group (1 if not grouped)
    let projectID: UUID
    let onSwipeNext: () -> Void
    let onSwipePrevious: () -> Void
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
                        .id(photo.id)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                } else {
                    ContentUnavailableView("Photo missing", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.white)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(photo.sequenceNumber)")
                        .font(.headline.monospaced())
                        .foregroundStyle(.white)
                    if totalCount > 1 {
                        Text("\(index + 1) of \(totalCount)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    if groupCount > 1 {
                        Text("group of \(groupCount)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(8)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                Spacer()
            }
            .padding(.leading, 12)
            .padding(.top, 12)

            if totalCount > 1 {
                HStack {
                    chevron(systemName: "chevron.left", action: onSwipePrevious)
                    Spacer()
                    chevron(systemName: "chevron.right", action: onSwipeNext)
                }
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity)
            }

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
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if abs(value.translation.height) > abs(value.translation.width) {
                        if value.translation.height > 60 {
                            onDismiss()
                        }
                        return
                    }
                    if value.translation.width < -40 {
                        onSwipeNext()
                    } else if value.translation.width > 40 {
                        onSwipePrevious()
                    }
                }
        )
    }

    @ViewBuilder
    private func chevron(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.45), in: Circle())
        }
    }
}
