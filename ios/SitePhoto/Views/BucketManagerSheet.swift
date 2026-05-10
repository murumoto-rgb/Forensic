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
                    Section("Buckets · \(buckets.count)") {
                        ForEach(buckets) { bucket in
                            bucketRow(bucket)
                        }
                        .onMove(perform: moveBuckets)
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
        guard let entry = store.saveBucketToLibrary(bucket,
                                                      intoCategory: categoryID) else {
            return
        }
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

    private func moveBuckets(from source: IndexSet, to destination: Int) {
        guard let project else { return }
        var ordered = buckets
        ordered.move(fromOffsets: source, toOffset: destination)
        _ = store.reorderBuckets(project, ordered: ordered)
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
