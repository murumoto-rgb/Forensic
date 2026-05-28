import SwiftUI

struct NewProjectView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let onCreated: (Project) -> Void

    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project name") {
                    TextField("e.g. 1234 Main St — settlement survey", text: $name, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                }

                Section {
                    Label {
                        Text("After creation you'll tap Start to record the project's GPS location and address. The app will request Location and Camera access on first use.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { nameFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard canSave else { return }
        var project = Project(name: trimmedName)
        // After the v2 library flatten, new projects ship with every
        // primary in the single Forensic Investigation context picked
        // so the engineer doesn't have to navigate to AI Tags before
        // tagging the first photo. They can deselect anything they
        // don't want via the AI Tags picker.
        project.tagSelection = store.defaultTagSelection()
        let saved = store.save(project)
        dismiss()
        onCreated(saved)
    }
}
