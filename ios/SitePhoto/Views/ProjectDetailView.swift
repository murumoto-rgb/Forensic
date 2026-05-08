import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(LocationService.self) private var location
    let projectID: UUID

    @State private var sessionWorking = false
    @State private var addressLookupRunning = false
    @State private var sessionError: String?
    @State private var showingCamera = false
    @State private var captureError: String?
    @State private var showingFloorPlanSetup = false
    @State private var confirmingPlanRemoval = false
    @State private var pendingPhotos: [CapturedPhoto] = []
    @State private var showingLocate = false
    @State private var showingPlanViewer = false
    @State private var showingPlanOrigin = false
    @State private var showingPlanNorth = false
    @State private var showingPlanReplace = false
    @State private var showingPlanRecalibrate = false
    @State private var showingExport = false

    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showingFileImporter = false
    @State private var importing = false
    @State private var importStatus: String?
    @State private var relocatingPhoto: PhotoTarget?
    @State private var pendingPhotoDelete: Photo?
    @State private var showingAddressEditor = false
    @State private var addressUpdating = false

    private struct PhotoTarget: Identifiable {
        let id: UUID
    }

    private var project: Project? {
        store.project(withID: projectID)
    }

    var body: some View {
        Group {
            if let project {
                List {
                    metadataSection(project)
                    actionsSection(project)
                    floorPlanSection(project)
                    photosSection(project)
                    exportSection(project)
                }
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
                .fullScreenCover(isPresented: $showingCamera) {
                    CameraView(
                        onCapture: { captured in
                            handleCapture(captured)
                            showingCamera = false
                        },
                        onCancel: { showingCamera = false }
                    )
                }
                .sheet(isPresented: $showingFloorPlanSetup) {
                    FloorPlanSetupView(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingLocate) {
                    LocateSheet(
                        projectID: projectID,
                        pendingPhotos: $pendingPhotos
                    )
                    .environment(store)
                }
                .fullScreenCover(isPresented: $showingPlanViewer) {
                    PlanViewerView(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingPlanOrigin) {
                    FloorPlanOriginView(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingPlanNorth) {
                    FloorPlanNorthView(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingPlanReplace) {
                    FloorPlanReplaceView(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingPlanRecalibrate) {
                    FloorPlanRecalibrateView(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingExport) {
                    ExportView(projectID: projectID)
                        .environment(store)
                }
                .sheet(item: $relocatingPhoto) { target in
                    RelocateSheet(projectID: projectID, photoID: target.id)
                        .environment(store)
                }
                .sheet(isPresented: $showingAddressEditor) {
                    AddressEditSheet(
                        projectID: projectID,
                        currentAddress: project.projectAddress ?? "",
                        onSave: { newAddress in
                            Task { await applyNewAddress(newAddress) }
                        }
                    )
                    .environment(store)
                }
                .fileImporter(
                    isPresented: $showingFileImporter,
                    allowedContentTypes: [.image],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result {
                        Task { await importFromFiles(urls) }
                    }
                }
                .confirmationDialog(
                    "Remove the floor plan?",
                    isPresented: $confirmingPlanRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) {
                        store.clearFloorPlan(project)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Photo locations recorded against this plan will be cleared on the next push when location capture is wired in. The plan image will be deleted from disk.")
                }
                .alert(
                    "Delete photo?",
                    isPresented: Binding(
                        get: { pendingPhotoDelete != nil },
                        set: { if !$0 { pendingPhotoDelete = nil } }
                    ),
                    presenting: pendingPhotoDelete
                ) { photo in
                    Button("Delete", role: .destructive) {
                        deletePhoto(photo)
                        pendingPhotoDelete = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingPhotoDelete = nil
                    }
                } message: { photo in
                    Text("Photo #\(photo.sequenceNumber) will be deleted and the remaining photos renumbered. This cannot be undone.")
                }
            } else {
                ContentUnavailableView(
                    "Project not found",
                    systemImage: "questionmark.folder",
                    description: Text("This project may have been deleted.")
                )
            }
        }
    }

    private func deletePhoto(_ photo: Photo) {
        guard let project = store.project(withID: projectID) else { return }
        do {
            _ = try store.deletePhoto(project, photoID: photo.id)
        } catch {
            captureError = "Could not delete photo: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func applyNewAddress(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        addressUpdating = true
        defer { addressUpdating = false }

        guard !trimmed.isEmpty else {
            // Clear the address but leave coordinates alone.
            if let project = store.project(withID: projectID) {
                _ = store.updateAddress(project, "")
            }
            return
        }

        guard let result = await location.forwardGeocode(trimmed) else {
            sessionError = "Couldn't resolve that address. Try a more complete street address."
            return
        }
        guard var current = store.project(withID: projectID) else { return }
        let newGPS = ProjectGPS(
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude,
            altitude: nil,
            accuracyFeet: nil,
            timestamp: Date()
        )
        current = store.updateGPS(current, newGPS)
        _ = store.updateAddress(current, result.address)
        sessionError = nil
    }

    private func handleCapture(_ captured: CapturedPhoto) {
        guard let project = store.project(withID: projectID) else { return }
        if project.floorPlan != nil {
            // Plan-equipped: queue for locate flow.
            pendingPhotos.append(captured)
            showingLocate = true
            captureError = nil
            return
        }
        // No plan: save immediately with NO LOC.
        do {
            try store.addPhoto(to: project, captured: captured)
            captureError = nil
        } catch {
            captureError = "Could not save photo: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func metadataSection(_ project: Project) -> some View {
        Section("Project Information") {
            LabeledContent("Created", value: project.createdAt.formatted(date: .abbreviated, time: .shortened))

            HStack {
                Text("Status")
                Spacer()
                statusText(project)
            }

            if let gps = project.projectGPS {
                LabeledContent("Coordinates") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.5f, %.5f", gps.latitude, gps.longitude))
                            .font(.caption.monospaced())
                        if let acc = gps.accuracyFeet {
                            Text(String(format: "± %.1f ft", acc))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button {
                showingAddressEditor = true
            } label: {
                HStack {
                    Text("Address")
                        .foregroundStyle(.primary)
                    Spacer()
                    addressTrailing(project)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func addressTrailing(_ project: Project) -> some View {
        HStack(spacing: 6) {
            if let address = project.projectAddress {
                Text(address)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                Text(addressLookupRunning || addressUpdating ? "looking up…" : "Tap to add")
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func actionsSection(_ project: Project) -> some View {
        Section("Session") {
            Button {
                Task { await toggleStartStop() }
            } label: {
                Label(startStopLabel(project), systemImage: startStopIcon(project))
            }
            .disabled(sessionWorking)
            .foregroundStyle(project.isActive ? Color.red : Color.accentColor)

            Button {
                showingCamera = true
            } label: {
                Label("Take Photo", systemImage: "camera")
            }
            .disabled(!project.isActive)
            .foregroundStyle(project.isActive ? Color.accentColor : Color.secondary)

            PhotosPicker(
                selection: $photoPickerItems,
                maxSelectionCount: 50,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Add from Photos", systemImage: "photo.on.rectangle")
            }
            .disabled(importing)
            .onChange(of: photoPickerItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task { await importFromPhotosLibrary(newItems) }
            }

            Button {
                showingFileImporter = true
            } label: {
                Label("Add from Files", systemImage: "folder")
            }
            .disabled(importing)

            if !project.isActive && project.hasBeenStarted {
                Text("Resume the session to take photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !project.hasBeenStarted {
                Text("Start the session, then tap Take Photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let status = importStatus {
                HStack(spacing: 6) {
                    if importing { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let err = sessionError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let err = captureError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Photo import helpers

    @MainActor
    private func importFromPhotosLibrary(_ items: [PhotosPickerItem]) async {
        defer {
            photoPickerItems = []
            importing = false
        }
        importing = true
        var added = 0
        for (i, item) in items.enumerated() {
            importStatus = "Importing \(i + 1) of \(items.count)…"
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            guard let project = store.project(withID: projectID) else { return }
            let date = ProjectStore.extractCaptureDate(from: data) ?? Date()
            do {
                _ = try store.importPhoto(to: project, imageData: data, capturedAt: date)
                added += 1
            } catch {
                captureError = "Import failed: \(error.localizedDescription)"
                importStatus = nil
                return
            }
        }
        importStatus = added > 0 ? "Imported \(added) photo\(added == 1 ? "" : "s")." : nil
    }

    @MainActor
    private func importFromFiles(_ urls: [URL]) async {
        defer {
            importing = false
        }
        importing = true
        var added = 0
        for (i, url) in urls.enumerated() {
            importStatus = "Importing \(i + 1) of \(urls.count)…"
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let project = store.project(withID: projectID) else { return }
            let date = ProjectStore.extractCaptureDate(from: data) ?? Date()
            do {
                _ = try store.importPhoto(to: project, imageData: data, capturedAt: date)
                added += 1
            } catch {
                captureError = "Import failed: \(error.localizedDescription)"
                importStatus = nil
                return
            }
        }
        importStatus = added > 0 ? "Imported \(added) photo\(added == 1 ? "" : "s")." : nil
    }

    private func toggleStartStop() async {
        guard var current = store.project(withID: projectID) else { return }
        sessionWorking = true
        sessionError = nil
        defer { sessionWorking = false }

        if current.isActive {
            store.stopSession(current)
            return
        }

        let isFirstStart = current.startedAt == nil
        current = store.startSession(current)

        guard isFirstStart, current.projectGPS == nil else { return }

        let auth = await location.requestPermission()
        guard auth == .authorizedAlways || auth == .authorizedWhenInUse else {
            sessionError = "Location permission denied. Open Settings → SitePhoto → Location to allow."
            return
        }

        do {
            let loc = try await location.currentLocation()
            let gps = ProjectGPS(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                altitude: loc.altitude.isFinite ? loc.altitude : nil,
                accuracyFeet: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy * 3.28084 : nil,
                timestamp: Date()
            )
            current = store.updateGPS(current, gps)

            addressLookupRunning = true
            if let address = await location.reverseGeocode(loc) {
                _ = store.updateAddress(current, address)
            }
            addressLookupRunning = false
        } catch LocationError.denied {
            sessionError = "Location permission denied."
        } catch {
            sessionError = "Could not get GPS: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func floorPlanSection(_ project: Project) -> some View {
        Section("Floor Plan") {
            if let plan = project.floorPlan {
                HStack(spacing: 12) {
                    floorPlanThumbnail(project)
                        .frame(width: 84, height: 64)
                        .clipped()
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calibrated").font(.subheadline.weight(.semibold))
                        Text(String(format: "%.1f px / ft", plan.pixelsPerFoot))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(String(format: "calibration: %.1f ft", plan.calibrationDistanceFeet))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(String(format: "north: %.0f° (CW from page up)", plan.northDeg))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Button {
                    showingPlanViewer = true
                } label: {
                    Label("View Plan", systemImage: "rectangle.expand.vertical")
                }

                Button {
                    showingPlanOrigin = true
                } label: {
                    Label("Set Origin", systemImage: "scope")
                }

                Button {
                    showingPlanNorth = true
                } label: {
                    Label("Set North", systemImage: "location.north")
                }

                Button {
                    showingPlanRecalibrate = true
                } label: {
                    Label("Re-calibrate Scale", systemImage: "ruler")
                }

                Button {
                    showingPlanReplace = true
                } label: {
                    Label("Replace Plan", systemImage: "rectangle.2.swap")
                }

                Button(role: .destructive) {
                    confirmingPlanRemoval = true
                } label: {
                    Label("Remove Floor Plan", systemImage: "trash")
                }
            } else {
                Text("No floor plan set. Photos will be saved without a recorded location until a plan is imported and calibrated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showingFloorPlanSetup = true
                } label: {
                    Label("Set Up Floor Plan", systemImage: "doc.viewfinder")
                }
            }
        }
    }

    @ViewBuilder
    private func floorPlanThumbnail(_ project: Project) -> some View {
        if let url = store.floorPlanURL(for: project),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func photosSection(_ project: Project) -> some View {
        Section("Photos · \(project.photos.count)") {
            if project.photos.isEmpty {
                Text("No photos yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(project.photos) { photo in
                    PhotoRow(photo: photo, project: project, store: store) {
                        relocatingPhoto = PhotoTarget(id: photo.id)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingPhotoDelete = photo
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func exportSection(_ project: Project) -> some View {
        Section("Export") {
            Button {
                showingExport = true
            } label: {
                Label("Export PDF", systemImage: "doc.richtext")
            }
            .disabled(project.photos.isEmpty)
        }
    }

    private func statusText(_ project: Project) -> Text {
        if project.isActive { return Text("Recording").foregroundStyle(.red) }
        if project.hasBeenStarted { return Text("Paused").foregroundStyle(.orange) }
        return Text("Not started").foregroundStyle(.secondary)
    }

    private func startStopLabel(_ project: Project) -> String {
        if project.isActive { return "Stop" }
        if project.hasBeenStarted { return "Resume" }
        return "Start"
    }

    private func startStopIcon(_ project: Project) -> String {
        project.isActive ? "stop.fill" : "play.fill"
    }
}

private struct PhotoRow: View {
    let photo: Photo
    let project: Project
    let store: ProjectStore
    var onLocate: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 64, height: 48)
                .clipped()
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(photo.sequenceNumber)")
                        .font(.headline.monospaced())
                    if photo.positionSource == .none {
                        badge(text: "NO LOC", color: .orange)
                    } else if photo.groupID != nil {
                        badge(text: photo.isPrimary ? "GROUP★" : "GROUP", color: .blue)
                    } else {
                        badge(text: "LOCATED", color: .green)
                    }
                }
                Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(metaLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let onLocate, project.floorPlan != nil {
                let isUnlocated = photo.positionSource == .none
                Button {
                    onLocate()
                } label: {
                    Image(systemName: isUnlocated
                          ? "location"
                          : "arrow.up.and.down.and.arrow.left.and.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.blue)
                .accessibilityLabel(isUnlocated ? "Add Location" : "Change Location")
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = store.thumbnailURL(for: photo, in: project),
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

    private var metaLine: String {
        var parts: [String] = []
        if let lens = photo.lensName { parts.append(lens.uppercased()) }
        parts.append(zoomLabel(photo.cameraZoom))
        parts.append("flash \(photo.flashMode.rawValue)")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold().monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private func zoomLabel(_ z: Double) -> String {
        if z == floor(z) { return "\(Int(z))x" }
        return String(format: "%.1fx", z)
    }
}

#Preview {
    let store = ProjectStore()
    let location = LocationService()
    let p = Project(name: "Demo project")
    let saved = store.save(p)
    return NavigationStack {
        ProjectDetailView(projectID: saved.id)
            .environment(store)
            .environment(location)
    }
}
