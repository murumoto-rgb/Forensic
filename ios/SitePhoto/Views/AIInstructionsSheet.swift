import SwiftUI

/// Editor for a project's AI tagging instructions (`Project.aiInstructions`).
/// Shows the current prompt in a `TextEditor`, lets the user customise it,
/// reset to the bundled default, or clear it (which falls back to default).
struct AIInstructionsSheet: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var loaded: Bool = false
    @State private var confirmingReset: Bool = false
    @State private var showingTemplatePicker: Bool = false
    @State private var showingTemplateManager: Bool = false
    @State private var showingSavePrompt: Bool = false
    @State private var saveTemplateName: String = ""

    private var project: Project? {
        store.project(withID: projectID)
    }

    /// True when `draft` differs from what's saved on the project.
    private var dirty: Bool {
        guard let project else { return false }
        return draft != project.effectiveAIInstructions
    }

    /// True when `draft` is exactly the bundled default — the "Reset" button
    /// is hidden in that case since there's nothing to reset.
    private var isAtDefault: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            == AIInstructions.defaultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                infoHeader
                Divider()
                TextEditor(text: $draft)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(Color(.systemGroupedBackground))
                Divider()
                footer
            }
            .navigationTitle("AI Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        templatesMenu
                        Button("Save") { save() }
                            .disabled(!dirty)
                    }
                }
            }
            .alert("Reset to default?",
                   isPresented: $confirmingReset) {
                Button("Reset", role: .destructive) {
                    draft = AIInstructions.defaultText
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your customised instructions for this project will be replaced with the bundled forensic-engineering default. This can't be undone.")
            }
            .alert("Save as template",
                   isPresented: $showingSavePrompt) {
                TextField("Template name", text: $saveTemplateName)
                    .textInputAutocapitalization(.words)
                Button("Save") { saveAsTemplate() }
                    .disabled(saveTemplateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { saveTemplateName = "" }
            } message: {
                Text("The current prompt will be saved as a reusable template you can load into other projects.")
            }
            .sheet(isPresented: $showingTemplatePicker) {
                AIPromptTemplatePickerSheet { template in
                    draft = template.prompt
                    Haptics.success()
                    toastCenter.post("Loaded \"\(template.name)\"", kind: .success)
                }
                .environment(store)
                .environment(toastCenter)
            }
            .sheet(isPresented: $showingTemplateManager) {
                AIPromptTemplateManagerSheet()
                    .environment(store)
                    .environment(toastCenter)
            }
            .onAppear { loadIfNeeded() }
        }
    }

    @ViewBuilder
    private var templatesMenu: some View {
        Menu {
            Button {
                showingTemplatePicker = true
            } label: {
                Label("Load Template…", systemImage: "tray.and.arrow.down")
            }
            Button {
                saveTemplateName = ""
                showingSavePrompt = true
            } label: {
                Label("Save as Template…", systemImage: "square.and.arrow.down")
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            Button {
                showingTemplateManager = true
            } label: {
                Label("Manage Templates…", systemImage: "list.bullet.rectangle")
            }
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .accessibilityLabel("AI Prompt Templates")
    }

    private func saveAsTemplate() {
        guard let template = store.addAIPromptTemplate(name: saveTemplateName,
                                                         prompt: draft) else {
            return
        }
        Haptics.success()
        toastCenter.post("Saved template \"\(template.name)\"", kind: .success)
        saveTemplateName = ""
    }

    @ViewBuilder
    private var infoHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("These instructions are sent to Claude as a tagging guide for every photo in this project. Edit the vocabulary, tone, or required fields to match how you write reports.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let project, project.hasCustomAIInstructions {
                    Label("Customised", systemImage: "pencil.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                } else {
                    Label("Using bundled default", systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(draft.count) chars")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button {
                confirmingReset = true
            } label: {
                Label("Reset to default", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isAtDefault)

            Spacer()

            if let project, project.hasCustomAIInstructions {
                Button(role: .destructive) {
                    _ = store.setAIInstructions(project, nil)
                    draft = AIInstructions.defaultText
                    dismiss()
                } label: {
                    Label("Clear & use default", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func loadIfNeeded() {
        guard !loaded, let project else { return }
        draft = project.effectiveAIInstructions
        loaded = true
    }

    private func save() {
        guard let project else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // If the user's text matches the default exactly, store nil — keeps
        // the project tracking the bundled default if we ever update it.
        if trimmed == AIInstructions.defaultText.trimmingCharacters(in: .whitespacesAndNewlines) {
            _ = store.setAIInstructions(project, nil)
        } else {
            _ = store.setAIInstructions(project, draft)
        }
        dismiss()
    }
}
