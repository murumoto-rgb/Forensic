import SwiftUI

/// Sheet for placing a single existing photo on the floor plan, or moving
/// one that was already located. Pre-fills the pin and direction from the
/// photo's current location when one exists.
struct RelocateSheet: View {
    let projectID: UUID
    let photoID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var step: LocateStep = .position
    @State private var planPoint: CGPoint?
    @State private var heading: Double?
    @State private var error: String?
    @State private var didPrefill = false

    @State private var planImage: UIImage?
    @State private var loadState: LoadState = .loading
    private enum LoadState { case loading, loaded, missing }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                instructionBar
                planArea
                actionBar
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                if step == .direction && !didPrefillNeeded {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Back") {
                            planPoint = nil
                            heading = nil
                            step = .position
                        }
                    }
                }
            }
            .task {
                await loadPlan()
            }
        }
        .interactiveDismissDisabled(true)
    }

    /// True only if we already pre-filled from an existing location — then
    /// the "Back" affordance is hidden because the user expects edit mode.
    private var didPrefillNeeded: Bool {
        photo?.positionSource != PositionSource.none
    }

    @ViewBuilder
    private var planArea: some View {
        switch loadState {
        case .loading:
            ZStack {
                Color.black
                VStack(spacing: 8) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Downloading plan from iCloud…")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxHeight: .infinity)
        case .loaded:
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
                missing
            }
        case .missing:
            missing
        }
    }

    @ViewBuilder
    private var missing: some View {
        ContentUnavailableView(
            "Plan unavailable",
            systemImage: "exclamationmark.triangle"
        )
        .frame(maxHeight: .infinity)
    }

    private var navTitle: String {
        if let photo, photo.positionSource != .none {
            return "Change Location"
        }
        return "Locate Photo"
    }

    private var instructionBar: some View {
        HStack {
            Text(instructionText).font(.callout)
            Spacer()
            if let photo {
                Text("#\(photo.sequenceNumber)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var instructionText: String {
        switch step {
        case .position: return "Tap on the plan to set the photo location."
        case .direction: return "Drag from the pin in the direction the camera was facing."
        }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let photo, photo.positionSource != .none {
                    Button(role: .destructive) {
                        clearLocation()
                    } label: {
                        Label("Clear", systemImage: "location.slash")
                    }
                    .controlSize(.regular)
                }
                Spacer()
                Menu {
                    Button("Skip Direction (no arrow)") {
                        save(skipDirection: true)
                    }
                    .disabled(planPoint == nil)
                } label: {
                    Label("Skip…", systemImage: "forward")
                }
                .disabled(planPoint == nil)

                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(planPoint == nil)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Data lookup

    private var photo: Photo? {
        store.project(withID: projectID)?.photos.first(where: { $0.id == photoID })
    }

    private func loadPlan() async {
        loadState = .loading
        guard let proj = store.project(withID: projectID),
              proj.floorPlan != nil,
              let url = store.floorPlanURL(for: proj) else {
            loadState = .missing
            return
        }
        if let data = await store.loadFileBytes(at: url),
           let img = UIImage(data: data) {
            planImage = img
            loadState = .loaded
            if !didPrefill {
                prefillFromExisting()
                didPrefill = true
            }
        } else {
            loadState = .missing
        }
    }

    private func prefillFromExisting() {
        guard let photo, let px = photo.planPixelX, let py = photo.planPixelY else { return }
        planPoint = CGPoint(x: px, y: py)
        if let h = photo.headingDegrees {
            heading = h
        }
        step = .direction
    }

    // MARK: - Actions

    private func save(skipDirection: Bool = false) {
        guard let project = store.project(withID: projectID),
              project.floorPlan != nil,
              let pt = planPoint else { return }
        let useHeading = skipDirection ? nil : heading
        store.setPhotoLocation(
            project,
            photoID: photoID,
            planPixelX: Double(pt.x),
            planPixelY: Double(pt.y),
            headingDegrees: useHeading
        )
        dismiss()
    }

    private func clearLocation() {
        guard let project = store.project(withID: projectID) else { return }
        store.clearPhotoLocation(project, photoID: photoID)
        dismiss()
    }
}
