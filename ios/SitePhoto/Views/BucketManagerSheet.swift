import SwiftUI

/// Create / rename / recolor / reorder / delete the project's user-defined
/// buckets. Buckets are a coarser categorization than the AI tag vocabulary
/// — usually one per report section the engineer plans to write up. Photos
/// reference buckets via `Photo.bucketID`; deleting a bucket here drops
/// every reference back to "Unbucketed" via `ProjectStore.deleteBucket`.
struct BucketManagerSheet: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var newBucketName: String = ""
    @State private var newBucketColor: String = Bucket.palette[0]
    @State private var pendingDelete: Bucket?
    @State private var renamingBucketID: UUID?
    @State private var renameDraft: String = ""
    @State private var showingLibraryPicker: Bool = false
    @State private var showingLibraryManager: Bool = false
    @State private var savingBucketToLibrary: Bucket?

    private var project: Project? { store.project(withID: projectID) }
    private var buckets: [Bucket] {
        (project?.buckets ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    /// One row in the grouped bucket list — a library category (or the
    /// "Uncategorized" sentinel) plus the buckets that fall under it,
    /// kept in sortOrder. Categories the engineer hasn't tagged any
    /// bucket under are omitted, so the manager only shows headings
    /// that have content.
    private struct BucketGroup: Identifiable {
        let id: String
        let categoryID: UUID?
        let title: String
        let buckets: [Bucket]
    }

    private var groupedBuckets: [BucketGroup] {
        let sorted = buckets
        let knownCategories = store.bucketLibrary
        var groups: [BucketGroup] = []
        // Render in the library's own order so the manager mirrors the
        // grouping the engineer sees in the picker.
        for category in knownCategories {
            let members = sorted.filter { $0.libraryCategoryID == category.id }
            guard !members.isEmpty else { continue }
            groups.append(BucketGroup(id: category.id.uuidString,
                                       categoryID: category.id,
                                       title: category.name,
                                       buckets: members))
        }
        // Buckets pointing at a category that no longer exists fall
        // back to "Uncategorized" so they're still reachable.
        let validIDs = Set(knownCategories.map(\.id))
        let unmatched = sorted.filter { bucket in
            guard let cid = bucket.libraryCategoryID else { return true }
            return !validIDs.contains(cid)
        }
        if !unmatched.isEmpty {
            groups.append(BucketGroup(id: "__uncategorized__",
                                       categoryID: nil,
                                       title: "Uncategorized",
                                       buckets: unmatched))
        }
        return groups
    }

    var body: some View {
        NavigationStack {
            List {
                createSection
                if buckets.isEmpty {
                    Section {
                        EmptyStateView(
                            icon: "folder.badge.plus",
                            title: "No buckets yet",
                            message: "Create buckets to group photos for report sections, then drop selected photos into them via the photos list."
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(groupedBuckets, id: \.id) { group in
                        bucketGroupSection(group)
                    }
                }
            }
            .navigationTitle("Buckets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        libraryMenu
                        if !buckets.isEmpty {
                            EditButton()
                        }
                    }
                }
            }
            .sheet(isPresented: $showingLibraryPicker) {
                BucketLibraryPickerSheet(projectID: projectID,
                                          onApplied: {})
                    .environment(store)
                    .environment(toastCenter)
            }
            .sheet(isPresented: $showingLibraryManager) {
                BucketLibraryManagerSheet()
                    .environment(store)
                    .environment(toastCenter)
            }
            .sheet(item: $savingBucketToLibrary) { bucket in
                SaveToLibraryCategorySheet(bucket: bucket) { categoryID in
                    saveToLibrary(bucket, categoryID: categoryID)
                }
                .environment(store)
                .environment(toastCenter)
                .presentationDetents([.medium])
            }
            .alert(
                "Delete bucket \"\(pendingDelete?.name ?? "")\"?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { bucket in
                Button("Delete", role: .destructive) {
                    delete(bucket)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            } message: { _ in
                Text("Photos in this bucket will become Unbucketed. The photos themselves stay put.")
            }
        }
    }

    @ViewBuilder
    private var createSection: some View {
        Section("New bucket") {
            TextField("Bucket name", text: $newBucketName)
                .textInputAutocapitalization(.words)
            colorPicker(selection: $newBucketColor)
            Button {
                createBucket()
            } label: {
                Label("Create", systemImage: "plus.circle.fill")
            }
            .disabled(trimmedNew.isEmpty)
        }
    }

    /// One Section in the grouped list. Uses the library category's
    /// name as the section header (or "Uncategorized" for buckets with
    /// no link), and lets the engineer drag-reorder within the section.
    /// Cross-section drag is intentionally disabled — moving a bucket
    /// out of its category would require changing both `sortOrder` and
    /// `libraryCategoryID`, which is too ambiguous to do silently.
    @ViewBuilder
    private func bucketGroupSection(_ group: BucketGroup) -> some View {
        Section {
            ForEach(group.buckets) { bucket in
                bucketRow(bucket)
            }
            .onMove { source, destination in
                moveBuckets(inGroup: group, from: source, to: destination)
            }
        } header: {
            HStack(spacing: 8) {
                if group.categoryID != nil {
                    Text("Investigation Type")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text("·")
                        .foregroundStyle(.secondary)
                }
                Text(group.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .textCase(nil)
                Spacer()
                Text("\(group.buckets.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func bucketRow(_ bucket: Bucket) -> some View {
        let assignedCount = countOfPhotos(in: bucket)
        HStack(spacing: 10) {
            Circle()
                .fill(bucket.color)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            if renamingBucketID == bucket.id {
                TextField("Bucket name", text: $renameDraft)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { commitRename(for: bucket) }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bucket.name)
                        .font(.body)
                    Text("\(assignedCount) photo\(assignedCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button {
                    renamingBucketID = bucket.id
                    renameDraft = bucket.name
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Menu("Color") {
                    ForEach(Bucket.palette, id: \.self) { hex in
                        Button {
                            recolor(bucket, to: hex)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(bucketHex: hex) ?? .accentColor)
                                    .frame(width: 14, height: 14)
                                Text(hex)
                                if bucket.colorHex.lowercased() == hex.lowercased() {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Button {
                    savingBucketToLibrary = bucket
                } label: {
                    Label("Save to Library…", systemImage: "books.vertical")
                }
                Divider()
                Button(role: .destructive) {
                    pendingDelete = bucket
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = bucket
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func colorPicker(selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color")
                .font(.caption)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(Bucket.palette, id: \.self) { hex in
                    let isSelected = selection.wrappedValue.lowercased() == hex.lowercased()
                    Button {
                        selection.wrappedValue = hex
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(bucketHex: hex) ?? .accentColor)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().stroke(
                                        isSelected ? Color.primary : Color.primary.opacity(0.15),
                                        lineWidth: isSelected ? 2.5 : 0.5
                                    )
                                )
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var trimmedNew: String {
        newBucketName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createBucket() {
        guard let project else { return }
        _ = store.addBucket(project, name: trimmedNew, colorHex: newBucketColor)
        newBucketName = ""
    }

    /// Toolbar menu surfacing the two library entry points.
    /// "Add from Library…" opens a picker showing every Primary
    /// Investigation Type and lets the engineer multi-select observation
    /// buckets to drop in. "Manage Library…" opens the curation surface
    /// for adding / renaming / deleting categories and entries.
    @ViewBuilder
    private var libraryMenu: some View {
        Menu {
            Button {
                showingLibraryPicker = true
            } label: {
                Label("Add from Library…", systemImage: "books.vertical")
            }
            Divider()
            Button {
                showingLibraryManager = true
            } label: {
                Label("Manage Library…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "books.vertical")
        }
        .accessibilityLabel("Bucket Library")
    }

    private func saveToLibrary(_ bucket: Bucket, categoryID: UUID) {
        guard let project,
              let entry = store.saveBucketToLibrary(bucket,
                                                      intoCategory: categoryID) else {
            return
        }
        // Classify the bucket on the project so it surfaces under the
        // chosen category in the grouped list immediately. Without this
        // the engineer would file the bucket to the library but the
        // bucket itself would stay under "Uncategorized".
        _ = store.setBucketLibraryCategory(project,
                                            bucketID: bucket.id,
                                            libraryCategoryID: categoryID)
        let categoryName = store.bucketLibrary
            .first(where: { $0.id == categoryID })?.name ?? ""
        Haptics.success()
        toastCenter.post("Saved \"\(entry.name)\" to \(categoryName)",
                          kind: .success)
        savingBucketToLibrary = nil
    }

    private func delete(_ bucket: Bucket) {
        guard let project else { return }
        _ = store.deleteBucket(project, bucketID: bucket.id)
    }

    private func recolor(_ bucket: Bucket, to colorHex: String) {
        guard let project else { return }
        _ = store.recolorBucket(project, bucketID: bucket.id, colorHex: colorHex)
    }

    private func commitRename(for bucket: Bucket) {
        guard let project else { return }
        _ = store.renameBucket(project, bucketID: bucket.id, to: renameDraft)
        renamingBucketID = nil
        renameDraft = ""
    }

    /// Move buckets inside one group only. SwiftUI's `.onMove` hands us
    /// indices relative to the group's slice, so we translate those
    /// back into a full-list reorder that keeps everything outside the
    /// group exactly where it was.
    private func moveBuckets(inGroup group: BucketGroup,
                              from source: IndexSet,
                              to destination: Int) {
        guard let project else { return }
        var groupBuckets = group.buckets
        groupBuckets.move(fromOffsets: source, toOffset: destination)
        // Stitch the reordered group back into the full bucket list at
        // the positions the group's buckets previously occupied.
        var remaining = groupBuckets.makeIterator()
        let groupIDs = Set(group.buckets.map(\.id))
        let stitched: [Bucket] = buckets.map { bucket in
            if groupIDs.contains(bucket.id), let next = remaining.next() {
                return next
            }
            return bucket
        }
        _ = store.reorderBuckets(project, ordered: stitched)
    }

    private func countOfPhotos(in bucket: Bucket) -> Int {
        project?.photos.filter { $0.bucketID == bucket.id }.count ?? 0
    }
}

/// Half-height sheet shown when the engineer taps "Save to Library…" on
/// a project bucket. Lists the existing Primary Investigation Type
/// categories so the bucket can be filed under one. If the library is
/// empty, the user is invited to open the manager and create a category
/// first — saving into a non-existent category is meaningless.
private struct SaveToLibraryCategorySheet: View {
    let bucket: Bucket
    let onPick: (UUID) -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.bucketLibrary.isEmpty {
                    EmptyStateView(
                        icon: "books.vertical",
                        title: "No categories yet",
                        message: "Create a Primary Investigation Type in Manage Library, then come back to save this bucket into it."
                    )
                } else {
                    List {
                        Section {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(bucket.color)
                                    .frame(width: 14, height: 14)
                                Text(bucket.name)
                                    .font(.body.bold())
                                Spacer()
                            }
                        } header: {
                            Text("Bucket to save")
                        }
                        Section {
                            ForEach(store.bucketLibrary) { category in
                                Button {
                                    onPick(category.id)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(category.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        Text("\(category.entries.count) bucket\(category.entries.count == 1 ? "" : "s") already")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Save into category")
                        }
                    }
                }
            }
            .navigationTitle("Save to Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
