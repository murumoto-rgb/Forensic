import SwiftUI

struct PlanViewerView: View {
    let projectID: UUID
    /// Optional callback fired when the engineer taps "Open in project
    /// list" on a photo's preview. Carries the photo's id back to the
    /// host so the project list can scroll to that row. The viewer
    /// dismisses itself before the callback runs; the host is expected
    /// to drive the scroll on the next layout pass.
    var onOpenPhotoInList: ((UUID) -> Void)? = nil
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage("sitephoto.bubbleScale") private var bubbleScale: Double = 1.5
    /// Persisted preview-bar navigation mode: when set to `.group` the
    /// engineer swipes / scrolls within the current photo's group; when
    /// set to `.all` the swipe ranges over every located photo on the
    /// active plan. Survives across sessions. Default `.group` so
    /// tapping a grouped bubble immediately surfaces its members.
    @AppStorage("sitephoto.photoPreviewNavMode") private var navModeRaw: String = PreviewNavMode.group.rawValue
    private var navMode: PreviewNavMode {
        get { PreviewNavMode(rawValue: navModeRaw) ?? .group }
    }
    /// Persisted color mode for the plan markers — `status` (single green,
    /// historical default), `bucket`, or `primaryTag`. Stored under
    /// `PlanColorMode.storageKey` so `PDFExportService` reads the same value
    /// from `UserDefaults` when rendering the PDF floor plan.
    @AppStorage(PlanColorMode.storageKey) private var planColorModeRaw: String = PlanColorMode.status.rawValue
    private var planColorMode: PlanColorMode {
        PlanColorMode(rawValue: planColorModeRaw) ?? .status
    }
    @State private var selectedPhotoID: UUID?
    /// Drives the BubbleStackSheet — non-nil when the engineer has tapped
    /// a stack-badge bubble. The sheet lists every photo whose center
    /// falls inside that overlap cluster.
    @State private var stackTarget: PlanStackTarget?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var pendingRecenterID: UUID?
    @State private var planImage: UIImage?
    @State private var layoutCache = PlanLayoutCache()
    @State private var planLoadState: PlanLoadState = .loading

    private enum PlanLoadState { case loading, loaded, missing }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                planArea

                if let selectedID = selectedPhotoID,
                   let photo = currentPhoto(for: selectedID) {
                    PhotoPreviewBar(
                        photo: photo,
                        activeSet: activeNavSet(for: photo),
                        navMode: Binding(
                            get: { navMode },
                            set: { navModeRaw = $0.rawValue }
                        ),
                        projectID: projectID,
                        onSwipeNext: { navigate(direction: +1) },
                        onSwipePrevious: { navigate(direction: -1) },
                        onSelectPhoto: { id in
                            // Quiet recenter — same mechanism the bubble
                            // tap path uses, but without re-entering
                            // select() (which would lock the preview to
                            // a group lead and skip non-lead members).
                            pendingRecenterID = id
                            withAnimation(.easeInOut(duration: 0.25)) {
                                selectedPhotoID = id
                            }
                        },
                        onOpenInList: { id in
                            // Dismiss the viewer and let the host scroll
                            // its project list to this photo so the
                            // engineer can tag / move / delete.
                            onOpenPhotoInList?(id)
                            dismiss()
                        },
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
            .task(id: planTaskID) {
                await loadPlanImage()
            }
            .sheet(item: $stackTarget) { target in
                BubbleStackSheet(
                    projectID: projectID,
                    photoIDs: target.photoIDs,
                    actionLabel: "View",
                    onSelect: { id in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedPhotoID = id
                        }
                    }
                )
                .environment(store)
            }
        }
    }

    /// Re-trigger the plan image load when the project, the floor-plan
    /// filename, or the calibration changes (e.g. after a re-calibrate or
    /// plan replace).
    private var planTaskID: String {
        guard let proj = store.project(withID: projectID) else { return "none" }
        if let plan = proj.floorPlan {
            return "\(proj.id)|\(plan.imageFilename)|\(plan.pixelsPerFoot)"
        }
        return "\(proj.id)|none"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                Button {
                    resetView()
                } label: {
                    Image(systemName: "arrow.up.backward.and.arrow.down.forward")
                }
                Menu {
                    Picker("Color markers by", selection: $planColorModeRaw) {
                        ForEach(PlanColorMode.allCases, id: \.self) { mode in
                            Label(mode.displayName, systemImage: mode.iconName)
                                .tag(mode.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                }
            }
        }
        if let project = store.project(withID: projectID), project.floorPlans.count > 1 {
            ToolbarItem(placement: .principal) {
                planPickerMenu(project: project)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack {
                Button {
                    bubbleScale = max(0.075, bubbleScale * 0.8)
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

    private var previewHeight: CGFloat { 364 }

    /// Photos the preview-bar's swipe + thumbnail strip walks across.
    /// Driven by the persisted nav mode: `.group` returns the current
    /// photo's group (or `[photo]` if ungrouped); `.all` returns every
    /// located photo on the active plan in sequence-number order.
    private func activeNavSet(for photo: Photo) -> [Photo] {
        switch navMode {
        case .group: return currentGroup(for: photo)
        case .all:   return locatedPhotosOrdered()
        }
    }

    @ViewBuilder
    private var planArea: some View {
        if let proj = store.project(withID: projectID),
           let plan = proj.floorPlan {
            switch planLoadState {
            case .loading:
                ZStack {
                    Color.black
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("Downloading plan from iCloud…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxHeight: .infinity)
            case .loaded:
                if let img = planImage {
                    GeometryReader { geo in
                        planContent(geo: geo, project: proj, plan: plan, image: img)
                    }
                    .background(Color.black)
                    .clipped()
                } else {
                    missingPlanView
                }
            case .missing:
                missingPlanView
            }
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
    private var missingPlanView: some View {
        ZStack {
            Color.black
            ContentUnavailableView(
                "Plan unavailable",
                systemImage: "doc.badge.ellipsis",
                description: Text("The plan image could not be loaded from iCloud.")
            )
            .foregroundStyle(.white)
        }
        .frame(maxHeight: .infinity)
    }

    private func loadPlanImage() async {
        planLoadState = .loading
        planImage = nil
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

    @ViewBuilder
    private func planContent(geo: GeometryProxy, project: Project, plan: FloorPlan, image: UIImage) -> some View {
        let imgSize = image.size
        let fit = min(geo.size.width / max(1, imgSize.width),
                      geo.size.height / max(1, imgSize.height))
        // Bake the user's zoom directly into image size + bubble
        // positions instead of going through .scaleEffect. scaleEffect
        // GPU-transforms already-rasterised pixels, which blurs text
        // at any scale ≠ 1. With manual scaling the image re-renders
        // at the new size each frame and bubble text stays crisp at
        // every zoom level. Mirrors `PlanLocateCanvas` in
        // `LocateSheet.swift`.
        let effScale = fit * scale
        let effW = imgSize.width * effScale
        let effH = imgSize.height * effScale
        let effOX = (geo.size.width  - effW) / 2 + offset.width
        let effOY = (geo.size.height - effH) / 2 + offset.height

        // Per-project bubble size — uniformly larger when sequence
        // numbers grow to 3+ digits so text doesn't have to shrink as
        // hard. All bubbles within a single render use the same scale.
        let digitScale = bubbleDigitScale(for: project)
        // Base radius at fit-to-screen (zoom=1). The plan-pixel
        // footprint = base / fit — independent of zoom, so the cluster
        // detection threshold uses this directly.
        let basePrimaryRview = 18 * bubbleScale * digitScale
        let baseSecRview = 13 * bubbleScale * digitScale
        // Rendered radius scales with zoom so the bubble keeps a fixed
        // plan-pixel footprint as the user pinches in/out — bigger when
        // zoomed in, smaller when zoomed out — mirroring how the old
        // .scaleEffect approach behaved, just without the rasterised-
        // pixel blur. Same for arrow length / stroke / arrowhead size.
        let primaryRview = basePrimaryRview * scale

        // Group leads (one marker per groupID, or one per ungrouped
        // photo). Tail bubbles are no longer rendered — grouped photos
        // collapse into a single ringed bubble; the engineer drills into
        // group members via the photo editor's per-group navigation.
        let arrowLengthPlan = (basePrimaryRview + 38 * bubbleScale) / fit
        let layout = layoutCache.value(projectID: projectID, revision: store.projectGeneration, fit: Double(fit), bubbleScale: bubbleScale) {
        let initialMarkers = buildMarkers(project: project)

        // MARK: cluster detection (replaces the old fanning rosette)
        let primaryRplan = Double(basePrimaryRview / fit)
        let secRplan     = Double(baseSecRview     / fit)
        // Photos whose centers fall within one bubble RADIUS of each
        // other are considered a single visual stack. The previous
        // rosette-fanning rendering displaced bubbles far from their
        // placed positions; the stack-badge approach instead renders ONE
        // representative bubble at the cluster centroid with a +N count
        // badge and surfaces the stack contents through a tap-to-expand
        // sheet. Position fidelity > visual spread.
        let primaryClusters = ClusterFanning.detectPrimaryClusters(
            markers: initialMarkers,
            position: { CGPoint(x: $0.x, y: $0.y) },
            isPrimary: { $0.isPrimary },
            collisionRadius: primaryRplan * 1.0
        )

        // For each cluster build a "displayed primary" — the lowest-seq
        // member acting as the cluster's lead, positioned at the cluster
        // centroid. Singletons keep their natural position (centroid ==
        // member position). groupSize carries through so the cluster
        // representative draws the group-band when the lead represents
        // a group.
        let displayedPrimaries: [DisplayedPrimary] = primaryClusters.map { cluster in
            let lead = cluster.members.min(by: { $0.photo.sequenceNumber < $1.photo.sequenceNumber })
                ?? cluster.members[0]
            let leadAtCentroid = PlanMarker(
                id: lead.id, photo: lead.photo,
                x: cluster.centroid.x, y: cluster.centroid.y,
                isPrimary: true, bearing: lead.bearing,
                groupSize: lead.groupSize
            )
            return DisplayedPrimary(
                id: lead.photo.id,
                marker: leadAtCentroid,
                stackPhotoIDs: cluster.members.map { $0.photo.id }
            )
        }


        // Arrow shortening considers the cluster representatives at
        // their displayed positions — no tails to consider anymore.
        let allDisplayedForArrowMath = displayedPrimaries.map { $0.marker }
        let arrowLengthsByID = ClusterFanning.arrowLengthAdjustments(
            markers: allDisplayedForArrowMath,
            id: { $0.photo.id },
            position: { CGPoint(x: $0.x, y: $0.y) },
            isPrimary: { $0.isPrimary },
            bearingDegrees: { $0.bearing },
            primaryRadius: primaryRplan,
            secondaryRadius: secRplan,
            defaultArrowLength: arrowLengthPlan
        )

            return PlanLayoutSnapshot(primaries: displayedPrimaries, arrowLengths: arrowLengthsByID)
        }
        let displayedPrimaries = layout.primaries
        let arrowLengthsByID = layout.arrowLengths

        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: effW, height: effH)
                .offset(x: effOX, y: effOY)

            ForEach(displayedPrimaries) { dp in
                if let bearing = dp.marker.bearing {
                    let planFrame = bearing
                    let centerX = effOX + dp.marker.x * effScale
                    let centerY = effOY + dp.marker.y * effScale
                    let myArrowLengthPlan = arrowLengthsByID[dp.marker.photo.id] ?? arrowLengthPlan
                    // Arrow scales with zoom so it stays plan-anchored —
                    // same rule as the bubble radius. Multiply the plan-
                    // pixel length by effScale (= fit · zoom) instead of
                    // just fit.
                    let myArrowLengthView = CGFloat(myArrowLengthPlan) * effScale
                    ArrowShape(bearingDegrees: planFrame, length: myArrowLengthView)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 3 * bubbleScale * scale, lineCap: .round))
                        .frame(width: 1, height: 1)
                        .position(x: centerX, y: centerY)
                    ArrowHead(bearingDegrees: planFrame,
                              length: myArrowLengthView,
                              baseRadius: 14 * bubbleScale * scale)
                        .fill(Color.green)
                        .frame(width: 1, height: 1)
                        .position(x: centerX, y: centerY)
                }
            }

            // Group-lead bubbles. Grouped photos no longer render tail
            // bubbles — the lead carries a black band signalling that
            // it represents a group. contentShape + onTapGesture must
            // come BEFORE .position(...) — .position reparents the view
            // to fill the entire plan area for layout, which would let
            // a trailing .contentShape(Circle()) inscribe in the whole
            // parent and steal every tap.
            ForEach(displayedPrimaries) { dp in
                stackOrSingle(dp,
                              primaryRview: primaryRview,
                              effOX: effOX, effOY: effOY,
                              effScale: effScale,
                              geo: geo, imgSize: imgSize, fit: fit)
            }

            NorthIndicator(northDeg: plan.northDeg)
                .frame(width: 56, height: 56)
                .position(x: geo.size.width - 38, y: 38)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .gesture(
            SimultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let newScale = max(0.5, min(8, lastScale * value.magnification))
                        // Anchor the zoom at the pinch start point: the
                        // image pixel under value.startLocation should
                        // stay there as the scale changes. Same derivation
                        // as `PlanLocateCanvas` in LocateSheet:
                        //   offset_new = q·(1 − r) + offset_start·r
                        // where r = magnification and q is the pinch
                        // location relative to the image's natural-fit
                        // center.
                        let baseW = imgSize.width  * fit
                        let baseH = imgSize.height * fit
                        let imgCenterX = (geo.size.width  - baseW) / 2 + baseW / 2
                        let imgCenterY = (geo.size.height - baseH) / 2 + baseH / 2
                        let qx = value.startLocation.x - imgCenterX
                        let qy = value.startLocation.y - imgCenterY
                        let r  = value.magnification
                        offset = CGSize(
                            width:  qx * (1 - r) + lastOffset.width  * r,
                            height: qy * (1 - r) + lastOffset.height * r
                        )
                        scale = newScale
                    }
                    .onEnded { _ in
                        lastScale = scale
                        lastOffset = offset
                    },
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
            guard let id = newID else { return }
            // Map a non-lead group member's ID back to the lead so the
            // recenter target points at the bubble that actually
            // renders for this photo.
            let bubbleID = bubblePhotoID(for: id) ?? id
            guard let dp = displayedPrimaries.first(where: {
                $0.marker.photo.id == bubbleID || $0.stackPhotoIDs.contains(bubbleID)
            }) else { return }
            recenter(on: dp.marker, geo: geo, imgSize: imgSize, fit: fit)
            pendingRecenterID = nil
        }
    }

    /// Render either a single primary bubble (cluster of 1) or a
    /// stack-badge bubble that opens BubbleStackSheet on tap (cluster
    /// of ≥ 2). The displayed primary's marker is positioned at the
    /// cluster centroid, so both branches share the same `.position`
    /// math.
    @ViewBuilder
    private func stackOrSingle(_ dp: DisplayedPrimary,
                                primaryRview: CGFloat,
                                effOX: CGFloat, effOY: CGFloat,
                                effScale: CGFloat,
                                geo: GeometryProxy,
                                imgSize: CGSize,
                                fit: CGFloat) -> some View {
        let x = effOX + dp.marker.x * effScale
        let y = effOY + dp.marker.y * effScale
        if dp.stackCount == 1 {
            bubble(for: dp.marker, radius: primaryRview)
                .frame(width: primaryRview * 2, height: primaryRview * 2)
                .contentShape(Circle().inset(by: -8))
                .onTapGesture {
                    select(photo: dp.marker.photo, geo: geo, imgSize: imgSize, fit: fit)
                }
                .position(x: x, y: y)
        } else {
            stackBadge(for: dp.marker,
                        additionalCount: dp.stackCount - 1,
                        radius: primaryRview)
                .frame(width: primaryRview * 2, height: primaryRview * 2)
                .contentShape(Circle().inset(by: -8))
                .onTapGesture {
                    stackTarget = PlanStackTarget(
                        id: dp.id,
                        photoIDs: dp.stackPhotoIDs
                    )
                }
                .position(x: x, y: y)
        }
    }

    /// Stack-badge bubble: the standard primary bubble plus a small
    /// pill in the top-right corner showing `+N` where N is the number
    /// of other photos at the same spot.
    @ViewBuilder
    private func stackBadge(for marker: PlanMarker,
                             additionalCount: Int,
                             radius: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            bubble(for: marker, radius: radius)
            // Pill badge — size tracks the bubble radius so it stays
            // proportional across the zoom + bubbleScale settings.
            let pillFont = max(10, radius * 0.5)
            Text("+\(additionalCount)")
                .font(.system(size: pillFont, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, max(4, radius * 0.18))
                .padding(.vertical, max(1, radius * 0.05))
                .background(
                    Capsule().fill(Color.black.opacity(0.78))
                )
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1)
                )
                // Offset half outside the bubble so the badge sits
                // visually on the bubble's rim, like a notification
                // count badge.
                .offset(x: radius * 0.25, y: -radius * 0.25)
        }
    }

    @ViewBuilder
    private func bubble(for marker: PlanMarker, radius: CGFloat) -> some View {
        // Canvas-based rendering keeps the text crisp at every zoom
        // level. SwiftUI Text + .minimumScaleFactor lets the text land
        // at a fractional point size and is re-rasterised by the layer
        // tree on each frame — both produce soft edges. Canvas resolves
        // the Text once at an integer point size and draws via Metal,
        // so glyphs land on exact pixel boundaries.
        let fill = fillColor(for: marker)
        // When the bubble carries a group band, the band's stroke eats
        // the outer slice of the fill area. Use a band-aware "effective
        // radius" for the text-fit math so 3-digit sequence numbers
        // shrink to clear the band's inner edge instead of being clipped
        // by it. The 3pt floor is the smallest practical rasterised
        // glyph and lets text scale down as the engineer drops
        // bubbleScale below the previous 0.15 floor.
        let bandWidth: CGFloat = marker.groupSize > 1 ? max(2, radius * 0.18) : 0
        let effR = max(1, radius - bandWidth)
        Canvas { context, size in
            context.fill(
                Path(ellipseIn: CGRect(origin: .zero, size: size)),
                with: .color(fill)
            )
            let maxSize = max(3, floor(effR * 1.1))
            let str = "\(marker.photo.sequenceNumber)"
            var fontSize = maxSize
            var resolved = context.resolve(
                Text(str)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white)
            )
            let measured = resolved.measure(in: size)
            let widthCap = effR * 1.75
            if measured.width > widthCap {
                let factor = max(0.6, widthCap / measured.width)
                fontSize = max(3, floor(maxSize * factor))
                resolved = context.resolve(
                    Text(str)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundColor(.white)
                )
            }
            context.draw(
                resolved,
                at: CGPoint(x: size.width / 2, y: size.height / 2),
                anchor: .center
            )
        }
        .frame(width: radius * 2, height: radius * 2)
        .overlay {
            // Black band: marks the bubble as a group lead so the
            // engineer knows it represents N photos, not one. Drawn as
            // a strokeBorder so the ring sits flush with the bubble's
            // outer edge (occupies the outermost slice of the fill
            // rather than extending into empty space).
            if marker.groupSize > 1 {
                Circle()
                    .strokeBorder(Color.black,
                                   lineWidth: max(2, radius * 0.18))
            }
        }
    }

    /// Resolve the bubble fill colour. Selected always wins (red) so the
    /// user can spot the active marker regardless of the colour mode.
    /// Unselected markers come from the shared `PlanMarkerColors` resolver
    /// so on-screen and PDF stay in sync. Pulled out of the `@ViewBuilder`
    /// body so the `if/else` branches don't trip "type '()' cannot conform
    /// to 'View'" — view builders interpret every statement as a candidate
    /// view, and a `let fill: Color` assignment is `Void`.
    private func fillColor(for marker: PlanMarker) -> Color {
        // The bubble on the plan represents the LEAD of a group, never
        // a non-lead member. When the engineer previews a non-lead
        // group member (via the thumbnail strip or in-group swipe),
        // resolve the selection back to its lead so the lead bubble
        // stays highlighted while they cycle through members.
        if marker.photo.id == bubblePhotoID(for: selectedPhotoID) {
            return Color(red: 0.92, green: 0.27, blue: 0.20)
        }
        if let project = store.project(withID: projectID) {
            return PlanMarkerColors.color(for: marker.photo,
                                            mode: planColorMode,
                                            project: project)
        }
        return .green
    }

    /// Map a photo ID to the photo ID of the bubble that represents it
    /// on the plan. For ungrouped photos, that's the photo itself;
    /// for grouped photos, it's the group's lead. Used by the highlight
    /// + recenter paths so previewing a non-lead member doesn't lose
    /// the visual cue or pan the plan to nowhere.
    private func bubblePhotoID(for photoID: UUID?) -> UUID? {
        guard let photoID,
              let photo = currentPhoto(for: photoID) else { return nil }
        return leadOfGroup(containing: photo)?.id ?? photoID
    }

    // MARK: - Selection / centering

    private func select(photo: Photo, geo: GeometryProxy, imgSize: CGSize, fit: CGFloat) {
        // Tap targets are always cluster representatives (group leads),
        // but resolve to the lead defensively in case a caller passes
        // a non-lead photo through select(photo:).
        let target = leadOfGroup(containing: photo) ?? photo

        // Compute marker position for the target — the lead always sits at its
        // own planPixel coords, no offset.
        let targetMarker = PlanMarker(
            id: target.id,
            photo: target,
            x: target.planPixelX ?? 0,
            y: target.planPixelY ?? 0,
            isPrimary: true,
            bearing: target.headingDegrees,
            // groupSize doesn't affect recenter math; pick 1 since
            // this marker isn't used for drawing.
            groupSize: 1
        )

        recenter(on: targetMarker, geo: geo, imgSize: imgSize, fit: fit)
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedPhotoID = target.id
        }
    }

    private func recenter(on marker: PlanMarker, geo: GeometryProxy, imgSize: CGSize, fit: CGFloat) {
        // Mirror the manual-scaling math used in `planContent`: the
        // marker lands at (effOX + x·effScale, effOY + y·effScale).
        // Solve for the `offset` (= pan) that puts that landing point at
        // the desired target screen position.
        let effScale = fit * scale
        let effW = imgSize.width  * effScale
        let effH = imgSize.height * effScale
        let baseEffOX = (geo.size.width  - effW) / 2
        let baseEffOY = (geo.size.height - effH) / 2
        let targetX = geo.size.width / 2
        let targetY = max(80, (geo.size.height - previewHeight) / 4)
        let newX = targetX - baseEffOX - marker.x * effScale
        let newY = targetY - baseEffOY - marker.y * effScale

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

    /// Navigate across whichever set the preview-bar is currently bound
    /// to — `.group` walks within the current photo's group, `.all`
    /// walks every located photo on the active plan in sequence order.
    /// Wraps at the ends.
    private func navigate(direction: Int) {
        guard let id = selectedPhotoID,
              let current = currentPhoto(for: id) else { return }
        let set = activeNavSet(for: current)
        guard !set.isEmpty else { return }
        let count = set.count
        let currentIdx = set.firstIndex(where: { $0.id == id }) ?? 0
        let nextIdx = ((currentIdx + direction) % count + count) % count
        let nextPhoto = set[nextIdx]
        selectedPhotoID = nextPhoto.id
        pendingRecenterID = nextPhoto.id
    }

    /// Every located photo on the *currently-active* plan, sorted by
    /// sequence number. Other plans' photos are excluded so the
    /// preview-bar swipe and bubble taps stay scoped to the plan the
    /// engineer is actually looking at.
    private func locatedPhotosOrdered() -> [Photo] {
        guard let project = store.project(withID: projectID) else { return [] }
        let activeID = project.floorPlan?.id
        return project.photos
            .filter { $0.planPixelX != nil && $0.planPixelY != nil && $0.floorPlanID == activeID }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    /// Multi-plan picker shown in the principal toolbar slot when the
    /// project has more than one plan. Selecting a plan updates the
    /// project's `activeFloorPlanID` and triggers a re-render against
    /// the new plan.
    @ViewBuilder
    private func planPickerMenu(project: Project) -> some View {
        Menu {
            Picker("Floor plan", selection: Binding(
                get: { project.floorPlan?.id ?? UUID() },
                set: { newID in
                    _ = store.setActiveFloorPlan(project, planID: newID)
                }
            )) {
                ForEach(project.floorPlans) { plan in
                    Text(plan.label).tag(plan.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(project.floorPlan?.label ?? "Plan")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
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

    /// Project-wide multiplier on bubble radius so 3+ digit photo
    /// numbers stay readable without per-bubble size variation. Looks
    /// at the highest sequence number in the project and scales every
    /// bubble (lead + tail) by the same amount.
    private func bubbleDigitScale(for project: Project) -> Double {
        let maxSeq = project.photos.map(\.sequenceNumber).max() ?? 0
        switch String(maxSeq).count {
        case 0, 1, 2: return 1.0
        case 3:       return 1.18
        default:      return 1.30
        }
    }

    private func buildMarkers(project: Project) -> [PlanMarker] {
        let activeID = project.floorPlan?.id
        var groups: [String: [Photo]] = [:]
        for photo in project.photos {
            // Only render bubbles for photos placed on the plan the
            // engineer is currently viewing — multi-plan projects show
            // each plan's bubbles in isolation.
            guard photo.floorPlanID == activeID,
                  photo.planPixelX != nil,
                  photo.planPixelY != nil else { continue }
            let key = photo.groupID?.uuidString ?? photo.id.uuidString
            groups[key, default: []].append(photo)
        }

        var out: [PlanMarker] = []
        // Iterate by sorted key so the resulting markers array has a
        // deterministic order across renders — important for the cluster
        // detection pass which is sensitive to consistent grouping.
        for key in groups.keys.sorted() {
            let members = groups[key]!
            let sorted = members.sorted { $0.sequenceNumber < $1.sequenceNumber }
            let primary = sorted.first(where: { $0.isPrimary }) ?? sorted.first!
            out.append(PlanMarker(
                id: primary.id,
                photo: primary,
                x: primary.planPixelX ?? 0,
                y: primary.planPixelY ?? 0,
                isPrimary: true,
                bearing: primary.headingDegrees,
                groupSize: members.count
            ))
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
    /// How many photos this bubble represents — 1 for ungrouped photos,
    /// N for grouped photos (the bubble is the group lead and the N-1
    /// remaining group members are not rendered separately). Renderers
    /// draw a black ring around the bubble when this is > 1 so the
    /// engineer knows the bubble stands for a group.
    let groupSize: Int
}

/// One displayed primary slot on the plan — either a single bubble or a
/// stack-badge representing N overlapping photos. `marker` is the lead
/// member (lowest sequence number) with its position replaced by the
/// cluster centroid so the badge renders dead-centre across the overlap
/// region. `stackPhotoIDs` carries every member's ID so a tap can hand
/// the full list off to BubbleStackSheet.
struct DisplayedPrimary: Identifiable {
    let id: UUID
    let marker: PlanMarker
    let stackPhotoIDs: [UUID]
    var stackCount: Int { stackPhotoIDs.count }
}

/// Sheet-presentation target — `Identifiable` so SwiftUI's
/// `.sheet(item:)` knows when to swap content if the engineer taps a
/// second stack while the first is still presented.
struct PlanStackTarget: Identifiable {
    let id: UUID            // lead photo's ID
    let photoIDs: [UUID]
}

struct ArrowShape: Shape {
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

struct ArrowHead: Shape {
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

/// Navigation set the preview bar's swipe / thumbnail strip is bound
/// to. `.group` only walks within the current photo's group (or just
/// the photo itself when ungrouped); `.all` walks every located photo
/// on the active plan in sequence-number order. Persisted via
/// @AppStorage so the engineer's preference survives across sessions.
enum PreviewNavMode: String { case group, all }

private struct PhotoPreviewBar: View {
    let photo: Photo
    /// Photos the engineer can navigate between — derived in
    /// PlanViewerView from `navMode` (group or all). The bar's index /
    /// total are computed off this set.
    let activeSet: [Photo]
    @Binding var navMode: PreviewNavMode
    let projectID: UUID
    let onSwipeNext: () -> Void
    let onSwipePrevious: () -> Void
    /// Invoked when the engineer taps a thumbnail in the strip — the
    /// host wires this to its own `selectedPhotoID` + recenter path.
    let onSelectPhoto: (UUID) -> Void
    /// Tap target for "open this photo in the project list" — used so
    /// the engineer can drop out of the plan viewer and land on the
    /// row in `ProjectDetailView` for tagging / move / delete actions.
    let onOpenInList: (UUID) -> Void
    let onDismiss: () -> Void

    @Environment(ProjectStore.self) private var store
    @State private var loadedImage: UIImage?
    @State private var loadState: LoadState = .loading

    private enum LoadState { case loading, loaded, missing }

    private var index: Int {
        activeSet.firstIndex(where: { $0.id == photo.id }) ?? 0
    }
    private var totalCount: Int { activeSet.count }

    var body: some View {
        VStack(spacing: 0) {
            // Group / All mode toggle. The default segmented Picker
            // renders its inactive segment with a dark-grey tint that
            // disappears against the bar's pure-black background, so
            // engineers can only see the active half. A custom
            // two-button toggle with explicit fill + text contrast for
            // both states makes both options visible at a glance.
            modeToggle
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color.black)

            // Horizontal thumbnail strip. Tap to jump; current photo
            // gets an accent-coloured stroke so its position is obvious
            // as the strip scrolls.
            thumbnailStrip
                .frame(height: 60)
                .background(Color.black)

            // Main photo area — unchanged from the original bar layout
            // except it now occupies the remaining vertical space
            // instead of the full bar height.
            mainPhotoArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .task(id: photo.id) {
            await loadCurrentPhoto()
        }
    }

    @ViewBuilder
    private var modeToggle: some View {
        HStack(spacing: 0) {
            ForEach([PreviewNavMode.group, PreviewNavMode.all], id: \.self) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        navMode = mode
                    }
                } label: {
                    Text(mode == .group ? "Group" : "All")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(navMode == mode ? Color.black : Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(navMode == mode ? Color.white : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.18))
        )
        .frame(width: 220)
    }

    @ViewBuilder
    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(activeSet, id: \.id) { p in
                        thumbnailView(for: p, isCurrent: p.id == photo.id)
                            .id(p.id)
                            .onTapGesture { onSelectPhoto(p.id) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .onChange(of: photo.id) { _, newID in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
            .onChange(of: navMode) { _, _ in
                // After a mode flip the active set changes; nudge the
                // current photo back into view in the new set.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(photo.id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnailView(for p: Photo, isCurrent: Bool) -> some View {
        let url = store.project(withID: projectID).flatMap { store.thumbnailURL(for: p, in: $0) }
        ZStack {
            Color.gray.opacity(0.3)
            CachedThumbnail(url: url, maxPixelSize: 132)
                .rotationEffect(.degrees(Double(p.previewRotation)))
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(isCurrent ? Color.accentColor : Color.white.opacity(0.15),
                         lineWidth: isCurrent ? 2 : 1)
        }
    }

    @ViewBuilder
    private var mainPhotoArea: some View {
        ZStack(alignment: .topTrailing) {
            Color.black

            switch loadState {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Downloading from iCloud…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            case .missing:
                ContentUnavailableView(
                    "Photo missing",
                    systemImage: "photo.badge.exclamationmark"
                )
                .foregroundStyle(.white)
            case .loaded:
                if let img = loadedImage {
                    // Rotation handling: a 90/270° rotation swaps the
                    // image's effective aspect, so a naive
                    // .rotationEffect on a .fit image would either
                    // overflow the container or shrink to a tiny strip.
                    // Size the inner frame to a transposed container
                    // (height × width) when quarter-turned, then rotate
                    // — the post-rotation bounding box ends up matching
                    // the container exactly.
                    GeometryReader { geo in
                        let quarterTurn = photo.previewRotation % 180 != 0
                        let w = quarterTurn ? geo.size.height : geo.size.width
                        let h = quarterTurn ? geo.size.width : geo.size.height
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: w, height: h)
                            .rotationEffect(.degrees(Double(photo.previewRotation)))
                            .position(x: geo.size.width / 2,
                                       y: geo.size.height / 2)
                    }
                    .id(photo.id)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2),
                                value: photo.previewRotation)
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

            HStack(spacing: 4) {
                Button {
                    onOpenInList(photo.id)
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.title2)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(8)
                }
                .accessibilityLabel("Open in project list")
                Button {
                    guard let project = store.project(withID: projectID) else { return }
                    _ = store.rotatePhotoPreview(project, photoID: photo.id)
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.title2)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding(8)
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

    private func loadCurrentPhoto() async {
        loadState = .loading
        loadedImage = nil
        guard let project = store.project(withID: projectID) else {
            loadState = .missing
            return
        }
        let url = store.imageURL(for: photo, in: project)
        if let data = await store.loadFileBytes(at: url),
           let img = UIImage(data: data) {
            loadedImage = img
            loadState = .loaded
        } else {
            loadState = .missing
        }
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
