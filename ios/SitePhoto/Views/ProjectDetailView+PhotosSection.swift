// Split out of ProjectDetailView.swift (Build #6.24.1 — iOS
// decomposition part 2). Members moved verbatim into a same-module
// extension; `private` dropped on the struct's members because Swift
// scopes private to the file and these now cross file boundaries.
// No behavior change.

import SwiftUI

extension ProjectDetailView {

    @ViewBuilder
    func photosSection(_ project: Project) -> some View {
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
                // Build #6.7.1: name the filters doing the excluding
                // (the old copy blamed "the selected tag filter" no
                // matter which filter was active) + one-tap escape.
                VStack(alignment: .leading, spacing: 8) {
                    Text("No photos match: \(filters.summaryDescription).")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Button {
                        filters = PhotoFilterState()
                    } label: {
                        Label("Clear all filters", systemImage: "xmark.circle")
                            .font(.callout)
                    }
                }
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
    func trashSection(_ project: Project) -> some View {
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
    func trashRow(_ photo: Photo, project: Project) -> some View {
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

    func restoreTrashed(_ photo: Photo, project: Project) {
        _ = store.restorePhoto(project, photoID: photo.id)
        Haptics.confirm()
        toastCenter.post("Restored photo #\(photo.sequenceNumber)", kind: .success)
    }

    func permanentlyDelete(_ photo: Photo, project: Project) {
        _ = store.permanentlyDeleteFromTrash(project, photoIDs: [photo.id])
        Haptics.confirm()
        toastCenter.post("Deleted permanently", kind: .success)
    }

    func emptyTrash(_ project: Project) {
        let count = project.trashedPhotos.count
        _ = store.emptyTrash(project)
        Haptics.confirm()
        toastCenter.post("Emptied Trash · \(count) photo\(count == 1 ? "" : "s")",
                          kind: .success)
    }

    func relativeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    func photosSectionHeader(project: Project, visiblePhotos: [Photo]) -> some View {
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
                if filters.isActive {
                    Text("· \(visiblePhotos.count) shown")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Build #6.1.1: Select mode + renumber both mutate the
                // project — hidden while locked.
                if !project.photos.isEmpty && !project.isFrozen {
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
    func selectionActionRow(visiblePhotos: [Photo]) -> some View {
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
    func selectablePhotoRow(photo: Photo, project: Project) -> some View {
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

    func exitSelectionMode() {
        selectionMode = false
        selectedPhotoIDs.removeAll()
    }

    func deleteSelectedPhotos() {
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

    func filteredPhotos(_ project: Project) -> [Photo] {
        let tagFilterActive = !filters.activeTagFilters.isEmpty
        let useFilterActive = !filters.recommendedUseFilter.isEmpty
        let bucketFilterActive = !filters.activeBucketFilter.isEmpty
        let trimmedSearch = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchActive = !trimmedSearch.isEmpty
        let dateBounds = filters.dateFilter.bounds()
        let planFilterActive = filters.planFilter != .all
        let locationFilterActive = filters.locationFilter != .all
        if !tagFilterActive && !useFilterActive && !bucketFilterActive
            && !filters.showOnlyNeedsReview && !filters.validationIssuesOnly
            && !filters.favoritesOnly && !filters.measurementsOnly
            && !searchActive
            && dateBounds == nil && !planFilterActive && !filters.notInBucketOnly
            && !locationFilterActive {
            return project.photos
        }
        // Memo (Build #6.5.1): with filters active this chain re-ran
        // on every body render — including unrelated state ticks like
        // batch-tag progress — doing per-photo string work. Cache the
        // membership + order (IDs, never Photo values, so rows always
        // render fresh data) keyed on the filter state + threshold +
        // a cheap content stamp (photos.count + lastSavedAt: any save
        // invalidates).
        let memoKey = FilterMemoKey(filters: filters,
                                    threshold: tagConfidenceThreshold,
                                    photosCount: project.photos.count,
                                    stamp: store.lastSavedAt)
        if filterMemo.key == memoKey {
            let byID = Dictionary(project.photos.map { ($0.id, $0) },
                                  uniquingKeysWith: { a, _ in a })
            return filterMemo.ids.compactMap { byID[$0] }
        }
        let lcFilters = Set(filters.activeTagFilters.map { $0.lowercased() })
        let lcSearch = trimmedSearch.lowercased()
        let result = project.photos.filter { photo in
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
                if !filters.recommendedUseFilter.contains(bucket) { return false }
            }
            if bucketFilterActive {
                guard let bid = photo.bucketID,
                      filters.activeBucketFilter.contains(bid) else { return false }
            }
            if filters.notInBucketOnly && photo.bucketID != nil {
                return false
            }
            if filters.showOnlyNeedsReview {
                if !needsReview(photo) { return false }
            }
            if filters.validationIssuesOnly {
                if !hasValidationIssue(photo) { return false }
            }
            if filters.favoritesOnly && !photo.isFavorite {
                return false
            }
            if filters.measurementsOnly && !hasMeasurement(photo) {
                return false
            }
            switch filters.planFilter {
            case .all:
                break
            case .unassigned:
                if photo.floorPlanID != nil { return false }
            case .plan(let id):
                if photo.floorPlanID != id { return false }
            }
            switch filters.locationFilter {
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
        filterMemo.key = memoKey
        filterMemo.ids = result.map(\.id)
        return result
    }

    /// Location filter pill — `All locations` / `Located` / `Not
    /// located`. Distinct from the level filter (which scopes "which
    /// plan"); this one scopes "has it been placed at all." Renders
    /// as an icon-only pill when inactive and adds a short label only
    /// after the engineer picks a specific filter.
    @ViewBuilder
    func locationFilterMenu() -> some View {
        Menu {
            Picker("Location", selection: Binding(
                get: { filters.locationFilter },
                set: { filters.locationFilter = $0 }
            )) {
                Text("All locations").tag(LocationFilter.all)
                Text("Located").tag(LocationFilter.located)
                Text("Not located").tag(LocationFilter.notLocated)
            }
        } label: {
            if filters.locationFilter == .all {
                Image(systemName: "location")
                    .font(.caption)
            } else {
                let short: String = {
                    switch filters.locationFilter {
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
        .tint(filters.locationFilter == .all ? .secondary : .accentColor)
        .accessibilityLabel("Filter by location")
    }

    /// Level filter pill — "level" being the engineer's term for a
    /// floor plan in their workflow. Icon-only when inactive; icon +
    /// short label when filtered to a specific plan.
    @ViewBuilder
    func planFilterMenu(project: Project) -> some View {
        Menu {
            Picker("Level", selection: Binding(
                get: { filters.planFilter },
                set: { filters.planFilter = $0 }
            )) {
                Text("All levels").tag(PlanFilter.all)
                Text("No level").tag(PlanFilter.unassigned)
                Divider()
                ForEach(project.floorPlans) { plan in
                    Text(plan.label).tag(PlanFilter.plan(plan.id))
                }
            }
        } label: {
            if filters.planFilter == .all {
                Image(systemName: "map")
                    .font(.caption)
            } else {
                let short: String = {
                    switch filters.planFilter {
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
        .tint(filters.planFilter == .all ? .secondary : .accentColor)
        .accessibilityLabel("Filter by level")
    }

    /// Check whether `photo` contains `lcSearch` (already lowercased) in
    /// any of the searchable fields: sequence number, location, caption,
    /// observation, tag labels. Substring match — no fuzzy matching.
    func photoMatchesSearch(_ photo: Photo, lcSearch: String) -> Bool {
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
    func needsReview(_ photo: Photo) -> Bool {
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
    func hasValidationIssue(_ photo: Photo) -> Bool {
        guard let a = photo.aiAnalysis, !a.parseFailed else { return false }
        return !a.validationErrors.isEmpty
    }

    /// Date-window chip rendered into the filter bar. Always present —
    /// even when no filter is applied it shows "Any date" so the
    /// engineer can discover the feature. Tapping opens a menu of
    /// preset windows plus a "Custom range…" option that pops a sheet.
    @ViewBuilder
    var dateFilterChip: some View {
        Menu {
            Button {
                filters.dateFilter = .all
            } label: {
                if case .all = filters.dateFilter {
                    Label("Any date", systemImage: "checkmark")
                } else {
                    Text("Any date")
                }
            }
            Button {
                filters.dateFilter = .today
            } label: {
                if case .today = filters.dateFilter {
                    Label("Today", systemImage: "checkmark")
                } else {
                    Text("Today")
                }
            }
            Button {
                filters.dateFilter = .last7Days
            } label: {
                if case .last7Days = filters.dateFilter {
                    Label("Last 7 days", systemImage: "checkmark")
                } else {
                    Text("Last 7 days")
                }
            }
            Button {
                filters.dateFilter = .last30Days
            } label: {
                if case .last30Days = filters.dateFilter {
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
            if filters.dateFilter.isActive {
                Label(filters.dateFilter.chipLabel, systemImage: "calendar")
                    .font(.caption)
            } else {
                Image(systemName: "calendar")
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(filters.dateFilter.isActive ? .accentColor : .secondary)
    }

    @ViewBuilder
    func tagFilterBar(allTags: [String]) -> some View {
        let project = store.project(withID: projectID)
        let needsReviewCount = project?.photos.filter { needsReview($0) }.count ?? 0
        let validationIssuesCount = project?.photos.filter { hasValidationIssue($0) }.count ?? 0
        let favoritesCount = project?.photos.filter { $0.isFavorite }.count ?? 0
        let measurementCount = project?.photos.filter { hasMeasurement($0) }.count ?? 0
        let recommendedUseChips = bucketsInUseFor(projectID: projectID)
        let userBuckets = (project?.buckets ?? []).sorted { $0.sortOrder < $1.sortOrder }
        let bucketFilterCount = filters.activeBucketFilter.count
            + filters.recommendedUseFilter.count
            + (filters.notInBucketOnly ? 1 : 0)
        let tagFilterCount = filters.activeTagFilters.count
        let anyFilterActive = !filters.activeTagFilters.isEmpty
            || !filters.recommendedUseFilter.isEmpty
            || !filters.activeBucketFilter.isEmpty
            || filters.showOnlyNeedsReview
            || filters.validationIssuesOnly
            || filters.favoritesOnly
            || filters.measurementsOnly
            || filters.planFilter != .all
            || filters.notInBucketOnly
            || filters.locationFilter != .all
            || filters.dateFilter.isActive

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if anyFilterActive {
                    Button {
                        filters.activeTagFilters.removeAll()
                        filters.recommendedUseFilter.removeAll()
                        filters.activeBucketFilter.removeAll()
                        filters.showOnlyNeedsReview = false
                        filters.validationIssuesOnly = false
                        filters.favoritesOnly = false
                        filters.measurementsOnly = false
                        filters.planFilter = .all
                        filters.notInBucketOnly = false
                        filters.locationFilter = .all
                        filters.dateFilter = .all
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
                    filters.favoritesOnly.toggle()
                } label: {
                    Image(systemName: "star.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(filters.favoritesOnly ? .yellow : .secondary)
                .disabled(favoritesCount == 0 && !filters.favoritesOnly)
                Button {
                    filters.showOnlyNeedsReview.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(filters.showOnlyNeedsReview ? .orange : .secondary)
                .disabled(needsReviewCount == 0 && !filters.showOnlyNeedsReview)
                Button {
                    filters.validationIssuesOnly.toggle()
                } label: {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(filters.validationIssuesOnly ? .red : .secondary)
                .disabled(validationIssuesCount == 0 && !filters.validationIssuesOnly)
                Button {
                    filters.measurementsOnly.toggle()
                } label: {
                    Image(systemName: "ruler")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(filters.measurementsOnly ? .teal : .secondary)
                .disabled(measurementCount == 0 && !filters.measurementsOnly)
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
    func hasMeasurement(_ photo: Photo) -> Bool {
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
    func bucketFilterMenu(userBuckets: [Bucket],
                                    recommendedUseChips: [String],
                                    activeCount: Int) -> some View {
        Menu {
            Button {
                filters.notInBucketOnly.toggle()
                if filters.notInBucketOnly {
                    filters.activeBucketFilter.removeAll()
                }
            } label: {
                if filters.notInBucketOnly {
                    Label("Not in a bucket", systemImage: "checkmark")
                } else {
                    Text("Not in a bucket")
                }
            }
            if !userBuckets.isEmpty {
                Section("Buckets") {
                    ForEach(userBuckets) { bucket in
                        let on = filters.activeBucketFilter.contains(bucket.id)
                        Button {
                            if on {
                                filters.activeBucketFilter.remove(bucket.id)
                            } else {
                                filters.activeBucketFilter.insert(bucket.id)
                                filters.notInBucketOnly = false
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
                        let on = filters.recommendedUseFilter.contains(bucket)
                        Button {
                            if on {
                                filters.recommendedUseFilter.remove(bucket)
                            } else {
                                filters.recommendedUseFilter.insert(bucket)
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
    func tagFilterMenu(allTags: [String], activeCount: Int) -> some View {
        Menu {
            ForEach(allTags, id: \.self) { tag in
                let on = filters.activeTagFilters.contains(tag)
                Button {
                    if on { filters.activeTagFilters.remove(tag) }
                    else  { filters.activeTagFilters.insert(tag) }
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
    func bucketsInUseFor(projectID: UUID) -> [String] {
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
}
