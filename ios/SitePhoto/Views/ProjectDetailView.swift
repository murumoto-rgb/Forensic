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
    case buckets   // buckets (Build #5.129.1: Buckets gets its own tab)
    case more      // metadata + export (Build #5.129.1: Export folds here)
}

struct ProjectDetailView: View {
    @Environment(ProjectStore.self) var store
    @Environment(LocationService.self) var location
    @Environment(ToastCenter.self) var toastCenter
    @AppStorage("sitephoto.tagConfidenceThreshold")
    var tagConfidenceThreshold: Double = 0.5
    /// Photos tab layout (Build #6.29.1): "list" (the classic rows)
    /// or "grid" (3-up thumbnails). Stored as the raw string so
    /// @AppStorage can persist it; `photoLayout` in the Photos
    /// extension wraps it in the enum.
    @AppStorage("sitephoto.photoLayout")
    var photoLayoutRaw: String = "list"
    let projectID: UUID
    var scope: ProjectDetailScope = .all

    @State var addressLookupRunning = false
    @State var locationError: String?
    @State var showingCamera = false
    @State var captureError: String?
    @State var showingFloorPlanSetup = false
    @State var confirmingPlanRemoval = false
    @State var planPendingRemoval: FloorPlan?
    @State var renamingPlan: FloorPlan?
    @State var renamePlanDraft: String = ""
    /// Photo IDs that just landed via Photos-library or Files import,
    /// OR were picked in multi-select before the engineer tapped "Move
    /// to Level". Drives the `FloorPlanAssignmentSheet` presentation;
    /// cleared after the sheet dismisses. `assignmentFromSelection`
    /// distinguishes the two paths so the multi-select case can also
    /// exit selection mode on completion.
    @State var pendingPlanAssignment: Set<UUID> = []
    @State var assignmentFromSelection: Bool = false
    /// All photo-list filters in one value (Build #6.5.1 —
    /// consolidated from 11 independent `@State` vars). One reset
    /// point, one `isActive` answer, and one `Equatable` key for the
    /// `filteredPhotos` memo. Per-field docs live on
    /// `PhotoFilterState` below.
    @State var filters = PhotoFilterState()

    /// Memo for `filteredPhotos(_:)` (Build #6.5.1). The box is a
    /// class held in `@State` so `body` can update its contents
    /// without triggering "modifying state during view update" — a
    /// mutation of the box doesn't invalidate the view.
    struct FilterMemoKey: Equatable {
        let filters: PhotoFilterState
        let threshold: Double
        let photosCount: Int
        let stamp: Date?
    }
    final class FilterMemoBox {
        var key: FilterMemoKey?
        var ids: [UUID] = []
    }
    @State var filterMemo = FilterMemoBox()
    enum LocationFilter: Hashable {
        case all
        case located
        case notLocated
    }
    enum PlanFilter: Hashable {
        case all
        case unassigned
        case plan(UUID)
    }
    @State var pendingPhotos: [CapturedPhoto] = []
    @State var showingLocate = false
    @State var showingPlanViewer = false
    @State var showingPlanOrigin = false
    @State var showingPlanNorth = false
    @State var showingPlanReplace = false
    @State var showingPlanRecalibrate = false
    @State var showingExport = false

    @State var photoPickerItems: [PhotosPickerItem] = []
    @State var showingFileImporter = false
    @State var importing = false
    @State var importStatus: String?
    @State var relocatingPhoto: PhotoTarget?
    @State var pendingPhotoDelete: Photo?
    /// True when the photos list is in multi-select / batch-delete mode.
    /// While on, rows show a check circle and tapping toggles selection
    /// instead of opening the tag editor; the per-row swipe-to-delete is
    /// also suspended.
    @State var selectionMode: Bool = false
    @State var selectedPhotoIDs: Set<UUID> = []
    @State var confirmingBatchDelete: Bool = false
    @State var showingBucketManager: Bool = false
    @State var showingBucketPicker: Bool = false
    @State var showingBulkTagPicker: Bool = false
    @State var showingAddressEditor = false
    @State var addressUpdating = false
    @State var taggingPhoto: PhotoTarget?
    @State var showingCustomDateSheet: Bool = false

    @State var showingAIInstructions = false
    @State var showingTagSelection = false
    @State var showingExtraVocabulary = false
    @State var showingTagFilter = false
    @State var showingClearAITags = false
    @State var batchTagConfirm: BatchTagPrompt?
    @State var batchTagTask: Task<Void, Never>?
    @State var batchTagProgressCurrent: Int = 0
    @State var batchTagProgressTotal: Int = 0
    @State var batchTagProgressSeq: Int?
    @State var batchTagError: String?
    @State var batchTagSummary: String?
    @State var batchTagFailureReport: BatchTagFailureReport?
    @State var batchBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// Confirmation gate for the bulk "Renumber by date" action — it
    /// renames every photo's on-disk file so the user gets a chance
    /// to back out before iCloud sees a full project's worth of
    /// renames.
    @State var confirmingRenumberByDate: Bool = false

    /// Build #6.1.1: confirm dialog for the More tab's "Lock Project
    /// (Finalize)" action. Locking disables editing on every device,
    /// so it warrants an explicit confirm; unlocking does not.
    @State var confirmingLock: Bool = false
    /// Comparison-view anchor — when non-nil, the comparison sheet opens
    /// for this photo's reshoot lineage.
    @State var comparingPhoto: PhotoTarget?
    /// When the user taps "Reshoot This Photo" we stash the original here
    /// and open the camera. On capture, the resulting photo inherits
    /// location/bearing/bucket/tags from this original and links back.
    @State var reshootingFromOriginal: Photo?

    /// Non-nil while the "Edit Calibration Distance" alert is presented
    /// for a specific plan — carries the plan whose scale is being
    /// adjusted (the alert uses it to read the current distance and
    /// figure out which plan to write back to on save). Lighter touch
    /// than the full re-calibrate flow because the engineer doesn't
    /// have to re-tap the two endpoints; only the real-world distance
    /// between them changes.
    @State var editingDistanceFor: FloorPlan?
    @State var editDistanceDraft: String = ""

    /// Photo id requested by the plan viewer's "Open in project list"
    /// button. Set when the user taps that button; the list's
    /// `ScrollViewReader` watches this for changes and scrolls to the
    /// row, then clears the value so subsequent layout passes don't
    /// re-trigger the scroll.
    @State var scrollToPhotoID: UUID?

    /// Drives the floating "Distress" FAB → full-screen distress editor
    /// presentation. Routed through state so the FAB can sit anywhere
    /// in the view tree without threading bindings.
    @State var showingDistressViewer = false

    struct PhotoTarget: Identifiable {
        let id: UUID
    }

    /// The photo-list filter state, consolidated from 11 independent
    /// `@State` vars (Build #6.5.1). All filters AND together.
    struct PhotoFilterState: Equatable {
        /// Tags active as filters. Empty = no filter. Compared
        /// case-insensitively; a photo must carry every active tag.
        var activeTagFilters: Set<String> = []
        /// Recommended-use bucket(s) to keep. Empty = no filtering.
        var recommendedUseFilter: Set<String> = []
        /// Bucket IDs active as filters. Empty = none. OR semantics
        /// across selected buckets.
        var activeBucketFilter: Set<UUID> = []
        /// Surfaces only photos where `isFavorite == true`.
        var favoritesOnly: Bool = false
        /// Surfaces every photo where Claude self-rated low
        /// confidence, wrote a reviewer flag, or failed validation.
        var showOnlyNeedsReview: Bool = false
        /// Stricter than `showOnlyNeedsReview` — only photos whose AI
        /// response tripped a vocabulary or schema rule in
        /// `AIResponseValidator`.
        var validationIssuesOnly: Bool = false
        /// Only photos whose AI analysis transcribed a visible
        /// measurement readout (level / moisture meter / ruler etc).
        var measurementsOnly: Bool = false
        /// Scope by which plan a photo is assigned to (or unassigned).
        var planFilter: PlanFilter = .all
        /// Show only photos with no bucket assigned — triage aid for
        /// fresh imports.
        var notInBucketOnly: Bool = false
        /// Located / not-located pill. Orthogonal to `planFilter`
        /// (which plan vs whether placed at all).
        var locationFilter: LocationFilter = .all
        /// Date-window filter. `.all` is the no-op default.
        var dateFilter: DateFilter = .all
        /// Search text. Matched against sequence number, location,
        /// captions, observations, and tag labels.
        var searchText: String = ""

        var trimmedSearch: String {
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Human-readable list of the active filters, for the
        /// empty-result callout — e.g. "tags (Crack, Spalling) ·
        /// favorites · date (Today)".
        var summaryDescription: String {
            var parts: [String] = []
            if !activeTagFilters.isEmpty {
                parts.append("tags (\(activeTagFilters.sorted().joined(separator: ", ")))")
            }
            if !recommendedUseFilter.isEmpty { parts.append("recommended use") }
            if !activeBucketFilter.isEmpty { parts.append("bucket") }
            if favoritesOnly { parts.append("favorites") }
            if showOnlyNeedsReview { parts.append("needs review") }
            if validationIssuesOnly { parts.append("validation issues") }
            if measurementsOnly { parts.append("has measurement") }
            if planFilter != .all { parts.append("level") }
            if notInBucketOnly { parts.append("not in a bucket") }
            if locationFilter != .all { parts.append("location") }
            if dateFilter != .all { parts.append("date (\(dateFilter.chipLabel))") }
            if !trimmedSearch.isEmpty { parts.append("search “\(trimmedSearch)”") }
            return parts.joined(separator: " · ")
        }

        /// True when anything is narrowing the photo list — drives
        /// the "· N shown" header annotation and the memo fast path.
        var isActive: Bool {
            !activeTagFilters.isEmpty
                || !recommendedUseFilter.isEmpty
                || !activeBucketFilter.isEmpty
                || favoritesOnly
                || showOnlyNeedsReview
                || validationIssuesOnly
                || measurementsOnly
                || planFilter != .all
                || notInBucketOnly
                || locationFilter != .all
                || dateFilter != .all
                || !trimmedSearch.isEmpty
        }
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

    var project: Project? {
        store.project(withID: projectID)
    }

    var body: some View {
        Group {
            if let project {
                ScrollViewReader { proxy in
                    List {
                        scopedSections(project)
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
                    searchText: $filters.searchText
                ))
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        AutoSaveIndicator(projectID: projectID)
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
                    CustomDateRangeSheet(current: filters.dateFilter) { newFilter in
                        filters.dateFilter = newFilter
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
                    progressThumbURL: batchProgressThumbURL(project),
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

    /// Thumbnail URL for the batch-tag progress overlay's in-flight
    /// photo (Build #6.9.1). Resolved by sequence number — the
    /// progress callback reports seq, not ID. O(n) once per progress
    /// tick (~1/photo), not per frame.
    func batchProgressThumbURL(_ project: Project) -> URL? {
        guard let seq = batchTagProgressSeq,
              let photo = project.photos.first(where: { $0.sequenceNumber == seq })
        else { return nil }
        return store.thumbnailURL(for: photo, in: project)
    }

    func renumberPhotosByDate() {
        guard let project = store.project(withID: projectID) else { return }
        let updated = store.renumberPhotosByDate(project)
        Haptics.confirm()
        toastCenter.post("Renumbered \(updated.photos.count) photos by date.", kind: .info)
    }

    func deletePhoto(_ photo: Photo) {
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
    func applyNewAddress(_ raw: String) async {
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

    func handleCapture(_ captured: CapturedPhoto) {
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
    func savedReshoot(captured: CapturedPhoto,
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

    /// Build #5.132.1: extracted the scope-conditional section list out
    /// of the `List { … }` literal into its own `@ViewBuilder` function.
    /// Seven `if` branches inline inside `Group { ScrollViewReader {
    /// List { … } } }` made the whole `body` type-check as one
    /// expression, which Swift rejected with "expression too complex"
    /// (and cascaded into bogus "no member 'buckets'" errors on the
    /// enum). Pulling them into a dedicated function gives the type
    /// checker a small, independent context. The scope booleans are
    /// precomputed so each branch is a trivial `if`.
    @ViewBuilder
    func scopedSections(_ project: Project) -> some View {
        let showPhotos = scope == .all || scope == .photos
        let showPlan   = scope == .all || scope == .plan
        let showAI     = scope == .all || scope == .ai
        let showBuckets = scope == .all || scope == .buckets
        let showMore   = scope == .all || scope == .more
        // Build #6.1.1: a locked/finalized project (`Project.isFrozen`,
        // shipped in the #5.126.1 schema but UI-less on iOS until now)
        // is read-only. Every tab shows the banner; edit-entry sections
        // (import, AI runs) disappear; viewing + export stay available.
        // `ProjectStore.save(_:)` backstops any path left visible.
        let frozen = store.isReadOnly(project)

        if frozen {
            frozenBannerSection
        }
        if showMore {
            metadataSection(project)
            ProjectWorkflowSection(projectID: projectID)
        }
        if showPhotos && !frozen {
            actionsSection(project)
        }
        if showPlan {
            floorPlanSection(project)
        }
        if showAI && !frozen {
            aiTaggingSection(project)
        }
        if showBuckets || showMore {
            bucketsSection(project)
        }
        if showMore && store.canManageLock(project) {
            projectLockSection(project)
        }
        if showPhotos {
            photosSection(project)
        }
    }

    /// Read-only callout pinned to the top of every tab while the
    /// project is locked/finalized. Mirrors web's banner above the
    /// workspace tabs (Build #5.126.1).
    var frozenBannerSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Locked / finalized")
                        .font(.subheadline.weight(.semibold))
                    Text("Read-only. Unlock from the More tab to edit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(Color.orange.opacity(0.12))
    }

    /// Lock/Unlock toggle on the More tab. Mirrors web's Info-tab
    /// control: locking confirms first (it disables editing on every
    /// device), unlocking is a direct toggle — and is deliberately NOT
    /// gated by the frozen state, otherwise a locked project could
    /// never be unlocked. The server enforces owner/admin on the flip.
    @ViewBuilder
    func projectLockSection(_ project: Project) -> some View {
        Section {
            if project.isFrozen {
                Button {
                    store.setFrozen(project, frozen: false)
                    Haptics.tap()
                } label: {
                    Label("Unlock Project", systemImage: "lock.open")
                }
            } else {
                Button {
                    confirmingLock = true
                } label: {
                    Label("Lock Project (Finalize)", systemImage: "lock")
                }
                .confirmationDialog(
                    "Lock this project?",
                    isPresented: $confirmingLock,
                    titleVisibility: .visible
                ) {
                    Button("Lock Project", role: .destructive) {
                        store.setFrozen(project, frozen: true)
                        Haptics.tap()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Editing is disabled on every device until the project is unlocked. Viewing and export stay available.")
                }
            }
        } header: {
            Text("Project Lock")
        } footer: {
            Text(project.isFrozen
                 ? "This project is locked / finalized. Unlocking re-enables editing on all devices."
                 : "Locking marks the project finalized: read-only on iPhone and web until unlocked. Only the project owner or an org admin can lock or unlock — the server enforces this when the change syncs.")
        }
    }

    @ViewBuilder
    func metadataSection(_ project: Project) -> some View {
        Section("Project Information") {
            LabeledContent("Created", value: project.createdAt.formatted(date: .abbreviated, time: .shortened))

            if let gps = project.projectGPS {
                LabeledContent("Coordinates") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(GPSFormat.coordinateString(gps) ?? "")
                            .font(.caption.monospaced())
                        if let acc = gps.accuracyFeet {
                            Text(String(format: "± %.1f ft", acc))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Build #6.1.1: the address stays visible but is no longer
            // tappable-to-edit while the project is locked.
            if project.isFrozen {
                LabeledContent("Address") {
                    Text(project.projectAddress ?? "—")
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                }
            } else {
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
    }

    @ViewBuilder
    func addressTrailing(_ project: Project) -> some View {
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
    func fabStack(for project: Project) -> some View {
        VStack(spacing: 12) {
            if !project.floorPlans.isEmpty {
                distressFAB
            }
            takePhotoFAB
        }
    }

    /// Build #5.128.1: scope-aware FAB selector. Each tab in the
    /// workspace shell shows only the FABs that make sense for it:
    ///   .photos / .ai    → Camera (take photo / reshoot)
    ///   .plan            → Distress (mark structural distress on plan)
    ///   .buckets / .more → no FAB
    ///   .all (legacy)    → both FABs (today's behavior, preserved)
    @ViewBuilder
    func scopedFabStack(for project: Project) -> some View {
        // Build #6.1.1: no capture/markup FABs on a locked project.
        if project.isFrozen {
            EmptyView()
        } else {
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
    }

    /// Floating action button anchored to the bottom-right of the
    /// project detail screen. Triggers the camera capture flow — the
    /// same flow the now-removed inline "Take Photo" row used to drive.
    /// Tinted with the user's accent so it picks up theme changes.
    var takePhotoFAB: some View {
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
    var distressFAB: some View {
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
    func actionsSection(_ project: Project) -> some View {
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
    struct StagedImport: Sendable {
        let data: Data
        let date: Date
    }

    /// Sequence numbers go to the photo with the oldest timestamp
    /// first. Ties keep the iteration order so a same-second burst
    /// from the picker stays grouped.
    func sortedByCaptureDate(_ staged: [StagedImport]) -> [StagedImport] {
        staged.sorted { $0.date < $1.date }
    }

    @MainActor
    func importFromPhotosLibrary(_ items: [PhotosPickerItem]) async {
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
    func importFromFiles(_ urls: [URL]) async {
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
    func captureLocationIfNeeded() async {
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
    func exportSection(_ project: Project) -> some View {
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
    func bucketsSection(_ project: Project) -> some View {
        let sortedBuckets = project.buckets.sorted { $0.sortOrder < $1.sortOrder }
        Section {
            // Build #6.1.1: bucket CRUD is an edit — hidden while the
            // project is locked. The counts row below stays (read-only).
            if !project.isFrozen {
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
            }
            if !sortedBuckets.isEmpty {
                let unbucketedCount = project.photos.filter { $0.bucketID == nil }.count
                bucketCountsRow(buckets: sortedBuckets,
                                  photos: project.photos,
                                  unbucketedCount: unbucketedCount)
            } else if project.isFrozen {
                Text("No buckets defined.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Buckets")
        } footer: {
            Text("Buckets are user-defined categories for grouping photos — typically one per report section. Use the Photos list's Select mode to assign multiple photos at once.")
        }
    }

    @ViewBuilder
    func bucketCountsRow(buckets: [Bucket],
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

    /// Build a `BatchTagPrompt` for the multi-select "Tag with AI"
    /// action. `skipAlreadyTagged` is false because the user explicitly
    /// picked these photos — even if some already carry tags, the
    /// confirmation dialog surfaces an Add/Overwrite choice so the user
    /// stays in control of the merge.
    /// True when the project has at least one floor plan — gates the
    /// "Move to Level" multi-select button so single-plan-less
    /// projects don't show a no-op picker.
    var hasFloorPlans: Bool {
        guard let project = store.project(withID: projectID) else { return false }
        return !project.floorPlans.isEmpty
    }

    /// Open the level-assignment sheet against the currently-selected
    /// photos. Reuses the same `FloorPlanAssignmentSheet` the
    /// import-time flow already uses; flag `assignmentFromSelection`
    /// so completion also exits select mode.
    func presentSelectedLevelAssignment() {
        guard !selectedPhotoIDs.isEmpty else { return }
        assignmentFromSelection = true
        pendingPlanAssignment = selectedPhotoIDs
    }

}
