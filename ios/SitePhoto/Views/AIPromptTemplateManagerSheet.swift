import SwiftUI

/// Curate the saved AI prompt templates: rename, edit the prompt body,
/// or delete templates. Tap a row to open an inline editor for the
/// prompt text; the rename action lives in the row's contextual menu.
struct AIPromptTemplateManagerSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var editing: AIPromptTemplate?
    @State private var renaming: AIPromptTemplate?
    @State private var renameDraft: String = ""
    @State private var pendingDelete: AIPromptTemplate?

    var body: some View {
        NavigationStack {
            Group {
                if store.aiPromptTemplates.isEmpty {
                    EmptyStateView(
                        icon: "doc.on.doc",
                        title: "No templates yet",
                        message: "Save your current AI prompt from the AI Instructions sheet to start your library."
                    )
                } else {
                    List {
                        ForEach(store.aiPromptTemplates) { template in
                            templateRow(template)
                        }
                    }
                }
            }
            .navigationTitle("AI Prompt Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { template in
                EditPromptSheet(template: template) { newPrompt in
                    _ = store.updateAIPromptTemplate(template.id, prompt: newPrompt)
                    Haptics.success()
                    toastCenter.post("Updated \"\(template.name)\"", kind: .success)
                }
                .environment(store)
            }
            .alert("Rename template",
                   isPresented: Binding(
                    get: { renaming != nil },
                    set: { if !$0 { renaming = nil } }
                   )) {
                TextField("Name", text: $renameDraft)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("Delete template?",
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
            } message: { template in
                Text("\"\(template.name)\" will be removed from your library. Projects already using its prompt aren't affected.")
            }
        }
    }

    @ViewBuilder
    private func templateRow(_ template: AIPromptTemplate) -> some View {
        Button {
            editing = template
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.name)
                        .font(.body.bold())
                        .foregroundStyle(.primary)
                    Text(template.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Menu {
                    Button {
                        renaming = template
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
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func commitRename() {
        guard let template = renaming else { return }
        _ = store.renameAIPromptTemplate(template.id, to: renameDraft)
        renaming = nil
        renameDraft = ""
        Haptics.tap()
    }

    private func deleteTemplate(_ template: AIPromptTemplate) {
        if store.deleteAIPromptTemplate(template.id) {
            Haptics.confirm()
            toastCenter.post("Deleted \"\(template.name)\"", kind: .success)
        }
    }
}

/// Full-screen editor for a single template's prompt body. Used from
/// `AIPromptTemplateManagerSheet` when the engineer taps a row.
private struct EditPromptSheet: View {
    let template: AIPromptTemplate
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(template: AIPromptTemplate, onSave: @escaping (String) -> Void) {
        self.template = template
        self.onSave = onSave
        _draft = State(initialValue: template.prompt)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(.callout.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))
                .navigationTitle(template.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") {
                            onSave(draft)
                            dismiss()
                        }
                        .bold()
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
