import SwiftUI

/// Editor for a project's optional `aiExtraVocabulary` — per-project
/// additions to the controlled vocabulary that get sent to Claude
/// alongside the main vocab block and accepted by the validator,
/// without ever touching the app-wide `TagLibrary`.
///
/// Two-level structure:
/// - Root list: primaries (engineer-named tags like "Custom site
///   condition").
/// - Drill-down per primary: secondaries.
///
/// Modelled after `TagLibraryManagerSheet` but scoped to a single
/// project and a single synthetic "Job-Specific Additions" context,
/// so the engineer doesn't have to invent context names. The wire
/// format Claude sees mirrors the main vocabulary block exactly.
struct ProjectExtraVocabularySheet: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var addingPrimaryName: String = ""
    @State private var showingAddPrimaryPrompt: Bool = false
    @State private var renamingPrimary: PrimaryTagEntry?
    @State private var renamePrimaryDraft: String = ""

    private var project: Project? {
        store.project(withID: projectID)
    }

    private var extras: ProjectExtraVocabulary {
        project?.aiExtraVocabulary ?? ProjectExtraVocabulary()
    }

    var body: some View {
        NavigationStack {
            Group {
                if let project {
                    if extras.primaries.isEmpty {
                        emptyState(for: project)
                    } else {
                        primariesList(for: project)
                    }
                } else {
                    Text("Project no longer available.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Job-Specific Vocabulary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            addingPrimaryName = ""
                            showingAddPrimaryPrompt = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .accessibilityLabel("Add Primary Tag")
                        EditButton()
                    }
                }
            }
            .alert("New Primary Tag",
                   isPresented: $showingAddPrimaryPrompt) {
                TextField("Name (e.g. Custom site condition)", text: $addingPrimaryName)
                    .textInputAutocapitalization(.words)
                Button("Add") { addPrimary() }
                    .disabled(addingPrimaryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Tags you add here are sent to Claude for THIS project only — they're never added to the app-wide tag library and other projects don't see them.")
            }
            .alert("Rename primary",
                   isPresented: Binding(
                    get: { renamingPrimary != nil },
                    set: { if !$0 { renamingPrimary = nil } }
                   )) {
                TextField("Name", text: $renamePrimaryDraft)
                Button("Save") { commitPrimaryRename() }
                Button("Cancel", role: .cancel) { renamingPrimary = nil }
            }
        }
    }

    // MARK: - States

    @ViewBuilder
    private func emptyState(for project: Project) -> some View {
        EmptyStateView(
            icon: "tag.fill",
            title: "No job-specific tags yet",
            message: "Use the + button to add primary tags that should be sent to Claude for this project only. Each primary can carry its own secondary tags.\n\nThe app-wide tag library is never modified by entries you add here."
        )
    }

    @ViewBuilder
    private func primariesList(for project: Project) -> some View {
        List {
            Section {
                ForEach(extras.primaries) { primary in
                    NavigationLink {
                        PrimaryDetailView(projectID: projectID,
                                            primaryID: primary.id)
                            .environment(store)
                            .environment(toastCenter)
                    } label: {
                        primaryRow(primary)
                    }
                }
                .onMove { source, dest in
                    let updated = store.reorderExtraPrimaries(project,
                                                                from: source,
                                                                to: dest)
                    _ = updated
                }
                .onDelete { offsets in
                    var p = project
                    for offset in offsets {
                        let primary = extras.primaries[offset]
                        p = store.deleteExtraPrimary(p, primaryID: primary.id)
                    }
                    Haptics.confirm()
                }
            } footer: {
                Text("These tags are appended to the controlled vocabulary block in this project's AI prompt and accepted by the response validator. They don't appear in the AI Tags picker (where you scope the app-wide library) and don't change the library.")
            }
        }
    }

    @ViewBuilder
    private func primaryRow(_ primary: PrimaryTagEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primary.name)
                    .font(.body)
                let count = primary.secondaries.count
                Text("\(count) secondar\(count == 1 ? "y" : "ies")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    renamingPrimary = primary
                    renamePrimaryDraft = primary.name
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    guard let project else { return }
                    _ = store.deleteExtraPrimary(project, primaryID: primary.id)
                    Haptics.confirm()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func addPrimary() {
        guard let project else { return }
        let name = addingPrimaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = store.addExtraPrimary(project, name: name)
        addingPrimaryName = ""
        Haptics.success()
        toastCenter.post("Added \"\(name)\"", kind: .success)
    }

    private func commitPrimaryRename() {
        guard let project, let target = renamingPrimary else { return }
        let name = renamePrimaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            renamingPrimary = nil
            return
        }
        _ = store.renameExtraPrimary(project, primaryID: target.id, to: name)
        renamingPrimary = nil
        renamePrimaryDraft = ""
        Haptics.tap()
    }
}

// MARK: - Primary detail (secondaries within one extras primary)

private struct PrimaryDetailView: View {
    let projectID: UUID
    let primaryID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter

    @State private var addingSecondaryName: String = ""
    @State private var showingAddSecondaryPrompt: Bool = false
    @State private var renamingSecondary: SecondaryTagEntry?
    @State private var renameSecondaryDraft: String = ""

    private var project: Project? {
        store.project(withID: projectID)
    }

    private var primary: PrimaryTagEntry? {
        project?.aiExtraVocabulary?.primaries.first { $0.id == primaryID }
    }

    var body: some View {
        Group {
            if let primary {
                if primary.secondaries.isEmpty {
                    EmptyStateView(
                        icon: "tag",
                        title: "No secondaries yet",
                        message: "Use the + button to add secondary tags under \"\(primary.name)\". Claude must pair this primary with one of its secondaries (or the primary alone) in valid responses."
                    )
                } else {
                    secondariesList(primary)
                }
            } else {
                Text("This primary no longer exists.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(primary?.name ?? "Primary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        addingSecondaryName = ""
                        showingAddSecondaryPrompt = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel("Add Secondary Tag")
                    EditButton()
                }
            }
        }
        .alert("New Secondary Tag",
               isPresented: $showingAddSecondaryPrompt) {
            TextField("Name (e.g. Distinct observation)",
                      text: $addingSecondaryName)
                .textInputAutocapitalization(.sentences)
            Button("Add") { addSecondary() }
                .disabled(addingSecondaryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename secondary",
               isPresented: Binding(
                get: { renamingSecondary != nil },
                set: { if !$0 { renamingSecondary = nil } }
               )) {
            TextField("Name", text: $renameSecondaryDraft)
            Button("Save") { commitSecondaryRename() }
            Button("Cancel", role: .cancel) { renamingSecondary = nil }
        }
    }

    @ViewBuilder
    private func secondariesList(_ primary: PrimaryTagEntry) -> some View {
        List {
            ForEach(primary.secondaries) { secondary in
                HStack {
                    Text(secondary.name)
                    Spacer()
                    Menu {
                        Button {
                            renamingSecondary = secondary
                            renameSecondaryDraft = secondary.name
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            guard let project else { return }
                            _ = store.deleteExtraSecondary(project,
                                                             primaryID: primaryID,
                                                             secondaryID: secondary.id)
                            Haptics.confirm()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onMove { source, dest in
                guard let project else { return }
                _ = store.reorderExtraSecondaries(project,
                                                    primaryID: primaryID,
                                                    from: source,
                                                    to: dest)
            }
            .onDelete { offsets in
                guard let project else { return }
                var p = project
                for offset in offsets {
                    let secondary = primary.secondaries[offset]
                    p = store.deleteExtraSecondary(p,
                                                     primaryID: primaryID,
                                                     secondaryID: secondary.id)
                }
                Haptics.confirm()
            }
        }
    }

    private func addSecondary() {
        guard let project else { return }
        let name = addingSecondaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = store.addExtraSecondary(project, primaryID: primaryID, name: name)
        addingSecondaryName = ""
        Haptics.success()
        toastCenter.post("Added \"\(name)\"", kind: .success)
    }

    private func commitSecondaryRename() {
        guard let project, let target = renamingSecondary else { return }
        let name = renameSecondaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            renamingSecondary = nil
            return
        }
        _ = store.renameExtraSecondary(project,
                                         primaryID: primaryID,
                                         secondaryID: target.id,
                                         to: name)
        renamingSecondary = nil
        renameSecondaryDraft = ""
        Haptics.tap()
    }
}
