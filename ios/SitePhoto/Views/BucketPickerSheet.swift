import SwiftUI

/// Sheet shown by the photos multi-select bottom bar's "Move to Bucket…"
/// action. Lists every bucket defined on the project as a colored chip;
/// tapping one assigns it to all `photoIDs` and dismisses. Also offers a
/// "Clear bucket" affordance to drop the photos back into Unbucketed, and
/// a quick-create row so the user doesn't have to bounce out to the
/// Bucket Manager just to make a new one mid-flow.
struct BucketPickerSheet: View {
    let projectID: UUID
    let photoIDs: Set<UUID>
    let onAssigned: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var newBucketName: String = ""
    @State private var newBucketColor: String = Bucket.palette[0]
    @State private var isCreating: Bool = false

    private var project: Project? { store.project(withID: projectID) }
    private var buckets: [Bucket] {
        (project?.buckets ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick a bucket for the \(photoIDs.count) selected photo\(photoIDs.count == 1 ? "" : "s").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !buckets.isEmpty {
                    Section("Buckets") {
                        ForEach(buckets) { bucket in
                            Button {
                                assign(to: bucket.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(bucket.color)
                                        .frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                                    Text(bucket.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                        Button(role: .destructive) {
                            assign(to: nil)
                        } label: {
                            Label("Clear bucket (move to Unbucketed)",
                                  systemImage: "tray")
                        }
                    }
                }
                Section(buckets.isEmpty ? "Create your first bucket" : "Create a new bucket") {
                    TextField("Bucket name", text: $newBucketName)
                        .textInputAutocapitalization(.words)
                    colorPicker(selection: $newBucketColor)
                    Button {
                        createAndAssign()
                    } label: {
                        Label("Create & Assign", systemImage: "plus.circle.fill")
                    }
                    .disabled(trimmedNew.isEmpty || isCreating)
                }
            }
            .navigationTitle("Move to Bucket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func colorPicker(selection: Binding<String>) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(Bucket.palette, id: \.self) { hex in
                let isSelected = selection.wrappedValue.lowercased() == hex.lowercased()
                Button {
                    selection.wrappedValue = hex
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(bucketHex: hex) ?? .accentColor)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().stroke(
                                    isSelected ? Color.primary : Color.primary.opacity(0.15),
                                    lineWidth: isSelected ? 2.5 : 0.5
                                )
                            )
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var trimmedNew: String {
        newBucketName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assign(to bucketID: UUID?) {
        guard let project else { return }
        _ = store.setBucket(project, photoIDs: photoIDs, bucketID: bucketID)
        let count = photoIDs.count
        let bucketName = bucketID.flatMap { id in
            project.buckets.first(where: { $0.id == id })?.name
        }
        let target = bucketName ?? "Unbucketed"
        Haptics.confirm()
        toastCenter.post("Moved \(count) photo\(count == 1 ? "" : "s") to \(target)",
                          kind: .success)
        onAssigned()
        dismiss()
    }

    private func createAndAssign() {
        guard let project else { return }
        isCreating = true
        let updated = store.addBucket(project, name: trimmedNew, colorHex: newBucketColor)
        // Find the newly-created bucket — it's the one with the highest
        // sortOrder, since `addBucket` always appends.
        guard let newBucket = updated.buckets.max(by: { $0.sortOrder < $1.sortOrder }) else {
            isCreating = false
            return
        }
        _ = store.setBucket(updated, photoIDs: photoIDs, bucketID: newBucket.id)
        let count = photoIDs.count
        isCreating = false
        Haptics.confirm()
        toastCenter.post("Created \"\(newBucket.name)\" and moved \(count) photo\(count == 1 ? "" : "s") into it",
                          kind: .success)
        onAssigned()
        dismiss()
    }
}
