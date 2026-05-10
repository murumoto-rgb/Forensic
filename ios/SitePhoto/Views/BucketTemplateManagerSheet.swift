import SwiftUI

/// Manage the app-wide library of bucket templates: rename, recolor
/// individual entries inline, delete entire templates, or delete entries
/// inside a template. Creation happens from the Bucket Manager via
/// "Save as Template…" — this sheet is the curation surface afterwards.
struct BucketTemplateManagerSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    @State private var pendingDelete: BucketTemplate?

    var body: some View {
        NavigationStack {
            Group {
                if store.bucketTemplates.isEmpty {
                    EmptyStateView(
                        icon: "list.bullet.rectangle",
                        title: "No templates yet",
                        message: "Create one from the Bucket Manager via \"Save as Template…\" after you've built a bucket list you'd like to reuse."
                    )
                } else {
                    List {
                        ForEach(store.bucketTemplates) { template in
                            templateSection(template)
                        }
                    }
                }
            }
            .navigationTitle("Bucket Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete template \"\(pendingDelete?.name ?? "")\"?",
                   isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                   ),
                   presenting: pendingDelete) { template in
                Button("Delete", role: .destructive) {
                    deleteTemplate(template)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("Existing projects that used this template keep their buckets. Future applies will be unavailable.")
            }
        }
    }

    @ViewBuilder
    private func templateSection(_ template: BucketTemplate) -> some View {
        Section {
            if renamingID == template.id {
                TextField("Template name", text: $renameDraft)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { commitRename(template) }
            }
            ForEach(template.entries, id: \.name) { entry in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(bucketHex: entry.colorHex) ?? .accentColor)
                        .frame(width: 14, height: 14)
                    Text(entry.name)
                        .font(.callout)
                    Spacer()
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(template.name)
                Spacer()
                Text("\(template.entries.count) bucket\(template.entries.count == 1 ? "" : "s")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Menu {
                    Button {
                        renamingID = template.id
                        renameDraft = template.name
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDelete = template
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .textCase(nil)
            }
        }
    }

    private func commitRename(_ template: BucketTemplate) {
        _ = store.renameBucketTemplate(template.id, to: renameDraft)
        renamingID = nil
        renameDraft = ""
        Haptics.tap()
    }

    private func deleteTemplate(_ template: BucketTemplate) {
        if store.deleteBucketTemplate(template.id) {
            Haptics.confirm()
            toastCenter.post("Deleted template \"\(template.name)\"", kind: .success)
        }
    }
}
