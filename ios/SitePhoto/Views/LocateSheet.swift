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
    /// Optional caption the engineer dictates / types while the photo is
    /// fresh. Persisted on the lead (primary) photo's `userCaption` after
    /// `save()` succeeds so it shows up later in the tag editor and in
    /// exports without a second trip back to the photo.
    @State private var captionDraft: String = ""
    @State private var captionDictation = VoiceDictationController()
    @FocusState private var captionFocused: Bool
    /// When the engineer taps an existing master/independent bubble on
    /// the canvas, this holds that photo's ID so the alert below can
    /// prompt before grouping. nil = no group-confirm pending.
    @State private var groupConfirmTarget: UUID?
    @State private var groupConfirmSequence: Int = 0
    @AppStorage("sitephoto.bubbleScale") private var bubbleScale: Double = 1.5

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                instructionBar
                captionBar

                if let img = planImage {
                    PlanLocateCanvas(
                        image: img,
                        planPoint: $planPoint,
                        heading: $heading,
                        step: $step,
                        existingBubbles: existingBubbles,
                        bubbleScale: CGFloat(bubbleScale),
                        onBubbleTap: { photoID in
                            handleExistingBubbleTap(photoID)
                        }
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
                if let project = store.project(withID: projectID),
                   project.floorPlans.count > 1 {
                    ToolbarItem(placement: .principal) {
                        planPickerMenu(project: project)
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
            .alert(
                "Group with #\(groupConfirmSequence)?",
                isPresented: Binding(
                    get: { groupConfirmTarget != nil },
                    set: { if !$0 { groupConfirmTarget = nil } }
                )
            ) {
                Button("Group") {
                    if let leadID = groupConfirmTarget {
                        saveAttachedToGroup(leadID: leadID)
                    }
                    groupConfirmTarget = nil
                }
                Button("Cancel", role: .cancel) {
                    groupConfirmTarget = nil
                }
            } message: {
                Text("The new photo will share #\(groupConfirmSequence)'s location and join its group as a stacked tail bubble. Tap an empty spot to place a new pin instead.")
            }
        }
        .interactiveDismissDisabled(true)
    }

    /// Photos already placed on the currently-active plan, surfaced to
    /// the canvas so the engineer can see where they're working
    /// against — and tap a master/independent bubble to group rather
    /// than dropping a new pin.
    private var existingBubbles: [LocateBubble] {
        guard let project = store.project(withID: projectID),
              let activeID = project.floorPlan?.id else { return [] }
        return project.photos.compactMap { p -> LocateBubble? in
            guard p.floorPlanID == activeID,
                  let px = p.planPixelX,
                  let py = p.planPixelY else { return nil }
            // "Master / independent" — a tappable bubble for grouping:
            // either a group lead (`isPrimary && groupID != nil`), or a
            // standalone photo with no group at all.
            let isTail = p.groupID != nil && !p.isPrimary
            return LocateBubble(
                id: p.id,
                position: CGPoint(x: px, y: py),
                isTappable: !isTail,
                bearing: p.headingDegrees,
                sequenceNumber: p.sequenceNumber
            )
        }
    }

    /// Called when the engineer taps an existing tappable bubble.
    /// Records the target so the confirmation alert fires; the actual
    /// save runs from the alert's Group button.
    private func handleExistingBubbleTap(_ photoID: UUID) {
        guard let project = store.project(withID: projectID),
              let photo = project.photos.first(where: { $0.id == photoID }) else { return }
        groupConfirmSequence = photo.sequenceNumber
        groupConfirmTarget = photoID
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

    /// Quick caption field + mic — captures the engineer's observation
    /// while the photo is fresh and before the pin is placed. Saved onto
    /// the lead photo's `userCaption` when the batch is committed.
    @ViewBuilder
    private var captionBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                TextField("Optional caption (or use mic →)",
                          text: $captionDraft, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($captionFocused)
                    .submitLabel(.done)
                    .onSubmit { captionFocused = false }
                Button {
                    if captionDictation.isRecording {
                        captionDictation.stop()
                    } else {
                        Task { await captionDictation.start(seed: captionDraft) }
                    }
                } label: {
                    Image(systemName: captionDictation.isRecording
                          ? "stop.circle.fill" : "mic.circle")
                        .font(.title2)
                        .foregroundStyle(captionDictation.isRecording
                                         ? Color.red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(captionDictation.isRecording
                                    ? "Stop dictation"
                                    : "Dictate caption")
            }
            if let err = captionDictation.error {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .onChange(of: captionDictation.transcript) { _, new in
            guard captionDictation.isRecording else { return }
            captionDraft = new
        }
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

    /// Plan picker shown in the principal toolbar slot when the
    /// project has more than one plan. Selecting a plan updates the
    /// project's `activeFloorPlanID` so the canvas re-renders against
    /// the new image and `save()` writes the placement against the
    /// newly-active plan. Resets `planPoint`/`heading` because a tap
    /// from the previous image's coord space wouldn't align on the
    /// new image.
    @ViewBuilder
    private func planPickerMenu(project: Project) -> some View {
        Menu {
            Picker("Floor plan", selection: Binding(
                get: { project.floorPlan?.id ?? UUID() },
                set: { newID in
                    _ = store.setActiveFloorPlan(project, planID: newID)
                    planPoint = nil
                    heading = nil
                    step = .position
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

    // MARK: - Actions

    private func discard() {
        captionDictation.stop()
        pendingPhotos = []
        planPoint = nil
        heading = nil
        step = .position
        captionDraft = ""
        dismiss()
    }

    private func save(skipLocation: Bool = false, skipDirection: Bool = false) {
        guard let project = store.project(withID: projectID) else { return }
        guard let plan = project.floorPlan else { return }
        guard !pendingPhotos.isEmpty else { dismiss(); return }

        captionDictation.stop()

        let useLoc = !skipLocation && planPoint != nil
        let useHeading = useLoc && !skipDirection && heading != nil
        let groupID: UUID? = pendingPhotos.count > 1 ? UUID() : nil
        let pendingCount = pendingPhotos.count

        var current = project
        for (i, captured) in pendingPhotos.enumerated() {
            var photoLoc: ProjectStore.PhotoLocation?
            if useLoc, let pt = planPoint {
                photoLoc = ProjectStore.PhotoLocation(
                    floorPlanID: plan.id,
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

        applyCaptionToLeadPhoto(in: &current, newlyAddedCount: pendingCount)

        pendingPhotos = []
        planPoint = nil
        heading = nil
        step = .position
        captionDraft = ""
        dismiss()
    }

    /// Find the first photo of the just-committed batch (the lead, marked
    /// `isPrimary` in the location helper above) and write the caption
    /// draft to its `userCaption`. Newly-added photos are appended to the
    /// end of `project.photos`, so the lead sits at index
    /// `count - newlyAddedCount`. Falls back to a search by isPrimary if
    /// the index is somehow out of range.
    private func applyCaptionToLeadPhoto(in project: inout Project,
                                          newlyAddedCount: Int) {
        let trimmed = captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, newlyAddedCount > 0 else { return }
        let leadIndex = project.photos.count - newlyAddedCount
        guard leadIndex >= 0, leadIndex < project.photos.count else { return }
        let leadID = project.photos[leadIndex].id
        project = store.setUserCaption(project, photoID: leadID, trimmed)
    }

    /// Save every pending photo at the chosen lead's plan position, joining
    /// the lead's group so they render as stack tails.
    private func saveAttachedToGroup(leadID: UUID) {
        guard var current = store.project(withID: projectID),
              let leadIdx = current.photos.firstIndex(where: { $0.id == leadID }),
              let lpx = current.photos[leadIdx].planPixelX,
              let lpy = current.photos[leadIdx].planPixelY,
              !pendingPhotos.isEmpty else {
            dismiss()
            return
        }
        // Use the LEAD's plan, not the project's active plan — when
        // grouping with a photo on a different floor than the one
        // currently selected here, the new captures need to land on
        // the lead's plan with the lead's calibration.
        let leadPlanID = current.photos[leadIdx].floorPlanID
        guard let plan = leadPlanID.flatMap({ current.floorPlan(id: $0) })
                ?? current.floorPlan else {
            dismiss()
            return
        }

        captionDictation.stop()
        // For the attach-to-existing flow, the dictated caption applies to
        // the existing lead photo (since the new pendings are tails). Skip
        // when the lead already has its own caption to avoid clobbering.
        let trimmedCaption = captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldApplyCaption = !trimmedCaption.isEmpty
            && (current.photos[leadIdx].userCaption?.isEmpty ?? true)

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
                floorPlanID: plan.id,
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

        if shouldApplyCaption {
            current = store.setUserCaption(current,
                                            photoID: leadID,
                                            trimmedCaption)
        }

        pendingPhotos = []
        planPoint = nil
        heading = nil
        step = .position
        captionDraft = ""
        dismiss()
    }
}

// MARK: - Plan canvas

/// One previously-placed photo on the plan, surfaced to the locate
/// canvas so the engineer can see where they're working against and
/// optionally tap an existing master/independent to group with it.
struct LocateBubble: Identifiable {
    let id: UUID            // photo ID
    let position: CGPoint   // image-pixel space
    /// Group masters + independent photos — tapping these prompts the
    /// engineer to group. Tail bubbles render but pass-through to the
    /// normal pin-placement so they aren't accidentally "selected."
    let isTappable: Bool
    let bearing: Double?
    let sequenceNumber: Int
}

struct PlanLocateCanvas: View {
    let image: UIImage
    @Binding var planPoint: CGPoint?
    @Binding var heading: Double?
    @Binding var step: LocateStep
    /// Existing photos to render on the canvas as static reference
    /// bubbles. `RelocateSheet` and any other caller that doesn't
    /// want them just leaves this at its default empty array.
    var existingBubbles: [LocateBubble] = []
    var bubbleScale: CGFloat = 1.5
    /// Fires when the engineer taps a tappable existing bubble.
    /// Default is a no-op so callers without grouping behaviour stay
    /// unchanged.
    var onBubbleTap: (UUID) -> Void = { _ in }

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

                // Existing bubbles + their direction arrows. Rendered
                // BELOW the new pin so the active pin always wins
                // visually. Tail bubbles get the smaller radius; only
                // masters/independents carry an arrow.
                let digitScale = bubbleDigitScale(existingBubbles)
                ForEach(existingBubbles) { bubble in
                    let center = CGPoint(
                        x: effOX + bubble.position.x * effScale,
                        y: effOY + bubble.position.y * effScale
                    )
                    // Bubble radius scales with zoom so existing
                    // markers keep a fixed plan-pixel footprint as the
                    // user pinches in/out — bigger when zoomed in,
                    // smaller when zoomed out. Matches PlanViewerView
                    // / PhotoGroupPickerSheet.
                    let baseRadius: CGFloat = ((bubble.isTappable
                        ? 18 * bubbleScale
                        : 13 * bubbleScale) * digitScale) * zoom
                    if let h = bubble.bearing, bubble.isTappable {
                        existingBubbleArrow(at: center,
                                             headingDegrees: h,
                                             length: baseRadius + 36 * bubbleScale * zoom)
                    }
                    existingBubble(seq: bubble.sequenceNumber,
                                    radius: baseRadius,
                                    at: center,
                                    tappable: bubble.isTappable)
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
            // Tap on the outer ZStack: the gesture's .local coord space is
            // the ZStack's frame (geo-relative), so we subtract the image's
            // current effective origin and divide by the effective scale to
            // get an image pixel. This is the same pattern that worked
            // before zoom/pan was added — and now that .scaleEffect is gone
            // there's no transform between gesture and the outer view, so
            // it works again at any zoom level.
            .onTapGesture(coordinateSpace: .local) { tap in
                let inImage = CGPoint(
                    x: (tap.x - effOX) / effScale,
                    y: (tap.y - effOY) / effScale
                )
                guard inImage.x >= 0, inImage.x <= imgSize.width,
                      inImage.y >= 0, inImage.y <= imgSize.height else { return }
                // Hit-test existing tappable bubbles only while we're
                // still positioning the new pin. Once a pin has been
                // dropped (step == .direction), bubble taps are
                // ignored so the engineer can refine direction without
                // accidentally triggering a group prompt.
                if step == .position {
                    // Match the bubble's visible radius (which scales
                    // with zoom) plus a small fixed-pt slack so the
                    // tap zone follows the bubble as the user pinches.
                    let hitRadiusPt: CGFloat = 22 * bubbleScale * zoom + 8
                    let hitRadiusImg = hitRadiusPt / effScale
                    if let hit = nearestTappableBubble(to: inImage,
                                                         within: hitRadiusImg) {
                        onBubbleTap(hit.id)
                        return
                    }
                }
                planPoint = inImage
                if step == .position { step = .direction }
            }
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

    /// Closest tappable bubble whose center is within `radius`
    /// image-pixels of `point`. Returns nil when nothing's in range —
    /// the caller then falls through to the place-pin path.
    /// Match `PlanViewerView.bubbleDigitScale` — uniformly larger
    /// bubbles when the project's highest sequence number has 3+
    /// digits so the white text inside stays crisp at small zooms.
    /// Uses the max sequence number across the bubbles we're about to
    /// render rather than the project at large; functionally
    /// equivalent because `existingBubbles` already covers every
    /// placed photo on the active plan.
    private func bubbleDigitScale(_ bubbles: [LocateBubble]) -> CGFloat {
        let maxSeq = bubbles.map(\.sequenceNumber).max() ?? 0
        switch String(maxSeq).count {
        case 0, 1, 2: return 1.0
        case 3:       return 1.18
        default:      return 1.30
        }
    }

    private func nearestTappableBubble(to point: CGPoint,
                                         within radius: CGFloat) -> LocateBubble? {
        var best: (bubble: LocateBubble, dist: CGFloat)?
        for b in existingBubbles where b.isTappable {
            let dx = b.position.x - point.x
            let dy = b.position.y - point.y
            let d = sqrt(dx * dx + dy * dy)
            if d <= radius, best == nil || d < best!.dist {
                best = (b, d)
            }
        }
        return best?.bubble
    }

    /// Filled bubble drawn for an already-placed photo. Slightly
    /// dimmer than the active pin so the pin still reads as the
    /// "selected" element; thicker border for tappable bubbles so the
    /// engineer can see at a glance which ones invite a group action.
    /// Canvas-rendered so the digit text stays crisp at every zoom
    /// level (SwiftUI Text + .minimumScaleFactor blurs at fractional
    /// point sizes and during transform passes).
    @ViewBuilder
    private func existingBubble(seq: Int,
                                  radius: CGFloat,
                                  at point: CGPoint,
                                  tappable: Bool) -> some View {
        let fillOpacity: Double = tappable ? 0.92 : 0.7
        let strokeOpacity: Double = tappable ? 0.9 : 0.55
        let strokeWidth: CGFloat = tappable ? 2 : 1
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Color.green.opacity(fillOpacity))
            )
            // Inset the stroke path by half its line width so the
            // stroke renders fully inside the bubble (matches the old
            // SwiftUI Circle().stroke behaviour, which centers on the
            // path).
            let strokeRect = rect.insetBy(dx: strokeWidth / 2,
                                             dy: strokeWidth / 2)
            context.stroke(
                Path(ellipseIn: strokeRect),
                with: .color(Color.white.opacity(strokeOpacity)),
                lineWidth: strokeWidth
            )
            // 3pt floor matches PlanViewerView so tiny bubbles still
            // render legibly when bubbleScale is at the lower bound.
            // LocateSheet doesn't draw a group band, so no effR shrink.
            let maxSize = max(3, floor(radius * 1.05))
            let str = "\(seq)"
            var fontSize = maxSize
            var resolved = context.resolve(
                Text(str)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white)
            )
            let measured = resolved.measure(in: size)
            let widthCap = radius * 1.75
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
        .position(point)
    }

    @ViewBuilder
    private func existingBubbleArrow(at pin: CGPoint,
                                       headingDegrees: Double,
                                       length: CGFloat) -> some View {
        let angRad = (headingDegrees - 90) * .pi / 180
        let tip = CGPoint(
            x: pin.x + cos(angRad) * length,
            y: pin.y + sin(angRad) * length
        )
        Path { p in
            p.move(to: pin)
            p.addLine(to: tip)
        }
        .stroke(Color.green.opacity(0.9),
                 style: StrokeStyle(lineWidth: 3, lineCap: .round))

        Path { p in
            let back = angRad + .pi
            let baseR: CGFloat = 12
            let leftX = tip.x + cos(back + 0.42) * baseR
            let leftY = tip.y + sin(back + 0.42) * baseR
            let rightX = tip.x + cos(back - 0.42) * baseR
            let rightY = tip.y + sin(back - 0.42) * baseR
            p.move(to: tip)
            p.addLine(to: CGPoint(x: leftX, y: leftY))
            p.addLine(to: CGPoint(x: rightX, y: rightY))
            p.closeSubpath()
        }
        .fill(Color.green.opacity(0.9))
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
