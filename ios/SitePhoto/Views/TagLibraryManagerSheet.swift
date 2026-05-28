import SwiftUI

/// App-wide editor for the three-level tag library. Drill-down
/// navigation: contexts → primaries → secondaries. Every level has the
/// same affordances — add, rename, delete, reorder via EditButton —
/// implemented through the matching `ProjectStore.addTag…` / `renameTag…`
/// / `deleteTag…` / `reorderTag…` helpers.
///
/// Mirror of `BucketLibraryManagerSheet.swift`'s patterns, extended to
/// three levels because tag classification is finer-grained than the
/// bucket library's two.
struct TagLibraryManagerSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var addingContextName: String = ""
    @State private var showingAddContextPrompt: Bool = false
    @State private var renamingContext: InvestigationContext?
    @State private var renameContextDraft: String = ""
    @State private var showingRestoreConfirm: Bool = false

    private var contexts: [InvestigationContext] { store.tagLibrary.contexts }

    var body: some View {
        NavigationStack {
            Group {
                if contexts.isEmpty {
                    VStack(spacing: 16) {
                        EmptyStateView(
                            icon: "books.vertical",
                            title: "Library is empty",
                            message: "Add an Investigation Context to start. Each context holds primary tags, and each primary tag holds secondary tags."
                        )
                        Button(role: .destructive) {
                            showingRestoreConfirm = true
                        } label: {
                            Label("Restore to default seed",
                                  systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    List {
                        ForEach(contexts) { ctx in
                            NavigationLink {
                                ContextDetailView(contextID: ctx.id)
                                    .environment(store)
                                    .environment(toastCenter)
                            } label: {
                                contextRow(ctx)
                            }
                        }
                        .onMove { source, dest in
                            store.reorderTagContexts(from: source, to: dest)
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                let ctx = contexts[offset]
                                _ = store.deleteTagContext(ctx.id)
                            }
                            Haptics.confirm()
                        }

                        Section {
                            Button(role: .destructive) {
                                showingRestoreConfirm = true
                            } label: {
                                Label("Restore to default seed",
                                      systemImage: "arrow.uturn.backward")
                            }
                        } footer: {
                            Text("Replaces every context, primary, and secondary with the bundled default vocabulary. Project tag selections and the AI Tagging Rules template are not affected.")
                        }
                    }
                }
            }
            .navigationTitle("Tag Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            addingContextName = ""
                            showingAddContextPrompt = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .accessibilityLabel("Add Investigation Context")
                        EditButton()
                    }
                }
            }
            .alert("New Investigation Context",
                   isPresented: $showingAddContextPrompt) {
                TextField("Name (e.g. Moisture Intrusion)", text: $addingContextName)
                    .textInputAutocapitalization(.words)
                Button("Add") { addContext() }
                    .disabled(addingContextName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Contexts group primary tags by the kind of investigation you're running. The per-project picker uses them to scope which tags the AI considers.")
            }
            .alert("Rename context",
                   isPresented: Binding(
                    get: { renamingContext != nil },
                    set: { if !$0 { renamingContext = nil } }
                   )) {
                TextField("Name", text: $renameContextDraft)
                Button("Save") { commitContextRename() }
                Button("Cancel", role: .cancel) { renamingContext = nil }
            }
            .confirmationDialog(
                "Restore tag library to default?",
                isPresented: $showingRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("Restore", role: .destructive) {
                    store.restoreTagLibraryToDefaults()
                    Haptics.confirm()
                    toastCenter.post("Tag library restored to default", kind: .success)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This replaces every context, primary, and secondary you've edited with the bundled vocabulary. Project tag selections and the rules template are left alone.")
            }
        }
    }

    @ViewBuilder
    private func contextRow(_ ctx: InvestigationContext) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Investigation Context")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(ctx.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            Spacer()
            Text("\(ctx.primaries.count)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Menu {
                Button {
                    renamingContext = ctx
                    renameContextDraft = ctx.name
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    if store.deleteTagContext(ctx.id) {
                        Haptics.confirm()
                        toastCenter.post("Deleted context \"\(ctx.name)\"", kind: .success)
                    }
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

    private func addContext() {
        guard let ctx = store.addTagContext(name: addingContextName) else { return }
        Haptics.success()
        toastCenter.post("Added context \"\(ctx.name)\"", kind: .success)
        addingContextName = ""
    }

    private func commitContextRename() {
        guard let ctx = renamingContext else { return }
        _ = store.renameTagContext(ctx.id, to: renameContextDraft)
        renamingContext = nil
        renameContextDraft = ""
        Haptics.tap()
    }
}

// MARK: - Context detail (primaries within one context)

private struct ContextDetailView: View {
    let contextID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter

    @State private var addingPrimaryName: String = ""
    @State private var showingAddPrimaryPrompt: Bool = false
    @State private var renamingPrimary: PrimaryTagEntry?
    @State private var renamePrimaryDraft: String = ""

    /// Resolve fresh each render so the view stays in sync with library
    /// edits made elsewhere (e.g. a rename in the parent list).
    private var context: InvestigationContext? {
        store.tagLibrary.contexts.first { $0.id == contextID }
    }

    var body: some View {
        Group {
            if let ctx = context {
                if ctx.primaries.isEmpty {
                    emptyState
                } else {
                    primariesList(ctx)
                }
            } else {
                Text("Context no longer exists.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(context?.name ?? "Context")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            TextField("Name (e.g. Drainage / Grading)", text: $addingPrimaryName)
                .textInputAutocapitalization(.words)
            Button("Add") { addPrimary() }
                .disabled(addingPrimaryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Primary tags name the element or condition being observed. Each one holds its own list of secondary tags.")
        }
        .alert("Rename primary tag",
               isPresented: Binding(
                get: { renamingPrimary != nil },
                set: { if !$0 { renamingPrimary = nil } }
               )) {
            TextField("Name", text: $renamePrimaryDraft)
            Button("Save") { commitPrimaryRename() }
            Button("Cancel", role: .cancel) { renamingPrimary = nil }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        EmptyStateView(
            icon: "tag",
            title: "No primary tags yet",
            message: "Tap + above to add the first primary tag for this context."
        )
    }

    @ViewBuilder
    private func primariesList(_ ctx: InvestigationContext) -> some View {
        List {
            ForEach(ctx.primaries) { primary in
                NavigationLink {
                    PrimaryDetailView(contextID: ctx.id, primaryID: primary.id)
                        .environment(store)
                        .environment(toastCenter)
                } label: {
                    primaryRow(ctx: ctx, primary: primary)
                }
            }
            .onMove { source, dest in
                store.reorderTagPrimaries(inContext: ctx.id, from: source, to: dest)
            }
            .onDelete { offsets in
                for offset in offsets {
                    let primary = ctx.primaries[offset]
                    _ = store.deleteTagPrimary(inContext: ctx.id, primary: primary.id)
                }
                Haptics.confirm()
            }
        }
    }

    @ViewBuilder
    private func primaryRow(ctx: InvestigationContext,
                              primary: PrimaryTagEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Primary Tag")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(primary.name)
                    .font(.callout)
            }
            Spacer()
            Text("\(primary.secondaries.count)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Menu {
                Button {
                    renamingPrimary = primary
                    renamePrimaryDraft = primary.name
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    if store.deleteTagPrimary(inContext: ctx.id, primary: primary.id) {
                        Haptics.confirm()
                    }
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

    private func addPrimary() {
        guard let ctx = context else { return }
        guard let primary = store.addTagPrimary(toContext: ctx.id,
                                                  name: addingPrimaryName) else { return }
        Haptics.success()
        toastCenter.post("Added primary \"\(primary.name)\"", kind: .success)
        addingPrimaryName = ""
    }

    private func commitPrimaryRename() {
        guard let ctx = context, let primary = renamingPrimary else { return }
        _ = store.renameTagPrimary(inContext: ctx.id,
                                     primary: primary.id,
                                     to: renamePrimaryDraft)
        renamingPrimary = nil
        renamePrimaryDraft = ""
        Haptics.tap()
    }
}

// MARK: - Primary detail (secondaries within one primary tag)

private struct PrimaryDetailView: View {
    let contextID: UUID
    let primaryID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter

    @State private var addingSecondaryName: String = ""
    @State private var showingAddSecondaryPrompt: Bool = false
    @State private var renamingSecondary: SecondaryTagEntry?
    @State private var renameSecondaryDraft: String = ""

    private var primary: PrimaryTagEntry? {
        store.tagLibrary.contexts
            .first { $0.id == contextID }?
            .primaries.first { $0.id == primaryID }
    }

    var body: some View {
        Group {
            if let primary {
                if primary.secondaries.isEmpty {
                    EmptyStateView(
                        icon: "tag",
                        title: "No secondary tags yet",
                        message: "Tap + above to add the first secondary tag for this primary."
                    )
                } else {
                    secondariesList(primary)
                }
            } else {
                Text("Primary no longer exists.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(primary?.name ?? "Primary Tag")
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
            TextField("Name (e.g. Slab crack)", text: $addingSecondaryName)
                .textInputAutocapitalization(.sentences)
            Button("Add") { addSecondary() }
                .disabled(addingSecondaryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Secondary tags describe the specific condition observed under this primary. They appear verbatim in Claude's tag suggestions.")
        }
        .alert("Rename secondary tag",
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
                secondaryRow(secondary)
            }
            .onMove { source, dest in
                store.reorderTagSecondaries(inContext: contextID,
                                              primary: primaryID,
                                              from: source, to: dest)
            }
            .onDelete { offsets in
                for offset in offsets {
                    let secondary = primary.secondaries[offset]
                    _ = store.deleteTagSecondary(inContext: contextID,
                                                   primary: primaryID,
                                                   secondary: secondary.id)
                }
                Haptics.confirm()
            }
        }
    }

    @ViewBuilder
    private func secondaryRow(_ secondary: SecondaryTagEntry) -> some View {
        HStack(spacing: 8) {
            Text(secondary.name)
                .font(.callout)
            Spacer()
            Button {
                renamingSecondary = secondary
                renameSecondaryDraft = secondary.name
            } label: {
                Image(systemName: "pencil")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func addSecondary() {
        guard let entry = store.addTagSecondary(inContext: contextID,
                                                  primary: primaryID,
                                                  name: addingSecondaryName) else { return }
        Haptics.success()
        toastCenter.post("Added secondary \"\(entry.name)\"", kind: .success)
        addingSecondaryName = ""
    }

    private func commitSecondaryRename() {
        guard let secondary = renamingSecondary else { return }
        _ = store.renameTagSecondary(inContext: contextID,
                                       primary: primaryID,
                                       secondary: secondary.id,
                                       to: renameSecondaryDraft)
        renamingSecondary = nil
        renameSecondaryDraft = ""
        Haptics.tap()
    }
}
