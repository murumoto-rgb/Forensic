import SwiftUI

struct InspectionPresetsView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var library = WorkflowLibrary()
    @State private var revision: String?
    @State private var loaded = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var name = ""
    @State private var requiredViews = ""
    @State private var selection: PresetSheet?
    private var project: Project? { store.project(withID: projectID) }
    private var writable: Bool { loaded && !busy && project.map(store.isReadOnly) == false }

    private enum PresetSheet: Identifiable {
        case preview(InspectionPreset, Project?)
        case edit(InspectionPreset)
        var id: String {
            switch self {
            case .preview(let preset, _): return "preview-" + preset.id.uuidString
            case .edit(let preset): return "edit-" + preset.id.uuidString
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Save current setup as a preset") {
                    TextField("Preset name", text: $name)
                    TextField("Required views (one per line)", text: $requiredViews, axis: .vertical).lineLimit(3...8)
                    Text("Saves the current address, AI notes, vocabulary, buckets and report layout. Photos and completed checklist states are never copied.").font(.caption)
                    Button("Save reusable preset") { Task { await saveCurrent() } }
                        .disabled(!writable || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Your presets · synced across devices") {
                    ForEach(library.inspectionPresets) { preset in
                        HStack {
                            Button { selection = .preview(preset, project) } label: {
                                VStack(alignment: .leading) {
                                    Text(preset.name)
                                    Text("\(preset.checklist.count) steps · \(preset.buckets.count) buckets").font(.caption)
                                }
                            }.buttonStyle(.plain).disabled(busy)
                            Spacer()
                            Button("Edit") { selection = .edit(preset) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Edit \(preset.name)")
                                .disabled(!writable)
                        }
                        .swipeActions { Button("Delete", role: .destructive) {
                            Task {
                                var next = library
                                next.inspectionPresets.removeAll { $0.id == preset.id }
                                await save(next)
                            }
                        }.disabled(!writable) }
                    }
                    if loaded && library.inspectionPresets.isEmpty { Text("No saved presets yet.").foregroundStyle(.secondary) }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        Button("Reload saved library") { Task { await load() } }.disabled(busy)
                        Text("Reload keeps the name and required-view text above. It never overwrites another device's saved library.").font(.caption)
                    }
                }
                if busy { ProgressView("Saving or loading…") }
            }
            .navigationTitle("Inspection Presets")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                requiredViews = project?.inspectionChecklist.map(\.label).joined(separator: "\n") ?? ""
                await load()
            }
            .sheet(item: $selection) { sheet in
                switch sheet {
                case .preview(let preset, let capturedProject):
                    previewSheet(preset, capturedProject: capturedProject)
                case .edit(let preset):
                    InspectionPresetEditor(projectID: projectID, preset: preset,
                        library: $library, revision: $revision)
                }
            }
        }
    }

    private func previewSheet(_ preset: InspectionPreset, capturedProject: Project?) -> some View {
        NavigationStack {
            List {
                Section("Review before applying") {
                    Text(preset.name).font(.headline)
                    Text("Address fills only if this project has no address.")
                    Text("AI notes and selected vocabulary will be replaced.")
                    Text("Adds \(preset.buckets.count) fresh buckets and \(preset.checklist.count) incomplete checklist steps. Existing photos, captions and assignments are preserved.")
                    Text("Report: \(preset.reportLayout.perPage) photos/page; bucket grouping \(preset.reportLayout.groupByBucket ? "on" : "off").")
                    if let instructions = preset.aiInstructions { Text(instructions).font(.caption) }
                }
                Section("Required views") {
                    ForEach(Array(preset.checklist.enumerated()), id: \.offset) { _, label in Text(label) }
                }
                Section {
                    Button("Apply reviewed preset") {
                        guard let current = project, current == capturedProject, !store.isReadOnly(current) else {
                            errorMessage = "Project changed or is read-only. Close this preview and review again."; return
                        }
                        store.save(preset.preview(on: current))
                        selection = nil
                    }.disabled(project.map(store.isReadOnly) != false)
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Preset Preview")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { selection = nil } } }
        }
    }
    private func load() async {
        guard let api = store.apiClient, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let response = try await api.workflowLibrary()
            library = response.library; revision = response.revision; loaded = true; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    private func saveCurrent() async {
        guard let project, writable else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.utf16.count <= 100 else {
            errorMessage = "Use a preset name from 1 to 100 characters."; return
        }
        let labels = requiredViews.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard labels.count <= 200, labels.allSatisfy({ $0.utf16.count <= 500 }) else {
            errorMessage = "Use at most 200 checklist steps, each under 500 characters."; return
        }
        let preset = InspectionPreset(name: trimmedName,
            projectNamePrefix: project.name, projectAddress: project.projectAddress,
            aiInstructions: project.aiInstructions, tagSelection: project.tagSelection,
            aiExtraVocabulary: project.aiExtraVocabulary, buckets: project.buckets, checklist: labels,
            reportLayout: project.reportLayout ?? .init())
        var next = library
        next.inspectionPresets.append(preset)
        await save(next)
    }
    private func save(_ next: WorkflowLibrary) async {
        guard let api = store.apiClient, writable else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let response = try await api.saveWorkflowLibrary(next, expectedRevision: revision)
            revision = response.revision; library = next; name = ""
        } catch {
            errorMessage = "Preset not saved: " + error.localizedDescription + " Reload the library before retrying a conflict."
        }
    }
}
