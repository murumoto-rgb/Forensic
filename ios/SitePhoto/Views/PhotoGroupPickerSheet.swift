import SwiftUI

/// Lets the user choose which photo to stack a new/relocated photo onto.
/// Two modes (List / Plan) plus a confirmation step that shows both
/// thumbnails before the group is created.
struct PhotoGroupPickerSheet: View {
    let projectID: UUID
    /// Photo IDs to omit (typically the photo currently being relocated).
    let excludingPhotoIDs: Set<UUID>
    /// Photo being relocated, used to render the "from" thumbnail in the
    /// confirmation. Pass nil for new captures (LocateSheet).
    let fromPhotoID: UUID?
    /// Number of yet-unsaved captures being grouped (LocateSheet's case).
    let pendingCount: Int
    let onSelect: (UUID) -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sitephoto.bubbleScale") private var bubbleScale: Double = 1.5

    @State private var mode: Mode = .list
    @State private var planImage: UIImage?
    @State private var planLoadState: PlanLoadState = .loading
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var pendingTargetID: UUID?

    private enum Mode { case list, plan }
    private enum PlanLoadState { case loading, loaded, missing }

    init(projectID: UUID,
         excludingPhotoIDs: Set<UUID>,
         fromPhotoID: UUID? = nil,
         pendingCount: Int = 0,
         onSelect: @escaping (UUID) -> Void) {
        self.projectID = projectID
        self.excludingPhotoIDs = excludingPhotoIDs
        self.fromPhotoID = fromPhotoID
        self.pendingCount = pendingCount
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .list: listMode
                case .plan: planMode
                }
            }
            .navigationTitle(mode == .list ? "Group With…" : "Tap a Bubble")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        toggleMode()
                    } label: {
                        switch mode {
                        case .list:
                            Label("Pick from Plan", systemImage: "rectangle.expand.vertical")
                        case .plan:
                            Label("Pick from List", systemImage: "list.bullet")
                        }
                    }
                    .disabled(mode == .list && !planAvailable)
                }
            }
            .task(id: mode) {
                if mode == .plan && planLoadState != .loaded {
                    await loadPlan()
                }
            }
            .sheet(item: Binding(
                get: { pendingTargetID.map { TargetID(id: $0) } },
                set: { pendingTargetID = $0?.id }
            )) { target in
                ConfirmGroupSheet(
                    projectID: projectID,
                    fromPhotoID: fromPhotoID,
                    pendingCount: pendingCount,
                    targetPhotoID: target.id,
                    onConfirm: {
                        let id = target.id
                        pendingTargetID = nil
                        onSelect(id)
                        dismiss()
                    },
                    onCancel: { pendingTargetID = nil }
                )
                .environment(store)
            }
        }
    }

    private struct TargetID: Identifiable { let id: UUID }

    private func toggleMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            mode = (mode == .list) ? .plan : .list
        }
    }

    // MARK: - List mode

    @ViewBuilder
    private var listMode: some View {
        if eligible.isEmpty {
            ContentUnavailableView(
                "No located photos yet",
                systemImage: "mappin.slash",
                description: Text("Locate at least one photo on the plan first, then you can stack new photos onto it.")
            )
        } else {
            List {
                Section {
                    ForEach(eligible) { photo in
                        Button {
                            pendingTargetID = photo.id
                        } label: {
                            row(for: photo)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("The new photo will share this photo's location and join its group as a stacked tail bubble.")
                }
            }
        }
    }

    private var eligible: [Photo] {
        guard let project = store.project(withID: projectID) else { return [] }
        return project.photos
            .filter { $0.positionSource != .none && !excludingPhotoIDs.contains($0.id) }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    private var planAvailable: Bool {
        store.project(withID: projectID)?.floorPlan != nil
    }

    @ViewBuilder
    private func row(for photo: Photo) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: photo)
                .frame(width: 64, height: 48)
                .clipped()
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(photo.sequenceNumber)")
                        .font(.headline.monospaced())
                    if photo.groupID != nil {
                        Text(photo.isPrimary ? "GROUP★" : "GROUP")
                            .font(.caption2.bold().monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.blue)
                    }
                }
                if let lx = photo.localXFeet, let ly = photo.localYFeet {
                    Text(String(format: "X %.1f ft · Y %.1f ft", lx, ly))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func thumbnail(for photo: Photo) -> some View {
        if let project = store.project(withID: projectID),
           let url = store.thumbnailURL(for: photo, in: project),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Plan mode

    @ViewBuilder
    private var planMode: some View {
        switch planLoadState {
        case .loading:
            ZStack {
                Color.black
                VStack(spacing: 8) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Downloading plan from iCloud…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        case .missing:
            ContentUnavailableView(
                "Plan unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Switch back to the list to pick a photo.")
            )
            .frame(maxHeight: .infinity)
        case .loaded:
            if let img = planImage {
                GeometryReader { geo in
                    planContent(geo: geo, image: img)
                }
                .background(Color.black)
                .clipped()
            } else {
                ContentUnavailableView("Plan unavailable", systemImage: "exclamationmark.triangle")
            }
        }
    }

    @ViewBuilder
    private func planContent(geo: GeometryProxy, image: UIImage) -> some View {
        let imgSize = image.size
        let fit = min(geo.size.width / max(1, imgSize.width),
                      geo.size.height / max(1, imgSize.height))
        let dispW = imgSize.width * fit
        let dispH = imgSize.height * fit
        let originX = (geo.size.width - dispW) / 2
        let originY = (geo.size.height - dispH) / 2

        // Match PlanViewerView's sizing exactly.
        let primaryRview = 18 * bubbleScale
        let secRview = 13 * bubbleScale
        let firstGapView = primaryRview + secRview - 2 * bubbleScale
        let stepGapView = secRview * 2 - 2 * bubbleScale

        let markers = buildMarkers(
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

            // Direction arrows on primary bubbles with a stored bearing.
            ForEach(markers.filter { $0.isPrimary && $0.bearing != nil }) { marker in
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

            // Tails first so leads draw on top of any visual overlap.
            ForEach(markers.filter { !$0.isPrimary }) { m in
                bubble(seq: m.photo.sequenceNumber, radius: secRview)
                    .position(x: originX + m.x * fit, y: originY + m.y * fit)
                    .contentShape(Circle().inset(by: -8))
                    .onTapGesture {
                        pendingTargetID = m.photo.id
                    }
            }
            ForEach(markers.filter { $0.isPrimary }) { m in
                bubble(seq: m.photo.sequenceNumber, radius: primaryRview)
                    .position(x: originX + m.x * fit, y: originY + m.y * fit)
                    .contentShape(Circle().inset(by: -8))
                    .onTapGesture {
                        pendingTargetID = m.photo.id
                    }
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

    @ViewBuilder
    private func bubble(seq: Int, radius: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.green).frame(width: radius * 2, height: radius * 2)
            Text("\(seq)")
                .font(.system(size: radius * 1.1, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .frame(width: radius * 1.6, height: radius * 1.6)
        }
    }

    // MARK: - Marker layout (mirrors PlanViewerView)

    private struct Marker: Identifiable {
        let id: UUID
        let photo: Photo
        let x: Double
        let y: Double
        let isPrimary: Bool
        let bearing: Double?
    }

    private func buildMarkers(firstGapPlan: Double, stepGapPlan: Double) -> [Marker] {
        guard let project = store.project(withID: projectID) else { return [] }
        var groups: [String: [Photo]] = [:]
        for photo in project.photos {
            guard photo.planPixelX != nil, photo.planPixelY != nil else { continue }
            if excludingPhotoIDs.contains(photo.id) { continue }
            let key = photo.groupID?.uuidString ?? photo.id.uuidString
            groups[key, default: []].append(photo)
        }
        var markers: [Marker] = []
        for (_, members) in groups {
            let sorted = members.sorted { $0.sequenceNumber < $1.sequenceNumber }
            let lead = sorted.first(where: { $0.isPrimary }) ?? sorted.first!
            let lpx = lead.planPixelX ?? 0
            let lpy = lead.planPixelY ?? 0
            markers.append(Marker(
                id: lead.id, photo: lead, x: lpx, y: lpy,
                isPrimary: true, bearing: lead.headingDegrees
            ))

            let bearing = lead.headingDegrees ?? 0
            let oppRad = (bearing + 90) * .pi / 180
            let dx = cos(oppRad)
            let dy = sin(oppRad)
            let tail = sorted.filter { $0.id != lead.id }
            for (i, t) in tail.enumerated() {
                let dist = firstGapPlan + Double(i) * stepGapPlan
                markers.append(Marker(
                    id: t.id, photo: t,
                    x: lpx + dx * dist, y: lpy + dy * dist,
                    isPrimary: false, bearing: nil
                ))
            }
        }
        return markers
    }

    private func loadPlan() async {
        planLoadState = .loading
        guard let proj = store.project(withID: projectID),
              proj.floorPlan != nil,
              let url = store.floorPlanURL(for: proj) else {
            planLoadState = .missing
            return
        }
        if let data = await store.loadFileBytes(at: url),
           let img = UIImage(data: data) {
            planImage = img
            planLoadState = .loaded
        } else {
            planLoadState = .missing
        }
    }
}

// MARK: - Confirmation sheet

private struct ConfirmGroupSheet: View {
    let projectID: UUID
    let fromPhotoID: UUID?
    let pendingCount: Int
    let targetPhotoID: UUID
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Text("Group these photos?")
                .font(.title3.bold())
                .padding(.top, 8)

            HStack(alignment: .center, spacing: 12) {
                fromTile
                Image(systemName: "plus")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                targetTile
            }
            .padding(.horizontal)

            if let target = targetPhoto {
                Text("It will share #\(target.sequenceNumber)'s location on the plan and join its group.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(role: .cancel) {
                    onCancel()
                    dismiss()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    onConfirm()
                    dismiss()
                } label: {
                    Text("Group").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .padding(.top)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var targetPhoto: Photo? {
        store.project(withID: projectID)?.photos.first { $0.id == targetPhotoID }
    }

    private var fromPhoto: Photo? {
        guard let id = fromPhotoID else { return nil }
        return store.project(withID: projectID)?.photos.first { $0.id == id }
    }

    @ViewBuilder
    private var fromTile: some View {
        if let from = fromPhoto {
            tile(for: from, caption: "Move this")
        } else if pendingCount > 0 {
            placeholderTile(
                glyph: "camera.fill",
                primary: pendingCount == 1 ? "1 new photo" : "\(pendingCount) new photos",
                caption: "Add these"
            )
        } else {
            placeholderTile(glyph: "questionmark", primary: "—", caption: "Move this")
        }
    }

    @ViewBuilder
    private var targetTile: some View {
        if let target = targetPhoto {
            tile(for: target, caption: "Onto this")
        } else {
            placeholderTile(glyph: "questionmark", primary: "—", caption: "Onto this")
        }
    }

    @ViewBuilder
    private func tile(for photo: Photo, caption: String) -> some View {
        VStack(spacing: 6) {
            tileImage(for: photo)
                .frame(width: 110, height: 110)
                .clipped()
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("#\(photo.sequenceNumber)")
                .font(.headline.monospaced())
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tileImage(for photo: Photo) -> some View {
        if let project = store.project(withID: projectID),
           let url = store.thumbnailURL(for: photo, in: project),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func placeholderTile(glyph: String, primary: String, caption: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                Image(systemName: glyph)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, height: 110)
            Text(primary)
                .font(.headline.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
