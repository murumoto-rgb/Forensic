import SwiftUI

struct ProjectWorkflowSection: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @State private var showingHealth = false
    @State private var showingPresets = false
    @State private var newItem = ""

    var body: some View {
        if let project = store.project(withID: projectID) {
            Section("Inspection session") {
                let running = project.inspectionSessions.contains { $0.endedAt == nil }
                Text(running ? "Visit in progress" : project.startedAt == nil ? "Not started" : "Visit stopped")
                Text("\(project.inspectionSessions.count) recorded visit(s)").font(.caption)
                Button(running ? "Stop visit" : project.startedAt == nil ? "Start inspection" : "Resume inspection") {
                    if running { store.stopSession(project) } else { store.startSession(project) }
                }.disabled(store.isReadOnly(project))
                ForEach(project.inspectionSessions.suffix(5)) { session in
                    Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) → \(session.endedAt?.formatted(date: .omitted, time: .shortened) ?? "In progress")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Inspection checklist") {
                ForEach(project.inspectionChecklist) { item in
                    Toggle(item.label, isOn: Binding(
                        get: { store.project(withID: projectID)?.inspectionChecklist.first { $0.id == item.id }?.isComplete ?? false },
                        set: { completed in
                            guard var latest = store.project(withID: projectID),
                                  let index = latest.inspectionChecklist.firstIndex(where: { $0.id == item.id }) else { return }
                            latest.inspectionChecklist[index].isComplete = completed
                            store.save(latest)
                        }))
                        .disabled(store.isReadOnly(project))
                        .swipeActions { Button("Remove", role: .destructive) { removeItem(item.id) }
                            .disabled(store.isReadOnly(project)) }
                }
                if !store.isReadOnly(project) {
                    TextField("Required view or inspection step", text: $newItem)
                    Button("Add checklist item") {
                        guard var latest = store.project(withID: projectID) else { return }
                        latest.inspectionChecklist.append(.init(label: newItem.trimmingCharacters(in: .whitespacesAndNewlines)))
                        store.save(latest); newItem = ""
                    }.disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.inspectionChecklist.count >= 200)
                }
                Text("Completing a step records your review; it does not certify an AI finding.").font(.caption)
            }
            Section("Report layout for this inspection") {
                Picker("Photos per page", selection: Binding(
                    get: { project.reportLayout?.perPage ?? 6 },
                    set: { value in updateLayout { $0.perPage = value } })) {
                    ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Group by bucket", isOn: Binding(
                    get: { project.reportLayout?.groupByBucket ?? false },
                    set: { value in updateLayout { $0.groupByBucket = value } }))
                Toggle("Include metadata table", isOn: Binding(
                    get: { project.reportLayout?.includeMetadataTable ?? false },
                    set: { value in updateLayout { $0.includeMetadataTable = value } }))
                Text("These defaults are included when you save an inspection preset. You can still change them for an individual export.").font(.caption)
            }.disabled(store.isReadOnly(project))
            Section("Recovery and reusable setup") {
                Button { showingHealth = true } label: { Label("Project Health & Version History", systemImage: "checkmark.shield") }
                Button { showingPresets = true } label: { Label("Inspection Presets", systemImage: "list.clipboard") }
            }
            .sheet(isPresented: $showingHealth) { ProjectHealthView(projectID: projectID) }
            .sheet(isPresented: $showingPresets) { InspectionPresetsView(projectID: projectID) }
        }
    }

    private func removeItem(_ id: UUID) {
        guard var latest = store.project(withID: projectID), !store.isReadOnly(latest) else { return }
        latest.inspectionChecklist.removeAll { $0.id == id }
        store.save(latest)
    }

    private func updateLayout(_ change: (inout InspectionReportLayout) -> Void) {
        guard var latest = store.project(withID: projectID), !store.isReadOnly(latest) else { return }
        var layout = latest.reportLayout ?? .init()
        change(&layout)
        latest.reportLayout = layout
        store.save(latest)
    }
}
