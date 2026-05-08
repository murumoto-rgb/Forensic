import SwiftUI

/// Sheet for placing a single existing photo on the floor plan, or moving
/// one that was already located. The plan fills the top portion and
/// supports zoom + pan; a preview of the photo being located fills the
/// bottom portion so the user can see *what* they're placing while they
/// drop the pin.
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
    @State private var showingGroupPicker = false

    @State private var planImage: UIImage?
    @State private var planLoadState: LoadState = .loading
    @State private var photoImage: UIImage?
    @State private var photoLoadState: LoadState = .loading
    private enum LoadState { case loading, loaded, missing }

    /// Photo preview's vertical share of the screen.
    private let photoPreviewHeight: CGFloat = 220

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                instructionBar
                planArea
                    .frame(maxHeight: .infinity)
                photoPreview
                    .frame(height: photoPreviewHeight)
                actionBar
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingGroupPicker = true
                    } label: {
                        Label("Group", systemImage: "rectangle.stack")
                    }
                }
            }
            .task {
                await loadPlan()
            }
            .task(id: photoID) {
                await loadPhoto()
            }
            .sheet(isPresented: $showingGroupPicker) {
                PhotoGroupPickerSheet(
                    projectID: projectID,
                    excludingPhotoIDs: [photoID],
                    fromPhotoID: photoID,
                    pendingCount: 0,
                    onSelect: { leadID in
                        attachToGroup(leadID: leadID)
                    }
                )
                .environment(store)
            }
        }
        .interactiveDismissDisabled(true)
    }

    @ViewBuilder
    private var planArea: some View {
        switch planLoadState {
        case .loading:
            ZStack {
                Color.black
                VStack(spacing: 8) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Downloading plan from iCloud…")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        case .loaded:
            if let img = planImage {
                PlanLocateCanvas(
                    image: img,
                    planPoint: $planPoint,
                    heading: $heading,
                    step: $step
                )
                .background(.black)
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

    /// Photo preview at the bottom — shows what's being located.
    @ViewBuilder
    private var photoPreview: some View {
        ZStack {
            Color.black

            switch photoLoadState {
            case .loading:
                VStack(spacing: 6) {
                    ProgressView().controlSize(.regular).tint(.white)
                    Text("Loading photo…")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            case .missing:
                ContentUnavailableView(
                    "Photo missing",
                    systemImage: "photo.badge.exclamationmark"
                )
                .foregroundStyle(.white)
            case .loaded:
                if let img = photoImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if let photo {
                VStack {
                    HStack {
                        Text("#\(photo.sequenceNumber)")
                            .font(.headline.monospaced())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.6),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
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
        case .position: return "Pinch to zoom, drag to pan, tap to place pin."
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
            if !didPrefill {
                prefillFromExisting()
                didPrefill = true
            }
        } else {
            planLoadState = .missing
        }
    }

    private func loadPhoto() async {
        photoLoadState = .loading
        photoImage = nil
        guard let project = store.project(withID: projectID),
              let photo = project.photos.first(where: { $0.id == photoID }) else {
            photoLoadState = .missing
            return
        }
        let url = store.imageURL(for: photo, in: project)
        if let data = await store.loadFileBytes(at: url),
           let img = UIImage(data: data) {
            photoImage = img
            photoLoadState = .loaded
        } else {
            photoLoadState = .missing
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

    private func attachToGroup(leadID: UUID) {
        guard let project = store.project(withID: projectID) else { return }
        store.attachToGroup(project, photoID: photoID, leadPhotoID: leadID)
        dismiss()
    }
}
