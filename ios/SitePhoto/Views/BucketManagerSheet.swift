import SwiftUI

/// Create / rename / recolor / reorder / delete the project's user-defined
/// buckets. Buckets are a coarser categorization than the AI tag vocabulary
/// — usually one per report section the engineer plans to write up. Photos
/// reference buckets via `Photo.bucketID`; deleting a bucket here drops
/// every reference back to "Unbucketed" via `ProjectStore.deleteBucket`.
struct BucketManagerSheet: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var newBucketName: String = ""
    @State private var newBucketColor: String = Bucket.palette[0]
    @State private var pendingDelete: Bucket?
    @State private var renamingBucketID: UUID?
    @State private var renameDraft: String = ""

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
                        ContentUnavailableView(
                            "No buckets yet",
                            systemImage: "folder.badge.plus",
                            description: Text("Create buckets to group photos for report sections, then drop selected photos into them via the photos list.")
                        )
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
                if !buckets.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
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
