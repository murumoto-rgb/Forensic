import SwiftUI

/// Picker for applying an existing bucket template to a project.
/// Engineer chooses which template + mode (replace existing buckets or
/// append). Replace is destructive (drops every photo's bucket
/// assignment that lived in the old buckets), so the apply button shows
/// an in-place confirmation alert in that mode.
struct BucketTemplatePickerSheet: View {
    let projectID: UUID
    let onApplied: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateID: UUID?
    @State private var mode: BucketTemplate.ApplyMode = .append
    @State private var confirmingReplace: Bool = false

    private var project: Project? { store.project(withID: projectID) }
    private var templates: [BucketTemplate] { store.bucketTemplates }

    var body: some View {
        NavigationStack {
            Group {
                if templates.isEmpty {
                    EmptyStateView(
                        icon: "list.bullet.rectangle",
                        title: "No templates yet",
                        message: "Build a bucket list in this project, then save it from \"Save as Template…\" to reuse later."
                    )
                } else {
                    Form {
                        Section {
                            ForEach(templates) { template in
                                templateRow(template)
                            }
                        } header: {
                            Text("Pick a template")
                        }
                        Section {
                            Picker("Apply as", selection: $mode) {
                                Text("Append to existing").tag(BucketTemplate.ApplyMode.append)
                                Text("Replace existing").tag(BucketTemplate.ApplyMode.replace)
                            }
                            .pickerStyle(.segmented)
                            if mode == .replace, let project, !project.buckets.isEmpty {
                                Text("This project currently has \(project.buckets.count) bucket\(project.buckets.count == 1 ? "" : "s"). They'll be removed and any photo assigned to them becomes Unbucketed.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } header: {
                            Text("Apply mode")
                        }
                    }
                }
            }
            .navigationTitle("Load Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        attemptApply()
                    }
                    .disabled(selectedTemplateID == nil)
                    .bold()
                }
            }
            .alert("Replace existing buckets?",
                   isPresented: $confirmingReplace) {
                Button("Replace", role: .destructive) { apply() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Existing buckets will be deleted and photos assigned to them will become Unbucketed. This cannot be undone.")
            }
        }
    }

    @ViewBuilder
    private func templateRow(_ template: BucketTemplate) -> some View {
        let isSelected = selectedTemplateID == template.id
        Button {
            selectedTemplateID = template.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.name)
                        .font(.body.bold())
                        .foregroundStyle(.primary)
                    swatchRow(for: template)
                    Text("\(template.entries.count) bucket\(template.entries.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func swatchRow(for template: BucketTemplate) -> some View {
        // Tiny color-swatch strip so the engineer can spot the template's
        // palette at a glance without reading every name.
        HStack(spacing: 4) {
            ForEach(template.entries.prefix(8), id: \.name) { entry in
                Circle()
                    .fill(Color(bucketHex: entry.colorHex) ?? .accentColor)
                    .frame(width: 12, height: 12)
            }
            if template.entries.count > 8 {
                Text("+\(template.entries.count - 8)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func attemptApply() {
        guard selectedTemplateID != nil else { return }
        if mode == .replace, let project, !project.buckets.isEmpty {
            confirmingReplace = true
        } else {
            apply()
        }
    }

    private func apply() {
        guard let id = selectedTemplateID,
              let template = templates.first(where: { $0.id == id }),
              let project else { return }
        _ = store.applyBucketTemplate(template, to: project, mode: mode)
        Haptics.success()
        let verb = (mode == .replace) ? "Replaced buckets with" : "Added buckets from"
        toastCenter.post("\(verb) \"\(template.name)\"", kind: .success)
        onApplied()
        dismiss()
    }
}
