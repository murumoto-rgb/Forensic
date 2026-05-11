import SwiftUI

/// Editor for a project's optional AI tagging notes
/// (`Project.aiInstructions`). The notes are appended to the compiled
/// system prompt as "Additional notes for this project" — use them for
/// one-off guidance like "focus on the east elevation" or "this
/// project has a known foundation repair in 2018." The schema lives in
/// **Settings → AI Tagging Rules**; the vocabulary lives in **AI Tags**.
struct AIInstructionsSheet: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var loaded: Bool = false
    @State private var showingTemplatePicker: Bool = false
    @State private var showingTemplateManager: Bool = false
    @State private var showingSavePrompt: Bool = false
    @State private var saveTemplateName: String = ""

    private var project: Project? {
        store.project(withID: projectID)
    }

    /// True when `draft` differs from what's saved on the project.
    /// Trim-tolerant so trailing-newline-only edits don't count as dirty.
    private var dirty: Bool {
        guard let project else { return false }
        let saved = (project.aiInstructions ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved != current
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
            .navigationTitle("AI Notes")
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
            Text("These notes are appended to the compiled AI prompt as \"Additional notes for this project.\" Use them for one-off guidance like \"focus on the east elevation\" or \"this project has a known foundation repair in 2018.\" Vocabulary lives in **AI Tags**; the schema lives in **Settings → AI Tagging Rules**.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("No notes set", systemImage: "square.dashed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Notes set", systemImage: "note.text")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
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
            Spacer()
            if let project,
               !(project.aiInstructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(role: .destructive) {
                    _ = store.setAIInstructions(project, nil)
                    draft = ""
                    dismiss()
                } label: {
                    Label("Clear notes", systemImage: "xmark.circle")
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
        // Notes are optional — empty when unset. Notes don't have a
        // "default" anymore (that role belongs to the app-wide rules
        // template, edited in Settings), so an empty editor is the
        // correct presentation when no notes are saved.
        draft = project.aiInstructions ?? ""
        loaded = true
    }

    private func save() {
        guard let project else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty text → store nil so the project's manifest stays tidy
        // and the AI Tags row's "no notes" badge is accurate.
        _ = store.setAIInstructions(project, trimmed.isEmpty ? nil : draft)
        dismiss()
    }
}
