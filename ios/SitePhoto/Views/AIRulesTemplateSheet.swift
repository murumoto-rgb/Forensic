import SwiftUI

/// Editor for the app-wide AI tagging rules template
/// (`ProjectStore.aiRulesTemplate`). The rules block holds the JSON
/// output schema, field definitions, and general tagging rules — the
/// stable scaffolding that every project's compiled prompt sits on top
/// of. Per-project vocabulary (the controlled tag list) is appended
/// separately at request time from each project's `tagSelection`.
///
/// Style mirrors `AIInstructionsSheet.swift`: a full-screen monospaced
/// `TextEditor`, dirty-state-aware Save button, and a Reset-to-default
/// confirmation.
struct AIRulesTemplateSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var loaded: Bool = false
    @State private var confirmingReset: Bool = false

    private var dirty: Bool { draft != store.aiRulesTemplate }

    private var isAtDefault: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            == AIRulesTemplate.defaultText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            .navigationTitle("AI Tagging Rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!dirty)
                }
            }
            .alert("Reset to default?",
                   isPresented: $confirmingReset) {
                Button("Reset", role: .destructive) {
                    draft = AIRulesTemplate.defaultText
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your customised rules template will be replaced with the bundled forensic-engineering default. This can't be undone.")
            }
            .onAppear { loadIfNeeded() }
        }
    }

    @ViewBuilder
    private var infoHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("These rules sit at the top of the AI prompt for every project. Each project's tag library selection is appended below them at request time — edit this block to tune output schema, tone, or the general rules; edit AI Tags per-project to tune the vocabulary.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if isAtDefault {
                    Label("Using bundled default", systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Customised", systemImage: "pencil.circle.fill")
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
            Button {
                confirmingReset = true
            } label: {
                Label("Reset to default", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isAtDefault)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        draft = store.aiRulesTemplate
        loaded = true
    }

    private func save() {
        _ = store.updateAIRulesTemplate(draft)
        Haptics.success()
        toastCenter.post("AI tagging rules saved", kind: .success)
        dismiss()
    }
}
