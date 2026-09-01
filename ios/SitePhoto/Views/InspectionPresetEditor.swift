import SwiftUI

/// Edits the reusable library entry only. Applying it to a project remains a
/// separate reviewed action in InspectionPresetsView.
struct InspectionPresetEditor: View {
    let projectID: UUID
    private let presetID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding private var library: WorkflowLibrary
    @Binding private var revision: String?
    @State private var baseRevision: String?
    @State private var name: String
    @State private var requiredViews: String
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var reloaded = false

    init(projectID: UUID, preset: InspectionPreset,
         library: Binding<WorkflowLibrary>, revision: Binding<String?>) {
        self.projectID = projectID
        self.presetID = preset.id
        self._library = library
        self._revision = revision
        self._baseRevision = State(initialValue: revision.wrappedValue)
        self._name = State(initialValue: preset.name)
        self._requiredViews = State(initialValue: preset.checklist.joined(separator: "\n"))
    }

    private var currentPreset: InspectionPreset? {
        library.inspectionPresets.first { $0.id == presetID }
    }
    private var writable: Bool {
        !busy && currentPreset != nil && store.project(withID: projectID).map(store.isReadOnly) == false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset details") {
                    TextField("Preset name", text: $name)
                    TextField("Required views (one per line)", text: $requiredViews, axis: .vertical)
                        .lineLimit(3...8)
                    Text("Changes only this saved preset. Its other settings and existing projects stay unchanged until you separately apply the preset.")
                        .font(.caption)
                }.disabled(busy)
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        Button("Reload saved library, keep draft") { Task { await reload() } }.disabled(busy)
                    }
                }
                if reloaded, let currentPreset {
                    Section("Saved version after reload — review before saving") {
                        Text(currentPreset.name)
                        ForEach(Array(currentPreset.checklist.enumerated()), id: \.offset) { _, label in Text(label) }
                        Text("Your name and required-view draft above were kept. Saving replaces these fields in the saved version.")
                            .font(.caption)
                    }
                }
                if busy { ProgressView("Saving or loading…") }
            }
            .navigationTitle("Edit Inspection Preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!writable || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func save() async {
        guard writable, let api = store.apiClient else { return }
        guard revision == baseRevision, let index = library.inspectionPresets.firstIndex(where: { $0.id == presetID }) else {
            errorMessage = "The saved library changed. Reload it and review before saving; your draft is kept."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = requiredViews.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !trimmedName.isEmpty, trimmedName.utf16.count <= 100,
              labels.count <= 200, labels.allSatisfy({ $0.utf16.count <= 500 }) else {
            errorMessage = "Use a name of 1–100 characters and at most 200 required views, each up to 500 characters."
            return
        }
        var next = library
        next.inspectionPresets[index].name = trimmedName
        next.inspectionPresets[index].checklist = labels
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let response = try await api.saveWorkflowLibrary(next, expectedRevision: baseRevision)
            library = next; revision = response.revision
            dismiss()
        } catch {
            errorMessage = "Preset not saved: " + error.localizedDescription + " Your draft is kept. Reload the saved library before retrying a conflict."
        }
    }

    private func reload() async {
        guard !busy, let api = store.apiClient else { return }
        busy = true
        defer { busy = false }
        do {
            let response = try await api.workflowLibrary()
            library = response.library; revision = response.revision; baseRevision = response.revision
            reloaded = true
            errorMessage = currentPreset == nil ? "This preset was deleted on another device. Your draft remains visible, but it cannot overwrite the deletion." : nil
        } catch { errorMessage = "Library reload failed: " + error.localizedDescription }
    }
}
