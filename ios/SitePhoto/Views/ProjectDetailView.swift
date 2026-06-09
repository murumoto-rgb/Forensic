import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Which subset of the legacy ProjectDetailView body to render
/// (Build #5.128.1 — iOS IA refactor PR 2/7).
///
/// PR 1 introduced the workspace tab shell with Photos embedding the
/// full ProjectDetailView and the other four tabs showing placeholders.
/// PR 2 makes each tab render a *slice* of the same view via this scope
/// enum, so the user sees only the section that belongs to that tab —
/// the actual content stays in ProjectDetailView (no per-section file
/// rewrites yet, those are PRs 3-6).
///
/// `.all` is the default and matches today's behavior for any caller
/// that doesn't opt in. Each tab passes the scope that corresponds to
/// its content.
enum ProjectDetailScope: Hashable {
    case all
    case photos    // imports + photos list + trash + filter chips
    case plan      // floor plans
    case ai        // AI tagging
    case export    // export
    case more      // metadata + buckets
}

struct ProjectDetailView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(LocationService.self) private var location
    @Environment(ToastCenter.self) private var toastCenter
    @AppStorage("sitephoto.tagConfidenceThreshold")
    private var tagConfidenceThreshold: Double = 0.5
    let projectID: UUID
    var scope: ProjectDetailScope = .all

    @State private var addressLookupRunning = false
    @State private var locationError: String?
    @State private var showingCamera = false
    @State private var captureError: String?
    @State private var showingFloorPlanSetup = false
    @State private var confirmingPlanRemoval = false
    @State private var planPendingRemoval: FloorPlan?
    @State private var renamingPlan: FloorPlan?
    @State private var renamePlanDraft: String = ""
    /// Photo IDs that just landed via Photos-library or Files import,
    /// OR were picked in multi-select before the engineer tapped "Move
    /// to Level". Drives the `FloorPlanAssignmentSheet` presentation;
    /// cleared after the sheet dismisses. `assignmentFromSelection`
    /// distinguishes the two paths so the multi-select case can also
    /// exit selection mode on completion.
    @State private var pendingPlanAssignment: Set<UUID> = []
    @State private var assignmentFromSelection: Bool = false
    @State private var planFilter: PlanFilter = .all
    /// One-line filter row toggle: when on, show only photos with no
    /// bucket assigned. Useful when triaging fresh imports that
    /// haven't been categorised yet.
    @State private var notInBucketOnly: Bool = false
    /// One-line filter row pill: limit visible photos to those with /
    /// without a plan position. Orthogonal to the level filter
    /// (which scopes by which plan, not whether placed).
    @State private var locationFilter: LocationFilter = .all
    private enum LocationFilter: Hashable {
        case all
        case located
        case notLocated
    }
    private enum PlanFilter: Hashable {
        case all
        case unassigned
        case plan(UUID)
    }
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
    @State private var showingBulkTagPicker: Bool = false
    /// Bucket IDs currently active as filters on the photo list. Empty =
    /// no bucket filter. OR semantics across selected buckets, ANDed with
    /// the existing tag and recommended-use filters.
    @State private var activeBucketFilter: Set<UUID> = []
    /// Text in the search field. Empty = no text filter. Matched against
    /// photo sequence number, location, caption (user or AI), observation
    /// (user or AI), and tag labels. ANDed with the other filters.
    @State private var searchText: String = ""
    /// True when the "Favorites only" chip is on. Surfaces only photos
    /// where `isFavorite == true`. ANDed with the other filters.
    @State private var favoritesOnly: Bool = false
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
    /// True when the "Validation issues only" chip is on. Stricter than
    /// `showOnlyNeedsReview` — surfaces only photos whose AI response
    /// actually tripped a vocabulary or schema rule in
    /// `AIResponseValidator`, ignoring reviewer flags / low confidence /
    /// parse failures. Useful for triaging vocab regressions after a
    /// rules-template change.
    @State private var validationIssuesOnly: Bool = false
    /// True when the "Has measurement" chip is on. Surfaces only photos
    /// whose AI analysis transcribed a visible measurement readout
    /// (level / moisture meter / ruler etc). ANDed with everything else.
    @State private var measurementsOnly: Bool = false
    /// Recommended-use bucket(s) to keep. Empty = no use-based filtering.
    /// ANDed with the tag filter and the needs-review toggle.
    @State private var recommendedUseFilter: Set<String> = []
    /// Active date-window filter applied to the photo list. `.all` is
    /// the default no-op state. `.custom` carries an inclusive start /
    /// end pair (with timezone-naive day boundaries).
    @State private var dateFilter: DateFilter = .all
    @State private var showingCustomDateSheet: Bool = false

    @State private var showingAIInstructions = false
    @State private var showingTagSelection = false
    @State private var showingExtraVocabulary = false
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
    /// Confirmation gate for the bulk "Renumber by date" action — it
    /// renames every photo's on-disk file so the user gets a chance
    /// to back out before iCloud sees a full project's worth of
    /// renames.
    @State private var confirmingRenumberByDate: Bool = false
    /// Comparison-view anchor — when non-nil, the comparison sheet opens
    /// for this photo's reshoot lineage.
    @State private var comparingPhoto: PhotoTarget?
    /// When the user taps "Reshoot This Photo" we stash the original here
    /// and open the camera. On capture, the resulting photo inherits
    /// location/bearing/bucket/tags from this original and links back.
    @State private var reshootingFromOriginal: Photo?

    /// Non-nil while the "Edit Calibration Distance" alert is presented
    /// for a specific plan — carries the plan whose scale is being
    /// adjusted (the alert uses it to read the current distance and
    /// figure out which plan to write back to on save). Lighter touch
    /// than the full re-calibrate flow because the engineer doesn't
    /// have to re-tap the two endpoints; only the real-world distance
    /// between them changes.
    @State private var editingDistanceFor: FloorPlan?
    @State private var editDistanceDraft: String = ""

    /// Photo id requested by the plan viewer's "Open in project list"
    /// button. Set when the user taps that button; the list's
    /// `ScrollViewReader` watches this for changes and scrolls to the
    /// row, then clears the value so subsequent layout passes don't
    /// re-trigger the scroll.
    @State private var scrollToPhotoID: UUID?

    /// Drives the floating "Distress" FAB → full-screen distress editor
    /// presentation. Routed through state so the FAB can sit anywhere
    /// in the view tree without threading bindings.
    @State private var showingDistressViewer = false

    private struct PhotoTarget: Identifiable {
        let id: UUID
    }

    /// Time-window applied to the photo list. `.all` is the default
    /// pass-through; the other cases scope the visible photos to a
    /// rolling window or an explicit custom range. The active filter
    /// is rendered as a single chip in the filter bar that opens a
    /// menu on tap.
    enum DateFilter: Equatable {
        case all
        case today
        case last7Days
        case last30Days
        case custom(start: Date, end: Date)

        var chipLabel: String {
            switch self {
            case .all:                          return "Any date"
            case .today:                        return "Today"
            case .last7Days:                    return "Last 7 days"
            case .last30Days:                   return "Last 30 days"
            case .custom(let start, let end):
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d"
                let calendar = Calendar.current
                if calendar.isDate(start, inSameDayAs: end) {
                    return formatter.string(from: start)
                }
                return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
            }
        }

        var isActive: Bool {
            if case .all = self { return false }
            return true
        }

        /// Resolve to an inclusive [start, end] pair in the user's
        /// current calendar. `.all` returns nil to signal "no clamp".
        func bounds() -> (start: Date, end: Date)? {
            let calendar = Calendar.current
            let now = Date()
            switch self {
            case .all:
                return nil
            case .today:
                let start = calendar.startOfDay(for: now)
                let end = calendar.date(byAdding: .day, value: 1, to: start)
                    ?? now
                return (start, end)
            case .last7Days:
                let end = calendar.date(byAdding: .day, value: 1,
                                          to: calendar.startOfDay(for: now)) ?? now
                let start = calendar.date(byAdding: .day, value: -7, to: end) ?? now
                return (start, end)
            case .last30Days:
                let end = calendar.date(byAdding: .day, value: 1,
                                          to: calendar.startOfDay(for: now)) ?? now
                let start = calendar.date(byAdding: .day, value: -30, to: end) ?? now
                return (start, end)
            case .custom(let start, let end):
                // Snap start to beginning-of-day, end to start of the
                // following day so the inclusive UI behaves like the
                // engineer expects.
                let s = calendar.startOfDay(for: start)
                let dayAfterEnd = calendar.date(byAdding: .day, value: 1,
                                                  to: calendar.startOfDay(for: end))
                return (s, dayAfterEnd ?? end)
            }
        }
    }

    private var project: Project? {
        store.project(withID: projectID)
    }

    var body: some View {
        Group {
            if let project {
                ScrollViewReader { proxy in
                    List {
                        // Build #5.128.1: per-tab scope filters which
                        // sections render. .all (the default) keeps
                        // today's layout for any non-tabbed caller.
                        // Build #5.129.1: Buckets gets its own tab;
                        // Export folds into More.
                        if scope == .all || scope == .more {
                            metadataSection(project)
                        }
                        if scope == .all || scope == .photos {
                            actionsSection(project)
                        }
                        if scope == .all || scope == .plan {
                            floorPlanSection(project)
                        }
                        if scope == .all || scope == .ai {
                            aiTaggingSection(project)
                        }
                        if scope == .all || scope == .buckets {
                            bucketsSection(project)
                        }
                        if scope == .all || scope == .more {
                            exportSection(project)
                        }
                        if scope == .all || scope == .photos {
                            photosSection(project)
                        }
                    }
                    .onChange(of: scrollToPhotoID) { _, newID in
                        guard let newID else { return }
                        // Defer a tick so the list has settled (closing
                        // the plan viewer dismisses a full-screen cover
                        // that re-runs layout). Then scroll and clear
                        // the request so we don't bounce on every later
                        // re-render.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(newID, anchor: .center)
                            }
                            scrollToPhotoID = nil
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Build #5.128.1: FABs only on the tabs that need
                    // them. Photos + AI get the Camera FAB; Plan gets
                    // the Distress FAB. Export and More render no FAB.
                    // .all (legacy / non-tabbed callers) keeps today's
                    // both-FABs-on-one-screen behavior.
                    scopedFabStack(for: project)
                }
                .modifier(SearchableIfPhotos(
                    show: scope == .all || scope == .photos,
                    searchText: $searchText
                ))
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        AutoSaveIndicator()
                            .environment(store)
                    }
                }
                .fullScreenCover(isPresented: $showingCamera) {
                    CameraView(
                        onCapture: { captured in
                            handleCapture(captured)
                            showingCamera = false
                        },
                        onCancel: {
                            showingCamera = false
                            // Make sure a cancelled reshoot doesn't leak its
                            // anchor into the next regular capture, which
                            // would silently reshoot whatever the engineer
                            // photographed next.
                            reshootingFromOriginal = nil
                        }
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
                    PlanViewerView(
                        projectID: projectID,
                        onOpenPhotoInList: { id in
                            scrollToPhotoID = id
                        }
                    )
                    .environment(store)
                }
                .fullScreenCover(isPresented: $showingDistressViewer) {
                    DistressViewerView(projectID: projectID)
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
                .alert(
                    "Edit Calibration Distance",
                    isPresented: Binding(
                        get: { editingDistanceFor != nil },
                        set: { if !$0 { editingDistanceFor = nil } }
                    ),
                    presenting: editingDistanceFor
                ) { plan in
                    TextField("Distance (feet)", text: $editDistanceDraft)
                        .keyboardType(.decimalPad)
                    Button("Save") {
                        commitEditDistance(for: plan, project: project)
                    }
                    Button("Cancel", role: .cancel) {
                        editingDistanceFor = nil
                    }
                } message: { plan in
                    Text("Update the real-world distance between the two calibration points on \(plan.label). Photos stay at their current spots on the plan; only the scale (and the feet readouts) change.")
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
                .sheet(isPresented: $showingExtraVocabulary) {
                    ProjectExtraVocabularySheet(projectID: projectID)
                        .environment(store)
                }
                .sheet(isPresented: $showingTagSelection) {
                    ProjectTagSelectionSheet(projectID: projectID)
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
                .sheet(isPresented: $showingCustomDateSheet) {
                    CustomDateRangeSheet(current: dateFilter) { newFilter in
                        dateFilter = newFilter
                    }
                    .presentationDetents([.medium])
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
                .sheet(isPresented: $showingBulkTagPicker) {
                    BulkTagPickerSheet(
                        projectID: projectID,
                        photoIDs: selectedPhotoIDs,
                        onApplied: {
                            exitSelectionMode()
                        }
                    )
                    .environment(store)
                }
                .sheet(item: $comparingPhoto) { target in
                    PhotoComparisonView(projectID: projectID,
                                          anchorPhotoID: target.id)
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
                .modifier(PlanAndDeletionModifiers(
                    project: project,
                    projectID: projectID,
                    selectedCount: selectedPhotoIDs.count,
                    planPendingRemoval: $planPendingRemoval,
                    confirmingPlanRemoval: $confirmingPlanRemoval,
                    renamingPlan: $renamingPlan,
                    renamePlanDraft: $renamePlanDraft,
                    pendingPhotoDelete: $pendingPhotoDelete,
                    confirmingBatchDelete: $confirmingBatchDelete,
                    pendingPlanAssignment: $pendingPlanAssignment,
                    onRemovePlan: { plan in
                        _ = store.removeFloorPlan(project, planID: plan.id)
                    },
                    onRenamePlanCommit: {
                        if let plan = renamingPlan {
                            _ = store.renameFloorPlan(project,
                                                       planID: plan.id,
                                                       label: renamePlanDraft)
                        }
                    },
                    onDeletePhoto: { photo in deletePhoto(photo) },
                    onDeleteSelectedPhotos: { deleteSelectedPhotos() },
                    onAssignmentCompleted: {
                        if assignmentFromSelection {
                            assignmentFromSelection = false
                            exitSelectionMode()
                        }
                    }
                ))
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
                EmptyStateView(
                    icon: "questionmark.folder",
                    title: "Project not found",
                    message: "This project may have been deleted."
                )
            }
        }
        .task(id: projectID) {
            await captureLocationIfNeeded()
        }
        .confirmationDialog(
            "Renumber photos by date/time?",
            isPresented: $confirmingRenumberByDate,
            titleVisibility: .visible
        ) {
            Button("Renumber") {
                renumberPhotosByDate()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Photos will be reordered by their capture timestamp and numbered 1…N. Tags, locations, buckets, AI analysis, and groupings stay attached to each photo. The on-disk image files are renamed, which may take a moment on large projects.")
        }
    }

    private func renumberPhotosByDate() {
        guard let project = store.project(withID: projectID) else { return }
        let updated = store.renumberPhotosByDate(project)
        Haptics.confirm()
        toastCenter.post("Renumbered \(updated.photos.count) photos by date.", kind: .info)
    }

    private func deletePhoto(_ photo: Photo) {
        guard let project = store.project(withID: projectID) else { return }
        let seq = photo.sequenceNumber
        let photoID = photo.id
        do {
            _ = try store.deletePhoto(project, photoID: photoID)
            Haptics.confirm()
            toastCenter.post("Moved photo #\(seq) to Trash",
                              kind: .success,
                              actionTitle: "Undo") { [projectID, store] in
                guard let current = store.project(withID: projectID) else { return }
                _ = store.restorePhoto(current, photoID: photoID)
            }
        } catch {
            captureError = "Could not delete photo: \(error.localizedDescription)"
            Haptics.error()
            toastCenter.post("Could not delete photo: \(error.localizedDescription)",
                              kind: .error)
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
        // Reshoot path: inherit the original's location + bearing + bucket
        // + tags directly, skip the Locate sheet entirely. The engineer
        // can still re-locate via the relocate sheet afterwards.
        if let original = reshootingFromOriginal {
            reshootingFromOriginal = nil
            do {
                let updated = try savedReshoot(captured: captured,
                                                 in: project,
                                                 original: original)
                _ = updated
                captureError = nil
            } catch {
                captureError = "Could not save reshoot: \(error.localizedDescription)"
            }
            return
        }
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

    /// Persist a freshly-captured reshoot, inheriting the original's plan
    /// location / heading (when present) plus bucket and confirmed tags
    /// via `ProjectStore.applyReshoot`. Returns the updated project so
    /// the caller can keep its hot copy in sync.
    @discardableResult
    private func savedReshoot(captured: CapturedPhoto,
                               in project: Project,
                               original: Photo) throws -> Project {
        var location: ProjectStore.PhotoLocation?
        if let px = original.planPixelX, let py = original.planPixelY,
           let lx = original.localXFeet, let ly = original.localYFeet {
            location = ProjectStore.PhotoLocation(
                floorPlanID: original.floorPlanID,
                planPixelX: px, planPixelY: py,
                localXFeet: lx, localYFeet: ly,
                headingDegrees: original.headingDegrees,
                groupID: nil,
                isPrimary: true
            )
        }
        var current = try store.addPhoto(to: project,
                                          captured: captured,
                                          location: location)
        // Newly-added photo is the last one in the array.
        if let new = current.photos.last {
            current = store.applyReshoot(to: current,
                                          newPhotoID: new.id,
                                          from: original)
        }
        return current
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

    /// Bottom-right floating-action stack. Threading `project` through
    /// as an explicit parameter (rather than capturing it from the
    /// outer `if let project { ... }` binding inside an overlay
    /// closure) gives SwiftUI a stable dependency to track — without
    /// it, the distress FAB would sometimes only appear after the
    /// view re-rendered due to an unrelated state change (e.g. after
    /// a photo capture).
    @ViewBuilder
    private func fabStack(for project: Project) -> some View {
        VStack(spacing: 12) {
            if !project.floorPlans.isEmpty {
                distressFAB
            }
            takePhotoFAB
        }
    }

    /// Build #5.128.1: scope-aware FAB selector. Each tab in the
    /// workspace shell shows only the FABs that make sense for it:
    ///   .photos / .ai  → Camera (take photo / reshoot)
    ///   .plan          → Distress (mark structural distress on plan)
    ///   .export / .more → no FAB
    ///   .all (legacy)  → both FABs (today's behavior, preserved)
    @ViewBuilder
    private func scopedFabStack(for project: Project) -> some View {
        switch scope {
        case .all:
            fabStack(for: project)
        case .photos, .ai:
            takePhotoFAB
        case .plan:
            if !project.floorPlans.isEmpty {
                distressFAB
            }
        case .buckets, .more:
            EmptyView()
        }
    }

    /// Floating action button anchored to the bottom-right of the
    /// project detail screen. Triggers the camera capture flow — the
    /// same flow the now-removed inline "Take Photo" row used to drive.
    /// Tinted with the user's accent so it picks up theme changes.
    private var takePhotoFAB: some View {
        Button {
            showingCamera = true
            Haptics.tap()
        } label: {
            Image(systemName: "camera.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(AppearanceSettings.currentAccent(), in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 24)
        .accessibilityLabel("Take Photo")
    }

    /// Floating distress-annotation button. Sits above the camera FAB
    /// when a floor plan is active so the engineer can drop structural
    /// distress markers (out-of-plumb door, door not latching, crack in
    /// grade beam, free-style floor crack) on the plan in parallel
    /// with photo pins. Hidden when no plan is set since the editor
    /// needs an active plan to draw on.
    private var distressFAB: some View {
        Button {
            showingDistressViewer = true
            Haptics.tap()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.orange, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
        }
        .padding(.trailing, 24)
        .accessibilityLabel("Mark Distress")
    }

    @ViewBuilder
    private func actionsSection(_ project: Project) -> some View {
        Section("Photo Documentation") {
            // Take Photo is no longer surfaced here — it's a floating
            // camera FAB anchored to the bottom-right of the project
            // detail screen (see `takePhotoFAB`). Keeping the import
            // actions inline so they don't fight the FAB for attention.
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

    /// One staged import waiting to be written to disk. Holds the raw
    /// bytes + parsed capture date so the batch can be sorted by date
    /// before any `importPhoto` calls — that way newly imported photos
    /// take sequence numbers in chronological order regardless of the
    /// picker's selection order.
    private struct StagedImport: Sendable {
        let data: Data
        let date: Date
    }

    /// Sequence numbers go to the photo with the oldest timestamp
    /// first. Ties keep the iteration order so a same-second burst
    /// from the picker stays grouped.
    private func sortedByCaptureDate(_ staged: [StagedImport]) -> [StagedImport] {
        staged.sorted { $0.date < $1.date }
    }

    @MainActor
    private func importFromPhotosLibrary(_ items: [PhotosPickerItem]) async {
        defer {
            photoPickerItems = []
            importing = false
        }
        importing = true

        // Pre-load every selected item so the batch can be ordered by
        // capture date before we start writing files. Holding the bytes
        // in memory adds a temporary footprint (≈ data × items.count)
        // but typical picker batches are small; the alternative would
        // be writing each item to a temp file just to sort, which costs
        // disk + iCloud churn.
        var staged: [StagedImport] = []
        staged.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            importStatus = "Reading \(i + 1) of \(items.count)…"
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let date = ProjectStore.extractCaptureDate(from: data) ?? Date()
            staged.append(StagedImport(data: data, date: date))
        }
        staged = sortedByCaptureDate(staged)

        var added = 0
        var newIDs: Set<UUID> = []
        for (i, entry) in staged.enumerated() {
            importStatus = "Importing \(i + 1) of \(staged.count)…"
            guard let project = store.project(withID: projectID) else { return }
            do {
                let updated = try store.importPhoto(to: project, imageData: entry.data, capturedAt: entry.date)
                if let newID = updated.photos.last?.id { newIDs.insert(newID) }
                added += 1
            } catch {
                captureError = "Import failed: \(error.localizedDescription)"
                importStatus = nil
                return
            }
        }
        importStatus = added > 0 ? "Imported \(added) photo\(added == 1 ? "" : "s")." : nil
        if added > 0,
           let project = store.project(withID: projectID),
           !project.floorPlans.isEmpty {
            pendingPlanAssignment = newIDs
        }
    }

    @MainActor
    private func importFromFiles(_ urls: [URL]) async {
        defer {
            importing = false
        }
        importing = true

        // Keep the import alive across a brief backgrounding event so
        // a cloud download (Dropbox / iCloud / OneDrive) doesn't get
        // killed if the user switches apps mid-import. iOS grants
        // ~30 seconds by default; not enough for huge cloud imports
        // but covers the common "check Messages then come back" case.
        let bgTask = UIApplication.shared.beginBackgroundTask(
            withName: "SitePhoto.ImportFromFiles"
        ) { /* expiration handler — nothing to do; bg task ID is
             cleaned up by the defer below either way */ }
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }

        // Same date-sort pass as photos-library imports. Files may
        // arrive in alphabetical filename order from the document
        // picker, which often isn't chronological.
        //
        // Each file's `Data(contentsOf:)` runs in a detached Task
        // off the main actor — cloud-backed file-provider URLs
        // (Dropbox, iCloud Drive, OneDrive) block until the system
        // finishes downloading, which on the main thread froze the
        // entire UI for the duration of the import. Off-main it
        // also lets the `importStatus = "Reading …"` text actually
        // render each iteration; before this fix, it was being set
        // but never repainted because the runloop never got a turn.
        var staged: [StagedImport] = []
        staged.reserveCapacity(urls.count)
        for (i, url) in urls.enumerated() {
            importStatus = "Reading \(i + 1) of \(urls.count)…"
            guard let entry = await Self.readFileForImport(url: url) else { continue }
            staged.append(entry)
        }
        staged = sortedByCaptureDate(staged)

        var added = 0
        var newIDs: Set<UUID> = []
        for (i, entry) in staged.enumerated() {
            importStatus = "Importing \(i + 1) of \(staged.count)…"
            guard let project = store.project(withID: projectID) else { return }
            do {
                let updated = try store.importPhoto(to: project, imageData: entry.data, capturedAt: entry.date)
                if let newID = updated.photos.last?.id { newIDs.insert(newID) }
                added += 1
            } catch {
                captureError = "Import failed: \(error.localizedDescription)"
                importStatus = nil
                return
            }
        }
        importStatus = added > 0 ? "Imported \(added) photo\(added == 1 ? "" : "s")." : nil
        if added > 0,
           let project = store.project(withID: projectID),
           !project.floorPlans.isEmpty {
            pendingPlanAssignment = newIDs
        }
    }

    /// Read a file-provider URL off the main thread. NSFileCoordinator
    /// is used to coordinate with cloud-backed providers (Dropbox,
    /// iCloud, OneDrive) so the read triggers a proper download-then-
    /// read rather than returning a stub or failing fast. Returns nil
    /// on coordination or read failure — the caller silently skips
    /// that URL and reports the final count.
    ///
    /// `nonisolated` so it doesn't get pinned to the MainActor —
    /// `Task.detached` inside picks a background thread from the
    /// concurrency pool. Captured `url` is a value type; security-
    /// scoped resource access is bracketed inside the detached task.
    private nonisolated static func readFileForImport(url: URL) async -> StagedImport? {
        await Task.detached(priority: .userInitiated) { () -> StagedImport? in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var readData: Data?
            coordinator.coordinate(
                readingItemAt: url,
                options: [],
                error: &coordinationError
            ) { localURL in
                readData = try? Data(contentsOf: localURL)
            }

            guard let data = readData else { return nil }
            let date = ProjectStore.extractCaptureDate(from: data) ?? Date()
            return StagedImport(data: data, date: date)
        }.value
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
        Section("Floor Plans") {
            if project.floorPlans.isEmpty {
                Text("No floor plans set. Photos will be saved without a recorded location until a plan is imported and calibrated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(project.floorPlans) { plan in
                    planRow(project: project, plan: plan)
                }
            }
            Button {
                showingFloorPlanSetup = true
            } label: {
                Label(project.floorPlans.isEmpty
                       ? "Set Up Floor Plan"
                       : "Add Floor Plan",
                      systemImage: "plus.circle")
            }
        }
    }

    /// One row per floor plan. Tapping the row makes that plan active
    /// + opens the viewer; the trailing menu surfaces the existing
    /// per-plan editors (Origin, North, Recalibrate, Replace) and
    /// destructive Remove. Editor sheets read `project.floorPlan` (the
    /// active plan accessor), so we set active before opening.
    @ViewBuilder
    private func planRow(project: Project, plan: FloorPlan) -> some View {
        let isActive = plan.id == project.floorPlan?.id
        Button {
            _ = store.setActiveFloorPlan(project, planID: plan.id)
            showingPlanViewer = true
        } label: {
            HStack(spacing: 10) {
                planThumbnail(project: project, planID: plan.id)
                    .frame(width: 56, height: 42)
                    .clipped()
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.label)
                        .foregroundStyle(.primary)
                    Text(planRowSubtitle(project: project, planID: plan.id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Text("ACTIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                Menu {
                    Button {
                        renamingPlan = plan
                        renamePlanDraft = plan.label
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if !isActive {
                        Button {
                            _ = store.setActiveFloorPlan(project, planID: plan.id)
                        } label: {
                            Label("Set as active", systemImage: "checkmark.circle")
                        }
                    }
                    Divider()
                    Button {
                        _ = store.setActiveFloorPlan(project, planID: plan.id)
                        showingPlanOrigin = true
                    } label: {
                        Label("Set Origin", systemImage: "scope")
                    }
                    Button {
                        _ = store.setActiveFloorPlan(project, planID: plan.id)
                        showingPlanNorth = true
                    } label: {
                        Label("Set North", systemImage: "location.north")
                    }
                    Button {
                        editingDistanceFor = plan
                        editDistanceDraft = trimmedFeet(plan.calibrationDistanceFeet)
                    } label: {
                        Label("Edit Calibration Distance", systemImage: "pencil")
                    }
                    Button {
                        _ = store.setActiveFloorPlan(project, planID: plan.id)
                        showingPlanRecalibrate = true
                    } label: {
                        Label("Re-calibrate Scale", systemImage: "ruler")
                    }
                    Button {
                        _ = store.setActiveFloorPlan(project, planID: plan.id)
                        showingPlanReplace = true
                    } label: {
                        Label("Replace Image", systemImage: "rectangle.2.swap")
                    }
                    Divider()
                    Button(role: .destructive) {
                        planPendingRemoval = plan
                        confirmingPlanRemoval = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Subtitle under the plan label — counts photos placed on this
    /// plan so the engineer can spot at-a-glance which plan is heavily
    /// used vs empty.
    private func planRowSubtitle(project: Project, planID: UUID) -> String {
        let count = project.photos.reduce(0) { $0 + ($1.floorPlanID == planID ? 1 : 0) }
        return "\(count) photo\(count == 1 ? "" : "s")"
    }

    /// Format a feet value for prefilling the Edit Distance text field —
    /// strips the ".0" off whole-foot values so the engineer sees
    /// "12" instead of "12.0" when the plan was calibrated to a clean
    /// number.
    private func trimmedFeet(_ value: Double) -> String {
        if value == floor(value) {
            return String(Int(value))
        }
        return String(value)
    }

    /// Apply the edited calibration distance. Computes the new
    /// pixels-per-foot from the existing pixel-distance between the
    /// original calibration points (recoverable as
    /// `pixelsPerFoot * calibrationDistanceFeet`) and the engineer's
    /// new distance, then routes through `store.recalibrateScale` which
    /// already preserves `planPixelX/Y` and re-derives `localXFeet/Y`
    /// so photos stay anchored to the same point on the drawing.
    private func commitEditDistance(for plan: FloorPlan, project: Project) {
        defer {
            editingDistanceFor = nil
            editDistanceDraft = ""
        }
        guard let newFeet = Double(editDistanceDraft), newFeet > 0 else { return }
        let pixelDistance = plan.pixelsPerFoot * plan.calibrationDistanceFeet
        guard pixelDistance > 0 else { return }
        let newPixelsPerFoot = pixelDistance / newFeet
        store.recalibrateScale(
            project,
            planID: plan.id,
            pixelsPerFoot: newPixelsPerFoot,
            calibrationDistanceFeet: newFeet
        )
    }

    @ViewBuilder
    private func planThumbnail(project: Project, planID: UUID) -> some View {
        if let url = store.floorPlanURL(for: project, planID: planID),
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
            // Filter row is always available so Level / Location / Not-in-bucket
            // / Favorites / Date / Needs-review / bucket chips stay reachable
            // even before any AI tagging has happened. The tag-chip ForEach
            // inside renders nothing when `projectTags` is empty.
            tagFilterBar(allTags: projectTags)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
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
                    Group {
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
                            },
                            onToggleFavorite: {
                                let next = !photo.isFavorite
                                _ = store.setFavorite(project,
                                                       photoID: photo.id,
                                                       isFavorite: next)
                                Haptics.tap()
                            },
                            onReshoot: {
                                reshootingFromOriginal = photo
                                showingCamera = true
                            },
                            onCompare: {
                                comparingPhoto = PhotoTarget(id: photo.id)
                            }
                        )
                        .draggable(PhotoTransferable(
                            url: store.imageURL(for: photo, in: project),
                            suggestedName: photo.imageFilename
                        ))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingPhotoDelete = photo
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    }
                    // Explicit identity so the plan viewer's
                    // "Open in project list" path can `proxy.scrollTo`
                    // the row in any selection / filter state.
                    .id(photo.id)
                }
            }
        } header: {
            photosSectionHeader(project: project, visiblePhotos: visiblePhotos)
        }
        if !project.trashedPhotos.isEmpty {
            trashSection(project)
        }
    }

    @ViewBuilder
    private func trashSection(_ project: Project) -> some View {
        Section {
            ForEach(project.trashedPhotos.sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }) { photo in
                trashRow(photo, project: project)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.caption)
                Text("Trash · \(project.trashedPhotos.count)")
                Spacer()
                Menu {
                    Button(role: .destructive) {
                        emptyTrash(project)
                    } label: {
                        Label("Empty Trash", systemImage: "trash.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .textCase(nil)
            }
        } footer: {
            Text("Trashed photos are permanently deleted 30 days after they're moved here. Restore them anytime before then.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func trashRow(_ photo: Photo, project: Project) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(photo.sequenceNumber) · \(photo.timestamp.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout)
                if let trashedAt = photo.trashedAt {
                    Text("Trashed \(relativeAgo(from: trashedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                restoreTrashed(photo, project: project)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(role: .destructive) {
                permanentlyDelete(photo, project: project)
            } label: {
                Label("Delete", systemImage: "trash.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button {
                restoreTrashed(photo, project: project)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                permanentlyDelete(photo, project: project)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func restoreTrashed(_ photo: Photo, project: Project) {
        _ = store.restorePhoto(project, photoID: photo.id)
        Haptics.confirm()
        toastCenter.post("Restored photo #\(photo.sequenceNumber)", kind: .success)
    }

    private func permanentlyDelete(_ photo: Photo, project: Project) {
        _ = store.permanentlyDeleteFromTrash(project, photoIDs: [photo.id])
        Haptics.confirm()
        toastCenter.post("Deleted permanently", kind: .success)
    }

    private func emptyTrash(_ project: Project) {
        let count = project.trashedPhotos.count
        _ = store.emptyTrash(project)
        Haptics.confirm()
        toastCenter.post("Emptied Trash · \(count) photo\(count == 1 ? "" : "s")",
                          kind: .success)
    }

    private func relativeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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
                    || showOnlyNeedsReview
                    || validationIssuesOnly
                    || favoritesOnly
                    || planFilter != .all
                    || notInBucketOnly
                    || locationFilter != .all
                    || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                    Menu {
                        Button {
                            confirmingRenumberByDate = true
                        } label: {
                            Label("Renumber by date/time",
                                  systemImage: "number.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .textCase(nil)
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func selectionActionRow(visiblePhotos: [Photo]) -> some View {
        // Horizontal ScrollView avoids the surprises that surface when
        // a Layout container (FlowLayout) ends up inside a List row:
        // List rows stretch their content vertically by default, and
        // the bordered button style measures itself against that
        // proposal — which produced huge tall icon-only ovals. With
        // a plain HStack and `.fixedSize(vertical: true)`, each button
        // sizes to its natural width + height and the user can scroll
        // horizontally on narrow devices when all four don't fit.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    showingBucketPicker = true
                } label: {
                    Label("Move to Bucket", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(selectedPhotoIDs.isEmpty)
                if hasFloorPlans {
                    Button {
                        presentSelectedLevelAssignment()
                    } label: {
                        Label("Move to Level", systemImage: "map")
                    }
                    .buttonStyle(.bordered)
                    .tint(.teal)
                    .disabled(selectedPhotoIDs.isEmpty)
                }
                Button {
                    showingBulkTagPicker = true
                } label: {
                    Label("Apply Tag", systemImage: "tag")
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .disabled(selectedPhotoIDs.isEmpty)
                Button {
                    presentSelectedAITagPrompt()
                } label: {
                    Label("Tag with AI", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(selectedPhotoIDs.isEmpty || batchTagTask != nil)
                Button(role: .destructive) {
                    confirmingBatchDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedPhotoIDs.isEmpty)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
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
        let count = ids.count
        do {
            _ = try store.deletePhotos(project, photoIDs: ids)
            exitSelectionMode()
            Haptics.confirm()
            toastCenter.post("Moved \(count) photo\(count == 1 ? "" : "s") to Trash",
                              kind: .success,
                              actionTitle: "Undo") { [projectID, store] in
                guard let current = store.project(withID: projectID) else { return }
                _ = store.restorePhotos(current, photoIDs: ids)
            }
        } catch {
            captureError = "Could not delete photos: \(error.localizedDescription)"
            Haptics.error()
            toastCenter.post("Could not delete photos: \(error.localizedDescription)",
                              kind: .error)
        }
    }

    private func filteredPhotos(_ project: Project) -> [Photo] {
        let tagFilterActive = !activeTagFilters.isEmpty
        let useFilterActive = !recommendedUseFilter.isEmpty
        let bucketFilterActive = !activeBucketFilter.isEmpty
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchActive = !trimmedSearch.isEmpty
        let dateBounds = dateFilter.bounds()
        let planFilterActive = planFilter != .all
        let locationFilterActive = locationFilter != .all
        if !tagFilterActive && !useFilterActive && !bucketFilterActive
            && !showOnlyNeedsReview && !validationIssuesOnly
            && !favoritesOnly && !measurementsOnly
            && !searchActive
            && dateBounds == nil && !planFilterActive && !notInBucketOnly
            && !locationFilterActive {
            return project.photos
        }
        let lcFilters = Set(activeTagFilters.map { $0.lowercased() })
        let lcSearch = trimmedSearch.lowercased()
        return project.photos.filter { photo in
            if let bounds = dateBounds {
                if photo.timestamp < bounds.start || photo.timestamp >= bounds.end {
                    return false
                }
            }
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
            if notInBucketOnly && photo.bucketID != nil {
                return false
            }
            if showOnlyNeedsReview {
                if !needsReview(photo) { return false }
            }
            if validationIssuesOnly {
                if !hasValidationIssue(photo) { return false }
            }
            if favoritesOnly && !photo.isFavorite {
                return false
            }
            if measurementsOnly && !hasMeasurement(photo) {
                return false
            }
            switch planFilter {
            case .all:
                break
            case .unassigned:
                if photo.floorPlanID != nil { return false }
            case .plan(let id):
                if photo.floorPlanID != id { return false }
            }
            switch locationFilter {
            case .all:
                break
            case .located:
                if photo.positionSource == .none { return false }
            case .notLocated:
                if photo.positionSource != .none { return false }
            }
            if searchActive && !photoMatchesSearch(photo, lcSearch: lcSearch) {
                return false
            }
            return true
        }
    }

    /// Location filter pill — `All locations` / `Located` / `Not
    /// located`. Distinct from the level filter (which scopes "which
    /// plan"); this one scopes "has it been placed at all." Renders
    /// as an icon-only pill when inactive and adds a short label only
    /// after the engineer picks a specific filter.
    @ViewBuilder
    private func locationFilterMenu() -> some View {
        Menu {
            Picker("Location", selection: Binding(
                get: { locationFilter },
                set: { locationFilter = $0 }
            )) {
                Text("All locations").tag(LocationFilter.all)
                Text("Located").tag(LocationFilter.located)
                Text("Not located").tag(LocationFilter.notLocated)
            }
        } label: {
            if locationFilter == .all {
                Image(systemName: "location")
                    .font(.caption)
            } else {
                let short: String = {
                    switch locationFilter {
                    case .all:          return ""
                    case .located:      return "Located"
                    case .notLocated:   return "Not located"
                    }
                }()
                Label(short, systemImage: "location")
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(locationFilter == .all ? .secondary : .accentColor)
    }

    /// Level filter pill — "level" being the engineer's term for a
    /// floor plan in their workflow. Icon-only when inactive; icon +
    /// short label when filtered to a specific plan.
    @ViewBuilder
    private func planFilterMenu(project: Project) -> some View {
        Menu {
            Picker("Level", selection: Binding(
                get: { planFilter },
                set: { planFilter = $0 }
            )) {
                Text("All levels").tag(PlanFilter.all)
                Text("No level").tag(PlanFilter.unassigned)
                Divider()
                ForEach(project.floorPlans) { plan in
                    Text(plan.label).tag(PlanFilter.plan(plan.id))
                }
            }
        } label: {
            if planFilter == .all {
                Image(systemName: "map")
                    .font(.caption)
            } else {
                let short: String = {
                    switch planFilter {
                    case .all:           return ""
                    case .unassigned:    return "No level"
                    case .plan(let id):  return project.floorPlan(id: id)?.label ?? "Level"
                    }
                }()
                Label(short, systemImage: "map")
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(planFilter == .all ? .secondary : .accentColor)
    }

    /// Check whether `photo` contains `lcSearch` (already lowercased) in
    /// any of the searchable fields: sequence number, location, caption,
    /// observation, tag labels. Substring match — no fuzzy matching.
    private func photoMatchesSearch(_ photo: Photo, lcSearch: String) -> Bool {
        if "#\(photo.sequenceNumber)".contains(lcSearch) { return true }
        if "\(photo.sequenceNumber)" == lcSearch { return true }
        if let analysis = photo.aiAnalysis {
            if analysis.locationInferred.lowercased().contains(lcSearch) { return true }
        }
        if let caption = photo.effectiveCaption?.lowercased(),
           caption.contains(lcSearch) { return true }
        if let observation = photo.effectiveObservation?.lowercased(),
           observation.contains(lcSearch) { return true }
        for tag in photo.tags {
            if tag.label.lowercased().contains(lcSearch) { return true }
            if let parent = tag.parentTag?.lowercased(),
               parent.contains(lcSearch) { return true }
        }
        return false
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
        // Replacement for the prior `if case .low = a.confidence` check
        // (the worded High/Medium/Low enum is gone). Surface a photo
        // for review when any tag the AI emitted carries a numerical
        // confidence below 0.7 — same spirit as "Low" in the old
        // worded scheme but driven by the per-secondary numbers we
        // already store.
        if a.tagConfidences.values.contains(where: { $0 < 0.7 }) { return true }
        return false
    }

    /// Stricter twin of `needsReview` used by the "Validation issues
    /// only" chip — true only when the validator actually flagged
    /// vocabulary/schema problems on the AI response. Parse failures
    /// are not counted here (they trip `needsReview` instead) because
    /// they're a different failure mode and the engineer triaging
    /// vocab regressions doesn't want them mixed in.
    private func hasValidationIssue(_ photo: Photo) -> Bool {
        guard let a = photo.aiAnalysis, !a.parseFailed else { return false }
        return !a.validationErrors.isEmpty
    }

    /// Date-window chip rendered into the filter bar. Always present —
    /// even when no filter is applied it shows "Any date" so the
    /// engineer can discover the feature. Tapping opens a menu of
    /// preset windows plus a "Custom range…" option that pops a sheet.
    @ViewBuilder
    private var dateFilterChip: some View {
        Menu {
            Button {
                dateFilter = .all
            } label: {
                if case .all = dateFilter {
                    Label("Any date", systemImage: "checkmark")
                } else {
                    Text("Any date")
                }
            }
            Button {
                dateFilter = .today
            } label: {
                if case .today = dateFilter {
                    Label("Today", systemImage: "checkmark")
                } else {
                    Text("Today")
                }
            }
            Button {
                dateFilter = .last7Days
            } label: {
                if case .last7Days = dateFilter {
                    Label("Last 7 days", systemImage: "checkmark")
                } else {
                    Text("Last 7 days")
                }
            }
            Button {
                dateFilter = .last30Days
            } label: {
                if case .last30Days = dateFilter {
                    Label("Last 30 days", systemImage: "checkmark")
                } else {
                    Text("Last 30 days")
                }
            }
            Divider()
            Button("Custom range…") {
                showingCustomDateSheet = true
            }
        } label: {
            if dateFilter.isActive {
                Label(dateFilter.chipLabel, systemImage: "calendar")
                    .font(.caption)
            } else {
                Image(systemName: "calendar")
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(dateFilter.isActive ? .accentColor : .secondary)
    }

    @ViewBuilder
    private func tagFilterBar(allTags: [String]) -> some View {
        let project = store.project(withID: projectID)
        let needsReviewCount = project?.photos.filter { needsReview($0) }.count ?? 0
        let validationIssuesCount = project?.photos.filter { hasValidationIssue($0) }.count ?? 0
        let favoritesCount = project?.photos.filter { $0.isFavorite }.count ?? 0
        let measurementCount = project?.photos.filter { hasMeasurement($0) }.count ?? 0
        let recommendedUseChips = bucketsInUseFor(projectID: projectID)
        let userBuckets = (project?.buckets ?? []).sorted { $0.sortOrder < $1.sortOrder }
        let bucketFilterCount = activeBucketFilter.count
            + recommendedUseFilter.count
            + (notInBucketOnly ? 1 : 0)
        let tagFilterCount = activeTagFilters.count
        let anyFilterActive = !activeTagFilters.isEmpty
            || !recommendedUseFilter.isEmpty
            || !activeBucketFilter.isEmpty
            || showOnlyNeedsReview
            || validationIssuesOnly
            || favoritesOnly
            || measurementsOnly
            || planFilter != .all
            || notInBucketOnly
            || locationFilter != .all
            || dateFilter.isActive

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if anyFilterActive {
                    Button {
                        activeTagFilters.removeAll()
                        recommendedUseFilter.removeAll()
                        activeBucketFilter.removeAll()
                        showOnlyNeedsReview = false
                        validationIssuesOnly = false
                        favoritesOnly = false
                        measurementsOnly = false
                        planFilter = .all
                        notInBucketOnly = false
                        locationFilter = .all
                        dateFilter = .all
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.secondary)
                }
                if let project, !project.floorPlans.isEmpty {
                    planFilterMenu(project: project)
                }
                locationFilterMenu()
                dateFilterChip
                bucketFilterMenu(userBuckets: userBuckets,
                                  recommendedUseChips: recommendedUseChips,
                                  activeCount: bucketFilterCount)
                // Tags / Favorites / Needs-review render unconditionally
                // so the engineer can see every available filter at a
                // glance. Pills are .disabled when the underlying source
                // is empty (no tags yet, no favorites, nothing flagged)
                // — visible but un-clickable until the project produces
                // something to filter by.
                tagFilterMenu(allTags: allTags, activeCount: tagFilterCount)
                    .disabled(allTags.isEmpty)
                Button {
                    favoritesOnly.toggle()
                } label: {
                    Image(systemName: "star.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(favoritesOnly ? .yellow : .secondary)
                .disabled(favoritesCount == 0 && !favoritesOnly)
                Button {
                    showOnlyNeedsReview.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(showOnlyNeedsReview ? .orange : .secondary)
                .disabled(needsReviewCount == 0 && !showOnlyNeedsReview)
                Button {
                    validationIssuesOnly.toggle()
                } label: {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(validationIssuesOnly ? .red : .secondary)
                .disabled(validationIssuesCount == 0 && !validationIssuesOnly)
                Button {
                    measurementsOnly.toggle()
                } label: {
                    Image(systemName: "ruler")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(measurementsOnly ? .teal : .secondary)
                .disabled(measurementCount == 0 && !measurementsOnly)
            }
            .padding(.vertical, 2)
        }
    }

    /// Whether the photo's AI analysis transcribed a visible measurement
    /// readout. A non-empty `measurementVisible` means the model read a
    /// number off the image (level / moisture meter / ruler etc.) —
    /// surfaces the photo in the "Has measurement" filter chip even when
    /// the auto-synthesised "Measurement reading" tag has been edited
    /// off by the engineer.
    private func hasMeasurement(_ photo: Photo) -> Bool {
        guard let m = photo.aiAnalysis?.measurementVisible else { return false }
        return !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Consolidated bucket filter pill. Shows a folder icon plus an
    /// active-count badge; tapping opens a menu with:
    ///   • "Not in a bucket" toggle (mutually exclusive with picking
    ///     specific user buckets — selecting one clears the other so
    ///     the filter never produces an impossible intersection).
    ///   • User buckets (multi-select with checkmarks).
    ///   • AI categories from `recommendedUse` (multi-select).
    @ViewBuilder
    private func bucketFilterMenu(userBuckets: [Bucket],
                                    recommendedUseChips: [String],
                                    activeCount: Int) -> some View {
        Menu {
            Button {
                notInBucketOnly.toggle()
                if notInBucketOnly {
                    activeBucketFilter.removeAll()
                }
            } label: {
                if notInBucketOnly {
                    Label("Not in a bucket", systemImage: "checkmark")
                } else {
                    Text("Not in a bucket")
                }
            }
            if !userBuckets.isEmpty {
                Section("Buckets") {
                    ForEach(userBuckets) { bucket in
                        let on = activeBucketFilter.contains(bucket.id)
                        Button {
                            if on {
                                activeBucketFilter.remove(bucket.id)
                            } else {
                                activeBucketFilter.insert(bucket.id)
                                notInBucketOnly = false
                            }
                        } label: {
                            if on {
                                Label(bucket.name, systemImage: "checkmark")
                            } else {
                                Text(bucket.name)
                            }
                        }
                    }
                }
            }
            if !recommendedUseChips.isEmpty {
                Section("Photo use") {
                    ForEach(recommendedUseChips, id: \.self) { bucket in
                        let on = recommendedUseFilter.contains(bucket)
                        Button {
                            if on {
                                recommendedUseFilter.remove(bucket)
                            } else {
                                recommendedUseFilter.insert(bucket)
                            }
                        } label: {
                            if on {
                                Label(bucket, systemImage: "checkmark")
                            } else {
                                Text(bucket)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: activeCount > 0 ? "folder.fill" : "folder")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(activeCount > 0 ? .accentColor : .secondary)
    }

    /// Consolidated tag filter pill. Tag icon flips to its filled
    /// variant + accent tint when any tag filter is on; the menu lists
    /// every confirmed tag in the project with a multi-select
    /// checkmark UI.
    @ViewBuilder
    private func tagFilterMenu(allTags: [String], activeCount: Int) -> some View {
        Menu {
            ForEach(allTags, id: \.self) { tag in
                let on = activeTagFilters.contains(tag)
                Button {
                    if on { activeTagFilters.remove(tag) }
                    else  { activeTagFilters.insert(tag) }
                } label: {
                    if on {
                        Label(tag, systemImage: "checkmark")
                    } else {
                        Text(tag)
                    }
                }
            }
        } label: {
            Image(systemName: activeCount > 0 ? "tag.fill" : "tag")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(activeCount > 0 ? .accentColor : .secondary)
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
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Export Project")
                        Text("Choose PDF report or folder by bucket")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(project.photos.isEmpty)
        }
    }

    // MARK: - AI Tagging section

    @ViewBuilder
    private func aiTaggingSection(_ project: Project) -> some View {
        let untaggedCount = project.photos.filter { $0.tags.isEmpty }.count
        let taggedCount   = project.photos.count - untaggedCount

        // Build #5.130.1: split today's monolithic AI Tagging section
        // into three visual subgroups (Vocabulary / Notes / Run) so the
        // user can find what they're looking for at a glance. The
        // misplaced "Filter photos by tag…" button is removed (filtering
        // already lives in the photos-section filter chip bar).
        Section {
            Button {
                showingTagSelection = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Tags")
                        Text(tagSelectionSubtitle(for: project))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: project.tagSelection?.isEmpty == false
                          ? "tag.fill" : "tag")
                }
            }

            Button {
                showingExtraVocabulary = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Job-Specific Vocabulary")
                        Text(extraVocabSubtitle(for: project))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: hasExtras(project)
                          ? "tag.circle.fill" : "tag.circle")
                }
            }
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("AI Tags scopes which contexts and tags this project sends to Claude. Job-Specific Vocabulary appends project-only tags without changing the team library.")
        }

        Section {
            Button {
                showingAIInstructions = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Notes")
                        Text(aiNotesSubtitle(for: project))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: hasNotes(project)
                          ? "note.text" : "square.dashed")
                }
            }
        } header: {
            Text("Notes")
        } footer: {
            Text("One-off guidance appended to the AI prompt for this project (e.g. \"focus on the east elevation\"). Templates available from inside the editor.")
        }

        Section {
            Button {
                batchTagConfirm = BatchTagPrompt(
                    candidateCount: untaggedCount,
                    skippedCount: taggedCount,
                    skipAlreadyTagged: true,
                    candidatesWithExistingTags: 0,
                    onlyPhotoIDs: nil
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
                        candidatesWithExistingTags: taggedCount,
                        onlyPhotoIDs: nil
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
            Text("Run")
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

    /// Subtitle under the "AI Tags" row — surfaces how much vocabulary
    /// the project has scoped for AI tagging without having to open the
    /// picker.
    private func tagSelectionSubtitle(for project: Project) -> String {
        guard let selection = project.tagSelection, !selection.isEmpty else {
            return "Not configured — AI tagging is disabled until you pick at least one investigation context."
        }
        let ctxCount = selection.contextIDs.count
        let primaryCount = selection.primariesByContext.values
            .reduce(0) { $0 + $1.count }
        return "\(ctxCount) context\(ctxCount == 1 ? "" : "s"), \(primaryCount) primary tag\(primaryCount == 1 ? "" : "s")"
    }

    /// Subtitle under the "AI Notes" row — shows whether any notes are
    /// in play, but doesn't expose the full text.
    private func aiNotesSubtitle(for project: Project) -> String {
        hasNotes(project)
            ? "Custom notes appended to the AI prompt for this project"
            : "Optional one-off guidance appended to the AI prompt"
    }

    private func hasNotes(_ project: Project) -> Bool {
        let trimmed = (project.aiInstructions ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    /// Subtitle under the "Job-Specific Vocabulary" row — shows the
    /// number of project-scoped primaries / secondaries Claude will
    /// see on top of the main library vocabulary.
    private func extraVocabSubtitle(for project: Project) -> String {
        guard let extras = project.aiExtraVocabulary, !extras.isEmpty else {
            return "Optional project-only tags appended to the AI vocabulary"
        }
        let pCount = extras.primaries.count
        let sCount = extras.secondaryCount
        return "\(pCount) primar\(pCount == 1 ? "y" : "ies"), \(sCount) secondar\(sCount == 1 ? "y" : "ies")"
    }

    private func hasExtras(_ project: Project) -> Bool {
        !(project.aiExtraVocabulary?.isEmpty ?? true)
    }

    /// Build a `BatchTagPrompt` for the multi-select "Tag with AI"
    /// action. `skipAlreadyTagged` is false because the user explicitly
    /// picked these photos — even if some already carry tags, the
    /// confirmation dialog surfaces an Add/Overwrite choice so the user
    /// stays in control of the merge.
    /// True when the project has at least one floor plan — gates the
    /// "Move to Level" multi-select button so single-plan-less
    /// projects don't show a no-op picker.
    private var hasFloorPlans: Bool {
        guard let project = store.project(withID: projectID) else { return false }
        return !project.floorPlans.isEmpty
    }

    /// Open the level-assignment sheet against the currently-selected
    /// photos. Reuses the same `FloorPlanAssignmentSheet` the
    /// import-time flow already uses; flag `assignmentFromSelection`
    /// so completion also exits select mode.
    private func presentSelectedLevelAssignment() {
        guard !selectedPhotoIDs.isEmpty else { return }
        assignmentFromSelection = true
        pendingPlanAssignment = selectedPhotoIDs
    }

    private func presentSelectedAITagPrompt() {
        guard !selectedPhotoIDs.isEmpty else { return }
        guard let project else { return }
        let selectedPhotos = project.photos.filter { selectedPhotoIDs.contains($0.id) }
        let existingTaggedCount = selectedPhotos.filter { !$0.tags.isEmpty }.count
        batchTagConfirm = BatchTagPrompt(
            candidateCount: selectedPhotos.count,
            skippedCount: 0,
            skipAlreadyTagged: false,
            candidatesWithExistingTags: existingTaggedCount,
            onlyPhotoIDs: selectedPhotoIDs
        )
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
        let onlyIDs = prompt.onlyPhotoIDs
        // The multi-select "Tag with AI" path passes a specific photo
        // set; exit selection mode immediately so the user sees the
        // progress overlay on top of the normal grid rather than the
        // selection toolbar.
        if onlyIDs != nil {
            exitSelectionMode()
        }
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
                    onlyPhotoIDs: onlyIDs,
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
    /// When set, the batch runs only against these specific photo IDs
    /// (the multi-select "Tag with AI" path). When nil, the batch
    /// targets every untagged photo in the project (the project-wide
    /// "Auto-tag untagged photos with AI" path).
    let onlyPhotoIDs: Set<UUID>?
}

/// Bundles the four batch-tagging-related view modifiers (3 alerts + 1
/// overlay) into a single `ViewModifier`. Keeps `ProjectDetailView.body`
/// short enough for the SwiftUI type checker to handle without timing out.
/// Bundles five view modifiers (1 confirmationDialog + 3 alerts + 1
/// sheet) into a single `ViewModifier`. Cuts the type-check budget
/// `ProjectDetailView.body` consumes — without this, the body's modifier
/// chain trips Swift's "compiler is unable to type-check this
/// expression in reasonable time" wall.
fileprivate struct PlanAndDeletionModifiers: ViewModifier {
    let project: Project
    let projectID: UUID
    let selectedCount: Int
    @Binding var planPendingRemoval: FloorPlan?
    @Binding var confirmingPlanRemoval: Bool
    @Binding var renamingPlan: FloorPlan?
    @Binding var renamePlanDraft: String
    @Binding var pendingPhotoDelete: Photo?
    @Binding var confirmingBatchDelete: Bool
    @Binding var pendingPlanAssignment: Set<UUID>
    let onRemovePlan: (FloorPlan) -> Void
    let onRenamePlanCommit: () -> Void
    let onDeletePhoto: (Photo) -> Void
    let onDeleteSelectedPhotos: () -> Void
    /// Fires after the assignment sheet dismisses successfully. The
    /// caller uses this to exit multi-select mode when the assignment
    /// came from the "Move to Level" path; the import-time path has
    /// nothing to do here.
    let onAssignmentCompleted: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                removePlanTitle,
                isPresented: $confirmingPlanRemoval,
                titleVisibility: .visible,
                presenting: planPendingRemoval
            ) { plan in
                Button("Remove", role: .destructive) {
                    onRemovePlan(plan)
                    planPendingRemoval = nil
                }
                Button("Cancel", role: .cancel) {
                    planPendingRemoval = nil
                }
            } message: { plan in
                Text(removePlanMessage(for: plan))
            }
            .alert(
                "Rename plan",
                isPresented: renamingPlanIsPresented
            ) {
                TextField("Name", text: $renamePlanDraft)
                    .textInputAutocapitalization(.words)
                Button("Save") {
                    onRenamePlanCommit()
                    renamingPlan = nil
                    renamePlanDraft = ""
                }
                Button("Cancel", role: .cancel) {
                    renamingPlan = nil
                    renamePlanDraft = ""
                }
            }
            .alert(
                "Delete photo?",
                isPresented: pendingPhotoDeleteIsPresented,
                presenting: pendingPhotoDelete
            ) { photo in
                Button("Delete", role: .destructive) {
                    onDeletePhoto(photo)
                    pendingPhotoDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingPhotoDelete = nil
                }
            } message: { photo in
                Text("Photo #\(photo.sequenceNumber) will be deleted and the remaining photos renumbered. This cannot be undone.")
            }
            .alert(
                batchDeleteTitle,
                isPresented: $confirmingBatchDelete
            ) {
                Button("Delete", role: .destructive) {
                    onDeleteSelectedPhotos()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The selected photos will be deleted and the remaining photos will be renumbered. This cannot be undone.")
            }
            .sheet(isPresented: planAssignmentIsPresented) {
                FloorPlanAssignmentSheet(
                    projectID: projectID,
                    photoIDs: pendingPlanAssignment,
                    onCompleted: {
                        pendingPlanAssignment = []
                        onAssignmentCompleted()
                    }
                )
            }
    }

    // MARK: - Computed helpers (extracted so the modifier chain above
    // stays simple enough for the SwiftUI type checker).

    private var renamingPlanIsPresented: Binding<Bool> {
        Binding(
            get: { renamingPlan != nil },
            set: { if !$0 { renamingPlan = nil } }
        )
    }

    private var pendingPhotoDeleteIsPresented: Binding<Bool> {
        Binding(
            get: { pendingPhotoDelete != nil },
            set: { if !$0 { pendingPhotoDelete = nil } }
        )
    }

    private var planAssignmentIsPresented: Binding<Bool> {
        Binding(
            get: { !pendingPlanAssignment.isEmpty },
            set: { if !$0 { pendingPlanAssignment = [] } }
        )
    }

    private var removePlanTitle: String {
        if let plan = planPendingRemoval {
            return "Remove \"\(plan.label)\"?"
        }
        return "Remove plan?"
    }

    private var batchDeleteTitle: String {
        let n = selectedCount
        let suffix = n == 1 ? "" : "s"
        return "Delete \(n) photo\(suffix)?"
    }

    /// Plan-deletion alert body. Counts photos placed on this plan so
    /// the engineer knows what's about to detach.
    private func removePlanMessage(for plan: FloorPlan) -> String {
        let count = project.photos.reduce(0) {
            $0 + ($1.floorPlanID == plan.id ? 1 : 0)
        }
        if count == 0 {
            return "The plan image will be deleted from this project."
        }
        let suffix = count == 1 ? "" : "s"
        return "The plan image will be deleted. \(count) photo\(suffix) placed on this plan will be detached but their saved real-world coordinates are preserved — adding a new plan with calibration + origin re-derives their positions automatically."
    }
}

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
        let scopeWord = (confirm?.onlyPhotoIDs != nil) ? "selected " : ""
        return "Run AI tagging on \(n) \(scopeWord)photo\(n == 1 ? "" : "s")?"
    }

    private func confirmMessage(for prompt: BatchTagPrompt) -> String {
        let cost = costFor(prompt.candidateCount)
        var lines: [String] = []
        if prompt.onlyPhotoIDs != nil {
            lines.append("Each selected photo is sent to Claude vision and every returned tag is auto-accepted. Estimated cost: ~\(cost).")
        } else {
            lines.append("Each photo is sent to Claude vision and every returned tag is auto-accepted. Estimated cost: ~\(cost).")
        }

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
    var onToggleFavorite: (() -> Void)? = nil
    var onReshoot: (() -> Void)? = nil
    var onCompare: (() -> Void)? = nil
    @AppStorage("sitephoto.tagConfidenceThreshold")
    private var tagConfidenceThreshold: Double = 0.5

    /// Compact timestamp formatter cached once per view type — used on
    /// every row, so allocating a new `DateFormatter` per render would
    /// noticeably affect scroll performance on big project lists. The
    /// `h:mm a` token respects the user's locale's AM/PM marker; 24-hour
    /// locales render `13:12`-style automatically.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy '@' h:mm a"
        return f
    }()

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
            let lr = ControlledVocabulary.primaryRank(lParent)
            let rr = ControlledVocabulary.primaryRank(rParent)
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
                    .frame(width: 144, height: 108)
                    .clipped()
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(photo.sequenceNumber)")
                        .font(.headline.monospaced())
                        .layoutPriority(1)
                    if photo.groupID != nil {
                        // Stacked-folders glyph mirrors the group-picker
                        // toolbar; filled variant marks the lead so it
                        // still reads at a glance.
                        Image(systemName: photo.isPrimary
                              ? "rectangle.stack.fill"
                              : "rectangle.stack")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                    let livePending = photo.pendingSuggestions.filter { $0.source == .claude }
                    if !livePending.isEmpty {
                        badge(text: "AI \(livePending.count)", color: .purple)
                    }
                }
                Text(Self.timestampFormatter.string(from: photo.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if let bucket = bucketFor(photo) {
                    bucketBadge(bucket)
                }
            }
            Spacer()
            VStack(spacing: 6) {
                if let onToggleFavorite {
                    Button {
                        onToggleFavorite()
                    } label: {
                        Image(systemName: photo.isFavorite ? "star.fill" : "star")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(photo.isFavorite ? .yellow : .secondary)
                    .accessibilityLabel(photo.isFavorite
                                         ? "Remove from favorites"
                                         : "Add to favorites")
                }
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
                        Image(systemName: "location")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    // Grey when the photo has no plan position yet; blue
                    // once it's been placed. Same tap target either way —
                    // RelocateSheet handles both "set initial" and
                    // "change existing" via its pre-fill logic.
                    .tint(isUnlocated ? .secondary : .blue)
                    .accessibilityLabel(isUnlocated ? "Add Location" : "Change Location")
                }
                if onReshoot != nil || onCompare != nil {
                    rowOverflowMenu
                }
            }
        }
    }

    /// Tiny `…` menu sitting under the per-row action stack. Keeps the
    /// reshoot / comparison entry points discoverable without crowding
    /// the row with two more icon buttons.
    @ViewBuilder
    private var rowOverflowMenu: some View {
        Menu {
            if let onReshoot {
                Button {
                    onReshoot()
                } label: {
                    Label("Reshoot This Photo", systemImage: "camera.rotate")
                }
            }
            if let onCompare, hasReshootLineage {
                Button {
                    onCompare()
                } label: {
                    Label("Compare with Reshoots", systemImage: "rectangle.on.rectangle.angled")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.secondary)
        .accessibilityLabel("More actions")
    }

    /// True when the photo is the root of a reshoot lineage *or* is itself
    /// a reshoot of something else — either way the compare view has more
    /// than one frame to show.
    private var hasReshootLineage: Bool {
        if photo.reshootsPhotoID != nil { return true }
        return project.photos.contains(where: { $0.reshootsPhotoID == photo.id })
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

// ---------------------------------------------------------------------
// Conditional search bar (Build #5.128.1)
// ---------------------------------------------------------------------

/// Applies `.searchable` only when `show` is true. Used by the workspace
/// shell to keep the search bar on the Photos tab and hide it from the
/// Plan / AI / Export / More tabs (where it has nothing to search).
///
/// Implemented as a ViewModifier because SwiftUI's built-in modifier
/// chain has no inline conditional and chaining `if show { .searchable }`
/// inside a builder breaks the resulting type.
private struct SearchableIfPhotos: ViewModifier {
    let show: Bool
    @Binding var searchText: String

    func body(content: Content) -> some View {
        if show {
            content.searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search photos by tag, caption, or #"
            )
        } else {
            content
        }
    }
}
