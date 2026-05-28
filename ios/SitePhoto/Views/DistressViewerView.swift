import SwiftUI

/// Editor for `DistressMark`s placed on the active floor plan. Mirrors
/// `PlanViewerView`'s coordinate transform (fit-to-screen + pinch zoom
/// + pan) but renders a separate annotation layer that doesn't share
/// state with the photo pins. The four supported distress kinds are
/// surfaced as a top toolbar: tap-to-place for the three dot kinds, and
/// finger-drag-to-draw a free-style pencil stroke for crack-in-floor.
struct DistressViewerView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Currently-armed distress kind. Tap on the plan drops a mark of
    /// this kind (or, for `crackFloor`, begins a drag-to-draw stroke).
    /// `nil` = inspection mode: taps select existing marks instead of
    /// placing new ones.
    @State private var armedKind: DistressKind?
    /// id of the currently-selected mark. Selection ring renders around
    /// the matching mark and unlocks the per-mark delete + move actions.
    @State private var selectedID: UUID?

    @State private var planImage: UIImage?
    @State private var planLoadState: PlanLoadState = .loading

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// In-progress free-style stroke for `crackFloor` placements. Points
    /// are in plan-image pixel space; commits to the model on touch-up.
    @State private var draftStroke: [CGPoint] = []
    /// In-progress drag offset for moving the selected mark. Applied
    /// visually during the drag and baked into the model on release.
    @State private var dragOffset: CGPoint?
    @State private var dragOriginalPoints: [CGPoint]?

    private enum PlanLoadState { case loading, loaded, missing }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                planArea
            }
            .navigationTitle("Distress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let id = selectedID,
                       let plan = activePlan,
                       plan.distress.contains(where: { $0.id == id }) {
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) { kindToolbar }
            .task(id: planTaskID) {
                await loadPlanImage()
            }
        }
    }

    // MARK: - Plan content

    @ViewBuilder
    private var planArea: some View {
        if let project = store.project(withID: projectID),
           let plan = project.floorPlan {
            switch planLoadState {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            case .missing:
                ContentUnavailableView(
                    "Plan unavailable",
                    systemImage: "doc.badge.ellipsis",
                    description: Text("The active plan's image could not be loaded.")
                )
                .foregroundStyle(.white)
            case .loaded:
                if let img = planImage {
                    GeometryReader { geo in
                        planContent(geo: geo,
                                     project: project,
                                     plan: plan,
                                     image: img)
                    }
                    .clipped()
                } else {
                    ContentUnavailableView(
                        "Plan unavailable",
                        systemImage: "doc.badge.ellipsis"
                    )
                    .foregroundStyle(.white)
                }
            }
        } else {
            ContentUnavailableView(
                "No active plan",
                systemImage: "doc.viewfinder",
                description: Text("Set an active floor plan on the project screen first.")
            )
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func planContent(geo: GeometryProxy,
                              project: Project,
                              plan: FloorPlan,
                              image: UIImage) -> some View {
        let imgSize = image.size
        let fit = min(geo.size.width / max(1, imgSize.width),
                      geo.size.height / max(1, imgSize.height))
        let effScale = fit * scale
        let effW = imgSize.width * effScale
        let effH = imgSize.height * effScale
        let effOX = (geo.size.width  - effW) / 2 + offset.width
        let effOY = (geo.size.height - effH) / 2 + offset.height

        // Convert a tap location (canvas coords) to plan-image pixels.
        let canvasToImage: (CGPoint) -> CGPoint = { p in
            CGPoint(x: (p.x - effOX) / effScale,
                    y: (p.y - effOY) / effScale)
        }
        // Inverse — used for drawing overlays.
        let imageToCanvas: (CGPoint) -> CGPoint = { p in
            CGPoint(x: effOX + p.x * effScale,
                    y: effOY + p.y * effScale)
        }

        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: effW, height: effH)
                .offset(x: effOX, y: effOY)

            // Committed marks (with live drag offset baked in for the
            // currently-moving one).
            ForEach(plan.distress) { mark in
                renderMark(mark, imageToCanvas: imageToCanvas)
            }

            // Live free-style stroke as the engineer draws.
            if armedKind == .crackFloor, draftStroke.count >= 2 {
                strokePath(draftStroke.map(imageToCanvas))
                    .stroke(DistressKind.crackFloor.color,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            // Pinch-to-zoom runs simultaneously with the drag-based
            // gesture below.
            MagnificationGesture()
                .onChanged { value in
                    scale = max(0.5, min(8, lastScale * value))
                }
                .onEnded { _ in
                    lastScale = scale
                }
        )
        .gesture(
            // Single drag handles four modes:
            //  1. armed == .crackFloor: samples points for a free-style
            //     stroke; commits the stroke on touch-up.
            //  2. selected mark + drag started on it: translate the
            //     mark; commit the new position on touch-up.
            //  3. armed dot kind, no existing mark hit, no movement:
            //     drop a new dot at the tap point on touch-up.
            //  4. inspection mode (armed == nil, no mark drag):
            //     pan the plan; on a near-zero drag, treat as tap and
            //     select/deselect.
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    handleDragChange(value, plan: plan,
                                      canvasToImage: canvasToImage)
                }
                .onEnded { value in
                    handleDragEnd(value, project: project, plan: plan,
                                   canvasToImage: canvasToImage)
                }
        )
    }

    // MARK: - Mark rendering

    @ViewBuilder
    private func renderMark(_ mark: DistressMark,
                             imageToCanvas: (CGPoint) -> CGPoint) -> some View {
        let isSelected = mark.id == selectedID
        // If this mark is being actively dragged, render at the
        // dragOffset-shifted position; otherwise render in place.
        let visiblePoints = displacedPoints(for: mark)
        if mark.kind.isStroke {
            let canvasPts = visiblePoints.map(imageToCanvas)
            strokePath(canvasPts)
                .stroke(mark.kind.color,
                        style: StrokeStyle(lineWidth: isSelected ? 5 : 3,
                                            lineCap: .round, lineJoin: .round))
                .shadow(color: isSelected ? .yellow : .clear, radius: 4)
        } else if let first = visiblePoints.first {
            let center = imageToCanvas(first)
            ZStack {
                Circle()
                    .fill(mark.kind.color)
                    .frame(width: 22, height: 22)
                Circle()
                    .stroke(isSelected ? Color.yellow : Color.white,
                            lineWidth: isSelected ? 3 : 2)
                    .frame(width: 22, height: 22)
            }
            .position(center)
        }
    }

    private func displacedPoints(for mark: DistressMark) -> [CGPoint] {
        guard mark.id == selectedID,
              let delta = dragOffset,
              let original = dragOriginalPoints else {
            return mark.points
        }
        return original.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }

    private func strokePath(_ points: [CGPoint]) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for pt in points.dropFirst() { p.addLine(to: pt) }
        return p
    }

    // MARK: - Gesture handling

    private func handleDragChange(_ value: DragGesture.Value,
                                   plan: FloorPlan,
                                   canvasToImage: (CGPoint) -> CGPoint) {
        // Free-style stroke placement.
        if armedKind == .crackFloor {
            let pt = canvasToImage(value.location)
            if draftStroke.last.map({ hypot($0.x - pt.x, $0.y - pt.y) > 1 }) ?? true {
                draftStroke.append(pt)
            }
            return
        }
        // Move the selected mark when the drag starts on top of it.
        if let id = selectedID,
           let mark = plan.distress.first(where: { $0.id == id }) {
            let startInImage = canvasToImage(value.startLocation)
            if dragOriginalPoints == nil,
               hitTest(startInImage, against: mark) {
                dragOriginalPoints = mark.points
            }
            if dragOriginalPoints != nil {
                let nowInImage = canvasToImage(value.location)
                let startCanvasInImage = canvasToImage(value.startLocation)
                dragOffset = CGPoint(x: nowInImage.x - startCanvasInImage.x,
                                     y: nowInImage.y - startCanvasInImage.y)
                return
            }
        }
        // Inspection mode → pan. We only pan if no kind is armed AND
        // the drag isn't translating an existing mark (handled above).
        if armedKind == nil {
            offset = CGSize(width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height)
        }
    }

    private func handleDragEnd(_ value: DragGesture.Value,
                                project: Project,
                                plan: FloorPlan,
                                canvasToImage: (CGPoint) -> CGPoint) {
        // Commit the free-style stroke.
        if armedKind == .crackFloor {
            let pts = draftStroke
            draftStroke = []
            if pts.count >= 2 {
                let mark = DistressMark(kind: .crackFloor, points: pts)
                store.addDistress(project, planID: plan.id, mark: mark)
                selectedID = mark.id
            }
            return
        }
        // Commit a drag-move on the selected mark.
        if let delta = dragOffset,
           let original = dragOriginalPoints,
           let id = selectedID,
           let mark = plan.distress.first(where: { $0.id == id }) {
            let moved = DistressMark(
                id: mark.id,
                kind: mark.kind,
                points: original.map { CGPoint(x: $0.x + delta.x,
                                                y: $0.y + delta.y) },
                note: mark.note,
                createdAt: mark.createdAt
            )
            dragOffset = nil
            dragOriginalPoints = nil
            if hypot(delta.x, delta.y) > 0.5 {
                store.updateDistress(project, planID: plan.id, mark: moved)
                return
            }
        }
        dragOffset = nil
        dragOriginalPoints = nil

        // Inspection-mode pan: commit the new offset and don't treat as
        // a tap.
        let distance = hypot(value.translation.width, value.translation.height)
        if armedKind == nil, distance >= 5 {
            lastOffset = offset
            return
        }
        // Treat a near-zero-distance drag as a tap.
        guard distance < 5 else { return }
        let tap = canvasToImage(value.location)
        // Hit-test existing marks first (top-most wins so smaller, more
        // recently placed marks aren't shadowed by older ones).
        if let hit = plan.distress.reversed().first(where: { hitTest(tap, against: $0) }) {
            selectedID = hit.id
            return
        }
        // No existing mark hit — place a new dot if a dot kind is armed.
        if let kind = armedKind, !kind.isStroke {
            let mark = DistressMark(kind: kind, points: [tap])
            store.addDistress(project, planID: plan.id, mark: mark)
            selectedID = mark.id
        } else {
            // Empty space tap in inspection mode — clear selection.
            selectedID = nil
        }
    }

    /// Hit-test a tap in plan-image space against a mark. Dots use a
    /// generous radius (so the user doesn't have to land precisely on
    /// the 22-pt circle); strokes hit when the tap is within ~10
    /// plan-pixels of any segment of the polyline.
    private func hitTest(_ point: CGPoint, against mark: DistressMark) -> Bool {
        let pts = displacedPoints(for: mark)
        if mark.kind.isStroke {
            return pts.contains(where: { hypot($0.x - point.x, $0.y - point.y) < 12 })
        }
        guard let first = pts.first else { return false }
        return hypot(first.x - point.x, first.y - point.y) < 24
    }

    // MARK: - Top toolbar

    private var kindToolbar: some View {
        HStack(spacing: 8) {
            ForEach(DistressKind.allCases, id: \.self) { kind in
                Button {
                    armedKind = (armedKind == kind ? nil : kind)
                    selectedID = nil
                    draftStroke = []
                } label: {
                    VStack(spacing: 4) {
                        if kind.isStroke {
                            Image(systemName: "scribble.variable")
                                .font(.title3)
                        } else {
                            Circle()
                                .fill(kind.color)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(.white, lineWidth: 1))
                        }
                        Text(kind.shortLabel)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(armedKind == kind
                                  ? Color.accentColor.opacity(0.85)
                                  : Color.black.opacity(0.55))
                    )
                    .foregroundStyle(armedKind == kind ? Color.white : Color.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial.opacity(0.4))
    }

    // MARK: - Helpers

    private var activePlan: FloorPlan? {
        store.project(withID: projectID)?.floorPlan
    }

    /// Recompute the plan image when the active plan changes.
    private var planTaskID: String {
        guard let plan = activePlan else { return "none" }
        return "\(plan.id.uuidString)/\(plan.imageFilename)"
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

    private func deleteSelected() {
        guard let id = selectedID,
              let project = store.project(withID: projectID),
              let plan = project.floorPlan else { return }
        store.removeDistress(project, planID: plan.id, markID: id)
        selectedID = nil
    }
}

extension DistressKind {
    /// Color used to render this kind on the plan + in the PDF legend.
    /// Chosen so the three dots are clearly distinguishable at small
    /// sizes and the crack stroke reads as a "warning" in red.
    var color: Color {
        switch self {
        case .outOfPlumbDoor:    return .yellow
        case .doorNotLatching:   return .orange
        case .crackGradeBeam:    return .purple
        case .crackFloor:        return .red
        }
    }
}
