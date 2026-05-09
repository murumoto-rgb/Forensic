import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(LocationService.self) private var location
    @AppStorage("sitephoto.tagConfidenceThreshold")
    private var tagConfidenceThreshold: Double = 0.5
    let projectID: UUID

    @State private var addressLookupRunning = false
    @State private var locationError: String?
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
    /// True when the photos list is in multi-select / batch-delete mode.
    /// While on, rows show a check circle and tapping toggles selection
    /// instead of opening the tag editor; the per-row swipe-to-delete is
    /// also suspended.
    @State private var selectionMode: Bool = false
    @State private var selectedPhotoIDs: Set<UUID> = []
    @State private var confirmingBatchDelete: Bool = false
    @State private var showingBucketManager: Bool = false
    @State private var showingBucketPicker: Bool = false
    /// Bucket IDs currently active as filters on the photo list. Empty =
    /// no bucket filter. OR semantics across selected buckets, ANDed with
    /// the existing tag and recommended-use filters.
    @State private var activeBucketFilter: Set<UUID> = []
    @State private var showingAddressEditor = false
    @State private var addressUpdating = false
    @State private var taggingPhoto: PhotoTarget?
    /// Tags currently active as filters on the photo list. Empty = no filter.
    /// Compared case-insensitively. AND semantics: a photo must carry every
    /// active filter tag to appear.
    @State private var activeTagFilters: Set<String> = []
    /// True when the "Needs review" chip is on. Surfaces every photo
    /// where Claude self-rated low confidence, wrote a reviewer flag, or
    /// returned a response that failed validation. ANDed with the tag
    /// filter and the recommended-use filter.
    @State private var showOnlyNeedsReview: Bool = false
    /// Recommended-use bucket(s) to keep. Empty = no use-based filtering.
    /// ANDed with the tag filter and the needs-review toggle.
    @State private var recommendedUseFilter: Set<String> = []

    @State private var showingAIInstructions = false
    @State private var showingTagFilter = false
    @State private var showingClearAITags = false
    @State private var batchTagConfirm: BatchTagPrompt?
    @State private var batchTagTask: Task<Void, Never>?
    @State private var batchTagProgressCurrent: Int = 0
    @State private var batchTagProgressTotal: Int = 0
    @State private var batchTagProgressSeq: Int?
    @State private var batchTagError: String?
    @State private var batchTagSummary: String?
    @State private var batchTagFailureReport: BatchTagFailureReport?
    @State private var batchBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

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
                    aiTaggingSection(project)
                    bucketsSection(project)
                    exportSection(project)
                    photosSection(project)
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
                .sheet(item: $taggingPhoto) { target in
                    PhotoTagEditorSheet(projectID: projectID, photoID: target.id)
                        .environment(store)
                }
                .sheet(isPresented: $showingAIInstructions) {
                    AIInstructionsSheet(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingTagFilter) {
                    TagFilterView(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingClearAITags) {
                    ClearAITagsSheet(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingBucketManager) {
                    BucketManagerSheet(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingBucketPicker) {
                    BucketPickerSheet(
                        projectID: projectID,
                        photoIDs: selectedPhotoIDs,
                        onAssigned: {
                            exitSelectionMode()
                        }
                    )
                    .environment(store)
                }
                .sheet(item: $batchTagFailureReport) { report in
                    BatchTagSummarySheet(
                        projectID: projectID,
                        result: report.result,
                        candidateCount: report.candidateCount,
                        mode: report.mode,
                        onRetry: { ids, mode in
                            retryFailedTagging(photoIDs: ids, mode: mode)
                        }
                    )
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
                    Text("The plan image will be deleted from this project. Photo positions are preserved — they'll reappear in the same physical locations when you set up a new plan with calibration and origin.")
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
                .alert(
                    "Delete \(selectedPhotoIDs.count) photo\(selectedPhotoIDs.count == 1 ? "" : "s")?",
                    isPresented: $confirmingBatchDelete
                ) {
                    Button("Delete", role: .destructive) {
                        deleteSelectedPhotos()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The selected photos will be deleted and the remaining photos will be renumbered. This cannot be undone.")
                }
                .modifier(BatchTagModifiers(
                    confirm: $batchTagConfirm,
                    summary: $batchTagSummary,
                    error: $batchTagError,
                    isRunning: batchTagTask != nil,
                    progressCurrent: batchTagProgressCurrent,
                    progressTotal: batchTagProgressTotal,
                    progressSeq: batchTagProgressSeq,
                    costFor: estimatedCostString,
                    onConfirm: { prompt, mode in
                        startBatchTagging(prompt, mode: mode)
                        batchTagConfirm = nil
                    },
                    onCancel: cancelBatchTagging
                ))
            } else {
                ContentUnavailableView(
                    "Project not found",
                    systemImage: "questionmark.folder",
                    description: Text("This project may have been deleted.")
                )
            }
        }
        .task(id: projectID) {
            await captureLocationIfNeeded()
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
            locationError = "Couldn't resolve that address. Try a more complete street address."
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
        locationError = nil
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
        Section("Photo Documentation") {
            Button {
                showingCamera = true
            } label: {
                Label("Take Photo", systemImage: "camera")
            }

            PhotosPicker(
                selection: $photoPickerItems,
                // No cap — the loop in importFromPhotosLibrary processes
                // items serially, so memory stays flat regardless of
                // selection size. Large batches just take proportionally
                // longer, with the "Importing N of M…" line ticking up.
                maxSelectionCount: nil,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Add from Photo Library", systemImage: "photo.on.rectangle")
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

            if let status = importStatus {
                HStack(spacing: 6) {
                    if importing { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let err = locationError {
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

    /// One-shot: when a project is opened that doesn't yet have a GPS fix,
    /// request the device's current location, store it, and reverse-geocode
    /// the address. Replaces what the old "Start Session" button used to do.
    /// Failure paths are non-fatal — the user can still set the address by
    /// hand from the Address row.
    @MainActor
    private func captureLocationIfNeeded() async {
        guard var current = store.project(withID: projectID),
              current.projectGPS == nil else { return }
        locationError = nil

        let auth = await location.requestPermission()
        guard auth == .authorizedAlways || auth == .authorizedWhenInUse else {
            locationError = "Location permission denied. Open Settings → SitePhoto → Location to allow, or enter the address manually."
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
            locationError = "Location permission denied."
        } catch {
            locationError = "Could not get GPS: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func floorPlanSection(_ project: Project) -> some View {
        Section("Floor Plan") {
            if project.floorPlan != nil {
                floorPlanThumbnail(project)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipped()
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

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
        let projectTags = store.tagsUsed(in: project, minConfidence: tagConfidenceThreshold)
        let visiblePhotos = filteredPhotos(project)
        Section {
            if !projectTags.isEmpty {
                tagFilterBar(allTags: projectTags)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
            }
            if project.photos.isEmpty {
                Text("No photos yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if visiblePhotos.isEmpty {
                Text("No photos match the selected tag filter.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                if selectionMode {
                    selectionActionRow(visiblePhotos: visiblePhotos)
                }
                ForEach(visiblePhotos) { photo in
                    if selectionMode {
                        selectablePhotoRow(photo: photo, project: project)
                    } else {
                        PhotoRow(
                            photo: photo,
                            project: project,
                            store: store,
                            onLocate: {
                                relocatingPhoto = PhotoTarget(id: photo.id)
                            },
                            onTag: {
                                taggingPhoto = PhotoTarget(id: photo.id)
                            }
                        )
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
        } header: {
            photosSectionHeader(project: project, visiblePhotos: visiblePhotos)
        }
    }

    @ViewBuilder
    private func photosSectionHeader(project: Project, visiblePhotos: [Photo]) -> some View {
        HStack(spacing: 8) {
            if selectionMode {
                Text("\(selectedPhotoIDs.count) selected")
                    .textCase(nil)
                Spacer()
                let allVisibleSelected = !visiblePhotos.isEmpty
                    && visiblePhotos.allSatisfy { selectedPhotoIDs.contains($0.id) }
                Button(allVisibleSelected ? "None" : "All") {
                    if allVisibleSelected {
                        selectedPhotoIDs.subtract(visiblePhotos.map(\.id))
                    } else {
                        selectedPhotoIDs.formUnion(visiblePhotos.map(\.id))
                    }
                }
                .textCase(nil)
                .font(.caption)
                Button("Cancel") {
                    exitSelectionMode()
                }
                .textCase(nil)
                .font(.caption)
            } else {
                Text("Photos · \(project.photos.count)")
                if !activeTagFilters.isEmpty
                    || !recommendedUseFilter.isEmpty
                    || !activeBucketFilter.isEmpty
                    || showOnlyNeedsReview {
                    Text("· \(visiblePhotos.count) shown")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !project.photos.isEmpty {
                    Button("Select") {
                        selectionMode = true
                    }
                    .textCase(nil)
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func selectionActionRow(visiblePhotos: [Photo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    showingBucketPicker = true
                } label: {
                    Label(
                        "Move \(selectedPhotoIDs.count) to Bucket…",
                        systemImage: "folder"
                    )
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(selectedPhotoIDs.isEmpty)
                Spacer()
            }
            HStack {
                Button(role: .destructive) {
                    confirmingBatchDelete = true
                } label: {
                    Label(
                        "Delete \(selectedPhotoIDs.count) Photo\(selectedPhotoIDs.count == 1 ? "" : "s")",
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedPhotoIDs.isEmpty)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func selectablePhotoRow(photo: Photo, project: Project) -> some View {
        let isSelected = selectedPhotoIDs.contains(photo.id)
        Button {
            if isSelected {
                selectedPhotoIDs.remove(photo.id)
            } else {
                selectedPhotoIDs.insert(photo.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                PhotoRow(
                    photo: photo,
                    project: project,
                    store: store
                )
                .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedPhotoIDs.removeAll()
    }

    private func deleteSelectedPhotos() {
        guard let project = store.project(withID: projectID) else { return }
        let ids = selectedPhotoIDs
        guard !ids.isEmpty else { return }
        do {
            _ = try store.deletePhotos(project, photoIDs: ids)
            exitSelectionMode()
        } catch {
            captureError = "Could not delete photos: \(error.localizedDescription)"
        }
    }

    private func filteredPhotos(_ project: Project) -> [Photo] {
        let tagFilterActive = !activeTagFilters.isEmpty
        let useFilterActive = !recommendedUseFilter.isEmpty
        let bucketFilterActive = !activeBucketFilter.isEmpty
        if !tagFilterActive && !useFilterActive && !bucketFilterActive && !showOnlyNeedsReview {
            return project.photos
        }
        let lcFilters = Set(activeTagFilters.map { $0.lowercased() })
        return project.photos.filter { photo in
            if tagFilterActive {
                let photoLC = Set(photo.tags
                    .filter { $0.confidence >= tagConfidenceThreshold }
                    .map { $0.label.lowercased() })
                if !lcFilters.isSubset(of: photoLC) { return false }
            }
            if useFilterActive {
                let bucket = photo.aiAnalysis?.recommendedUse.bucketKey ?? ""
                if !recommendedUseFilter.contains(bucket) { return false }
            }
            if bucketFilterActive {
                guard let bid = photo.bucketID,
                      activeBucketFilter.contains(bid) else { return false }
            }
            if showOnlyNeedsReview {
                if !needsReview(photo) { return false }
            }
            return true
        }
    }

    /// True when this photo warrants the engineer's attention before
    /// shipping the report — Claude self-rated Low confidence, wrote a
    /// reviewer flag, returned a response that didn't pass validation,
    /// or the response couldn't be parsed at all.
    private func needsReview(_ photo: Photo) -> Bool {
        guard let a = photo.aiAnalysis else { return false }
        if a.parseFailed { return true }
        if !a.reviewerFlag.isEmpty { return true }
        if !a.validationErrors.isEmpty { return true }
        if case .low = a.confidence { return true }
        return false
    }

    @ViewBuilder
    private func tagFilterBar(allTags: [String]) -> some View {
        // Buckets and reviewer-attention counts come from the project's
        // analysed photos; the chips below them only show when at least
        // one photo would match.
        let needsReviewCount = store.project(withID: projectID)
            .map { project in project.photos.filter { needsReview($0) }.count } ?? 0
        let recommendedUseChips = bucketsInUseFor(projectID: projectID)
        let userBuckets = (store.project(withID: projectID)?.buckets ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !activeTagFilters.isEmpty
                    || !recommendedUseFilter.isEmpty
                    || !activeBucketFilter.isEmpty
                    || showOnlyNeedsReview {
                    Button {
                        activeTagFilters.removeAll()
                        recommendedUseFilter.removeAll()
                        activeBucketFilter.removeAll()
                        showOnlyNeedsReview = false
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if needsReviewCount > 0 {
                    Button {
                        showOnlyNeedsReview.toggle()
                    } label: {
                        Label("Needs review · \(needsReviewCount)",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(showOnlyNeedsReview ? .orange : .secondary)
                }
                ForEach(userBuckets) { bucket in
                    let on = activeBucketFilter.contains(bucket.id)
                    Button {
                        if on { activeBucketFilter.remove(bucket.id) }
                        else  { activeBucketFilter.insert(bucket.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(bucket.color)
                                .frame(width: 8, height: 8)
                            Text(bucket.name)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(on ? bucket.color : .secondary)
                }
                ForEach(recommendedUseChips, id: \.self) { bucket in
                    let on = recommendedUseFilter.contains(bucket)
                    Button {
                        if on { recommendedUseFilter.remove(bucket) }
                        else  { recommendedUseFilter.insert(bucket) }
                    } label: {
                        Text(bucket)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(on ? .blue : .secondary)
                }
                ForEach(allTags, id: \.self) { tag in
                    let on = activeTagFilters.contains(tag)
                    Button {
                        if on { activeTagFilters.remove(tag) }
                        else  { activeTagFilters.insert(tag) }
                    } label: {
                        Text(tag)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(on ? .accentColor : .secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Recommended-use buckets that actually appear on at least one photo
    /// in the project. Sorted in canonical order so the chip bar reads
    /// Body figure → Re-shoot recommended consistently across projects.
    private func bucketsInUseFor(projectID: UUID) -> [String] {
        guard let project = store.project(withID: projectID) else { return [] }
        var seen: Set<String> = []
        for photo in project.photos {
            if let a = photo.aiAnalysis, !a.parseFailed {
                seen.insert(a.recommendedUse.bucketKey)
            }
        }
        let canonical: [String] = [
            RecommendedUse.bodyFigure.displayName,
            RecommendedUse.appendixOnly.displayName,
            RecommendedUse.contextLocator.displayName,
            RecommendedUse.reshootRecommended.displayName
        ]
        var out: [String] = canonical.filter { seen.contains($0) }
        let extras = seen.subtracting(out).sorted()
        out.append(contentsOf: extras)
        return out
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

    // MARK: - AI Tagging section

    @ViewBuilder
    private func aiTaggingSection(_ project: Project) -> some View {
        let untaggedCount = project.photos.filter { $0.tags.isEmpty }.count
        let taggedCount   = project.photos.count - untaggedCount

        Section {
            Button {
                showingTagFilter = true
            } label: {
                Label("Filter photos by tag…", systemImage: "line.3.horizontal.decrease.circle")
            }
            .disabled(project.photos.isEmpty)

            Button {
                showingAIInstructions = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Instructions")
                        Text(project.hasCustomAIInstructions
                             ? "Customised for this project"
                             : "Using bundled forensic-engineering default")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: project.hasCustomAIInstructions
                          ? "doc.text.fill" : "doc.text")
                }
            }

            Button {
                batchTagConfirm = BatchTagPrompt(
                    candidateCount: untaggedCount,
                    skippedCount: taggedCount,
                    skipAlreadyTagged: true,
                    candidatesWithExistingTags: 0
                )
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-tag untagged photos with AI")
                        if untaggedCount > 0 {
                            Text("\(untaggedCount) photo\(untaggedCount == 1 ? "" : "s") · ~\(estimatedCostString(for: untaggedCount))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Every photo already has tags.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "wand.and.sparkles")
                }
            }
            .disabled(untaggedCount == 0 || batchTagTask != nil)

            if taggedCount > 0 && project.photos.count > 0 {
                Button {
                    batchTagConfirm = BatchTagPrompt(
                        candidateCount: project.photos.count,
                        skippedCount: 0,
                        skipAlreadyTagged: false,
                        candidatesWithExistingTags: taggedCount
                    )
                } label: {
                    Label("Auto-tag every photo",
                          systemImage: "wand.and.sparkles.inverse")
                }
                .disabled(batchTagTask != nil)
            }

            Button(role: .destructive) {
                showingClearAITags = true
            } label: {
                Label("Clear AI tagging from photos…",
                      systemImage: "eraser")
            }
            .disabled(project.photos.isEmpty || batchTagTask != nil)
        } header: {
            Text("AI Tagging")
        } footer: {
            Text("Each photo is sent to Claude (~1¢ each with prompt caching, billed to your Anthropic account) using the project's tagging guide. Returned tags are auto-accepted. Cancel any time. \"Clear AI tagging\" lets you pick which AI tags to remove from selected photos while preserving manual entries and the photo's saved AI analysis.")
        }
    }

    // MARK: - Buckets section

    @ViewBuilder
    private func bucketsSection(_ project: Project) -> some View {
        let sortedBuckets = project.buckets.sorted { $0.sortOrder < $1.sortOrder }
        Section {
            Button {
                showingBucketManager = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manage Buckets")
                        Text(sortedBuckets.isEmpty
                             ? "No buckets yet — create some to group photos for export."
                             : "\(sortedBuckets.count) bucket\(sortedBuckets.count == 1 ? "" : "s") defined")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "folder")
                }
            }
            if !sortedBuckets.isEmpty {
                let unbucketedCount = project.photos.filter { $0.bucketID == nil }.count
                bucketCountsRow(buckets: sortedBuckets,
                                  photos: project.photos,
                                  unbucketedCount: unbucketedCount)
            }
        } header: {
            Text("Buckets")
        } footer: {
            Text("Buckets are user-defined categories for grouping photos — typically one per report section. Use the Photos list's Select mode to assign multiple photos at once.")
        }
    }

    @ViewBuilder
    private func bucketCountsRow(buckets: [Bucket],
                                   photos: [Photo],
                                   unbucketedCount: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(buckets) { bucket in
                    let count = photos.filter { $0.bucketID == bucket.id }.count
                    HStack(spacing: 4) {
                        Circle()
                            .fill(bucket.color)
                            .frame(width: 10, height: 10)
                        Text(bucket.name)
                            .font(.caption)
                        Text("\(count)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                if unbucketedCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "tray")
                            .font(.caption2)
                        Text("Unbucketed")
                            .font(.caption)
                        Text("\(unbucketedCount)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Per-photo cost is ~$0.01 with the long forensic prompt + prompt
    /// caching enabled. The first photo in a 5-min window pays a write
    /// premium; subsequent photos in the same batch pay only ~10% of the
    /// cached portion. Across a full batch the average lands near 1¢.
    private func estimatedCostString(for count: Int) -> String {
        let cents = Double(count) * 1.0
        if cents < 100 {
            return String(format: "%.0f¢", cents)
        }
        return String(format: "$%.2f", cents / 100)
    }

    private func startBatchTagging(_ prompt: BatchTagPrompt,
                                    mode: ProjectStore.BatchTagMode) {
        batchTagError = nil
        batchTagSummary = nil
        batchTagProgressCurrent = 0
        batchTagProgressTotal = prompt.candidateCount
        batchTagProgressSeq = nil

        // (A) Keep the screen alive while the batch runs so iOS doesn't
        // suspend us when the auto-lock timer fires. Reset on completion.
        UIApplication.shared.isIdleTimerDisabled = true

        // (B) Ask iOS for ~30s of background grace if the user briefly
        // backgrounds the app — long enough for the in-flight requests to
        // finish and persist their manifests before suspension. The user
        // can resume the batch by re-tapping "Auto-tag untagged" since
        // already-tagged photos are skipped automatically.
        batchBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "AI Tagging"
        ) {
            // Expiration handler — iOS is about to suspend us. Cancel the
            // task cleanly so the in-flight Claude calls bail out.
            batchTagTask?.cancel()
            endBatchBackgroundTask()
        }

        let pid = projectID
        let skip = prompt.skipAlreadyTagged
        let candidateCount = prompt.candidateCount
        batchTagTask = Task { @MainActor in
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                endBatchBackgroundTask()
            }
            do {
                let result = try await store.batchClaudeTagging(
                    projectID: pid,
                    skipAlreadyTagged: skip,
                    mode: mode,
                    onlyPhotoIDs: nil,
                    onProgress: { current, total, seq in
                        self.batchTagProgressCurrent = current
                        self.batchTagProgressTotal = total
                        self.batchTagProgressSeq = seq
                    }
                )
                self.presentResult(result, candidateCount: candidateCount, mode: mode)
            } catch is CancellationError {
                self.batchTagSummary = "Cancelled at \(self.batchTagProgressCurrent) of \(self.batchTagProgressTotal). Re-run \"Auto-tag untagged\" to resume — already-tagged photos will be skipped."
            } catch let err as ClaudeTaggingService.Error {
                self.batchTagError = err.errorDescription ?? "Failed."
            } catch {
                self.batchTagError = error.localizedDescription
            }
            self.batchTagTask = nil
        }
    }

    private func endBatchBackgroundTask() {
        if batchBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(batchBackgroundTaskID)
            batchBackgroundTaskID = .invalid
        }
    }

    private func cancelBatchTagging() {
        batchTagTask?.cancel()
    }

    /// Decide how to surface a finished batch: a completely-clean run
    /// (no failures, no parse errors, no validation issues, no reviewer
    /// flags, no low-confidence picks) gets a quiet text alert; anything
    /// else opens the rich summary sheet so the user can see counts per
    /// primary, counts per recommended use, the photos that need review,
    /// and any failed photos to retry.
    private func presentResult(_ result: ProjectStore.BatchTagResult,
                                 candidateCount: Int,
                                 mode: ProjectStore.BatchTagMode) {
        if result.isCompletelyClean {
            self.batchTagSummary = "Tagged \(result.tagged) of \(candidateCount) photo\(candidateCount == 1 ? "" : "s")."
                + (result.skipped > 0 ? " \(result.skipped) already had tags." : "")
        } else {
            self.batchTagFailureReport = BatchTagFailureReport(
                result: result,
                candidateCount: candidateCount,
                mode: mode
            )
        }
    }

    /// Re-run the batch on a specific set of photo IDs (typically the
    /// failed ones from a prior run). Bypasses the confirmation alert
    /// since the user explicitly asked to retry, and uses the same
    /// Add/Overwrite mode the original batch ran with.
    private func retryFailedTagging(photoIDs: Set<UUID>,
                                      mode: ProjectStore.BatchTagMode) {
        guard !photoIDs.isEmpty else { return }
        guard batchTagTask == nil else { return }   // a batch is already running

        batchTagError = nil
        batchTagSummary = nil
        batchTagFailureReport = nil
        batchTagProgressCurrent = 0
        batchTagProgressTotal = photoIDs.count
        batchTagProgressSeq = nil

        UIApplication.shared.isIdleTimerDisabled = true
        batchBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "AI Tagging Retry"
        ) {
            batchTagTask?.cancel()
            endBatchBackgroundTask()
        }

        let pid = projectID
        let candidateCount = photoIDs.count
        batchTagTask = Task { @MainActor in
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                endBatchBackgroundTask()
            }
            do {
                let result = try await store.batchClaudeTagging(
                    projectID: pid,
                    mode: mode,
                    onlyPhotoIDs: photoIDs,
                    onProgress: { current, total, seq in
                        self.batchTagProgressCurrent = current
                        self.batchTagProgressTotal = total
                        self.batchTagProgressSeq = seq
                    }
                )
                self.presentResult(result, candidateCount: candidateCount, mode: mode)
            } catch is CancellationError {
                self.batchTagSummary = "Retry cancelled at \(self.batchTagProgressCurrent) of \(self.batchTagProgressTotal)."
            } catch let err as ClaudeTaggingService.Error {
                self.batchTagError = err.errorDescription ?? "Failed."
            } catch {
                self.batchTagError = error.localizedDescription
            }
            self.batchTagTask = nil
        }
    }

}

/// State envelope for the failure-summary sheet. Carries the batch result
/// + the parameters needed to retry just the failed photos with the same
/// settings the original run used.
fileprivate struct BatchTagFailureReport: Identifiable {
    let id = UUID()
    let result: ProjectStore.BatchTagResult
    let candidateCount: Int
    let mode: ProjectStore.BatchTagMode
}

fileprivate struct BatchTagPrompt: Identifiable {
    let id = UUID()
    let candidateCount: Int
    let skippedCount: Int
    let skipAlreadyTagged: Bool
    /// Number of candidate photos that already carry at least one tag —
    /// the population that "Overwrite" will actually clobber. Equal to 0
    /// when `skipAlreadyTagged` is true (those photos are filtered out
    /// before the prompt shows).
    let candidatesWithExistingTags: Int
}

/// Bundles the four batch-tagging-related view modifiers (3 alerts + 1
/// overlay) into a single `ViewModifier`. Keeps `ProjectDetailView.body`
/// short enough for the SwiftUI type checker to handle without timing out.
fileprivate struct BatchTagModifiers: ViewModifier {
    @Binding var confirm: BatchTagPrompt?
    @Binding var summary: String?
    @Binding var error: String?
    let isRunning: Bool
    let progressCurrent: Int
    let progressTotal: Int
    let progressSeq: Int?
    let costFor: (Int) -> String
    let onConfirm: (BatchTagPrompt, ProjectStore.BatchTagMode) -> Void
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(confirmTitle, isPresented: confirmIsPresented, presenting: confirm) { prompt in
                Button("Add to existing · ~\(costFor(prompt.candidateCount))") {
                    onConfirm(prompt, .add)
                }
                if prompt.candidatesWithExistingTags > 0 {
                    Button("Overwrite existing · ~\(costFor(prompt.candidateCount))",
                           role: .destructive) {
                        onConfirm(prompt, .overwrite)
                    }
                }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: { prompt in
                Text(confirmMessage(for: prompt))
            }
            .alert("AI tagging done",
                   isPresented: summaryIsPresented,
                   presenting: summary) { _ in
                Button("OK") { summary = nil }
            } message: { s in
                Text(s)
            }
            .alert("AI tagging failed",
                   isPresented: errorIsPresented,
                   presenting: error) { _ in
                Button("OK") { error = nil }
            } message: { msg in
                Text(msg)
            }
            .overlay {
                if isRunning {
                    BatchTagProgressOverlay(
                        current: progressCurrent,
                        total: progressTotal,
                        photoSeq: progressSeq,
                        onCancel: onCancel
                    )
                }
            }
    }

    private var confirmIsPresented: Binding<Bool> {
        Binding(get: { confirm != nil },
                set: { if !$0 { confirm = nil } })
    }
    private var summaryIsPresented: Binding<Bool> {
        Binding(get: { summary != nil },
                set: { if !$0 { summary = nil } })
    }
    private var errorIsPresented: Binding<Bool> {
        Binding(get: { error != nil },
                set: { if !$0 { error = nil } })
    }

    private var confirmTitle: String {
        let n = confirm?.candidateCount ?? 0
        return "Run AI tagging on \(n) photo\(n == 1 ? "" : "s")?"
    }

    private func confirmMessage(for prompt: BatchTagPrompt) -> String {
        let cost = costFor(prompt.candidateCount)
        var lines: [String] = []
        lines.append("Each photo is sent to Claude vision and every returned tag is auto-accepted. Estimated cost: ~\(cost).")

        if prompt.skipAlreadyTagged && prompt.skippedCount > 0 {
            lines.append("\(prompt.skippedCount) photo\(prompt.skippedCount == 1 ? "" : "s") with existing tags will be skipped.")
        }
        if prompt.candidatesWithExistingTags > 0 {
            lines.append("\(prompt.candidatesWithExistingTags) of these photo\(prompt.candidatesWithExistingTags == 1 ? "" : "s") already have tags. \"Add\" preserves them; \"Overwrite\" replaces them with what Claude returns.")
        }
        return lines.joined(separator: "\n\n")
    }
}

private struct BatchTagProgressOverlay: View {
    let current: Int
    let total: Int
    let photoSeq: Int?
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if total > 0 {
                    ProgressView(value: Double(current), total: Double(max(total, 1)))
                        .tint(.white)
                        .frame(width: 220)
                }
                if let photoSeq {
                    Text("Photo #\(photoSeq)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.75))
                }
                Button("Cancel", role: .destructive, action: onCancel)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(28)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var headline: String {
        if total == 0 { return "Starting…" }
        return "Tagging \(current) of \(total)"
    }
}

private struct PhotoRow: View {
    let photo: Photo
    let project: Project
    let store: ProjectStore
    var onLocate: (() -> Void)? = nil
    var onTag: (() -> Void)? = nil
    @AppStorage("sitephoto.tagConfidenceThreshold")
    private var tagConfidenceThreshold: Double = 0.5

    /// Tags above the visibility threshold, sorted to read top-to-bottom
    /// the same way they appear in the AI guide: primaries in canonical
    /// order, secondaries grouped under their primary. The chip itself
    /// only shows the label string — combining "Primary / Secondary" would
    /// make every chip wide and lose the visual hierarchy.
    private var visibleTags: [Tag] {
        let kept = photo.tags.filter { $0.confidence >= tagConfidenceThreshold }
        return kept.sorted { lhs, rhs in
            let lParent = lhs.parentTag ?? lhs.label
            let rParent = rhs.parentTag ?? rhs.label
            let lr = AIInstructions.primaryRank(lParent)
            let rr = AIInstructions.primaryRank(rParent)
            if lr != rr { return lr < rr }
            if lParent.lowercased() != rParent.lowercased() {
                return lParent.lowercased() < rParent.lowercased()
            }
            // Same primary bucket — primary itself first, then secondaries.
            let lIsPrimary = lhs.parentTag == nil
            let rIsPrimary = rhs.parentTag == nil
            if lIsPrimary != rIsPrimary { return lIsPrimary }
            return lhs.label.lowercased() < rhs.label.lowercased()
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onTag?()
            } label: {
                thumbnail
                    .frame(width: 96, height: 72)
                    .clipped()
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

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
                    let livePending = photo.pendingSuggestions.filter { $0.source == .claude }
                    if !livePending.isEmpty {
                        badge(text: "AI \(livePending.count)", color: .purple)
                    }
                    if let bucket = bucketFor(photo) {
                        bucketBadge(bucket)
                    }
                }
                Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(metaLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                if !visibleTags.isEmpty {
                    tagsRow
                }
            }
            Spacer()
            VStack(spacing: 6) {
                if let onTag {
                    Button {
                        onTag()
                    } label: {
                        Image(systemName: visibleTags.isEmpty ? "tag" : "tag.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.purple)
                    .accessibilityLabel("Edit Tags")
                }
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
    }

    @ViewBuilder
    private var tagsRow: some View {
        // ScrollView keeps long tag lists from forcing the row to grow tall
        // or breaking the cell layout. Two-line wrap would be nicer but adds
        // a layout pass per row — the horizontal scroll is fine for now.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(visibleTags, id: \.label) { tag in
                    HStack(spacing: 3) {
                        Text(tag.label)
                        if tag.confidence < 1.0 {
                            Text("\(Int(round(tag.confidence * 100)))")
                                .foregroundStyle(.purple.opacity(0.6))
                        }
                    }
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15), in: Capsule())
                    .foregroundStyle(.purple)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Resolve the photo's bucket against the project's defined buckets.
    /// Returns nil for unbucketed photos or for stale references whose
    /// bucket has since been deleted (ProjectStore.deleteBucket nilifies
    /// these on save, but a freshly-decoded manifest could still carry an
    /// orphan reference).
    private func bucketFor(_ photo: Photo) -> Bucket? {
        guard let id = photo.bucketID else { return nil }
        return project.buckets.first(where: { $0.id == id })
    }

    @ViewBuilder
    private func bucketBadge(_ bucket: Bucket) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(bucket.color)
                .frame(width: 7, height: 7)
            Text(bucket.name)
                .font(.caption2.bold())
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(bucket.color.opacity(0.2), in: Capsule())
        .foregroundStyle(bucket.color)
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
