import SwiftUI

/// Per-project picker for `ProjectTagSelection`. Mirrors the layered
/// structure of the app-wide `TagLibrary`: each library context is a
/// collapsible section, each primary tag inside it is a checkable row,
/// and each primary discloses its secondary tags for fine-grained
/// inclusion. Edits live in a draft `ProjectTagSelection` that's only
/// persisted on Save — Cancel discards.
///
/// "Picking" follows three nested rules:
///   * Picking a context auto-picks all its primaries.
///   * Picking a primary auto-includes all its secondaries.
///   * Deselecting a secondary doesn't unpick the primary — the picker
///     just tracks it in `deselectedSecondariesByPrimary`.
struct ProjectTagSelectionSheet: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProjectTagSelection = ProjectTagSelection()
    @State private var loaded: Bool = false
    @State private var showingLibrary: Bool = false
    @State private var showingPreview: Bool = false
    @State private var expandedPrimaries: Set<UUID> = []

    private var project: Project? { store.project(withID: projectID) }
    private var contexts: [InvestigationContext] { store.tagLibrary.contexts }

    private var dirty: Bool {
        guard let project else { return false }
        return draft != (project.tagSelection ?? ProjectTagSelection())
    }

    private var pickedSummary: String {
        let ctxCount = draft.contextIDs.count
        let primaryCount = draft.primariesByContext.values
            .reduce(0) { $0 + $1.count }
        return "\(ctxCount) context\(ctxCount == 1 ? "" : "s"), \(primaryCount) primary tag\(primaryCount == 1 ? "" : "s")"
    }

    var body: some View {
        NavigationStack {
            Group {
                if contexts.isEmpty {
                    EmptyStateView(
                        icon: "books.vertical",
                        title: "Tag library is empty",
                        message: "Open Manage Library to add an investigation context and at least one primary tag, then come back here to pick which apply to this project."
                    )
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pickedSummary)
                                    .font(.callout)
                                Text("Picked tags are sent to the AI as the controlled vocabulary for this project. Adding new tags here doesn't change the app-wide library — use Manage Library for that.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        ForEach(contexts) { ctx in
                            contextSection(ctx)
                        }
                    }
                }
            }
            .navigationTitle("AI Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!dirty)
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button {
                            showingLibrary = true
                        } label: {
                            Label("Manage Library", systemImage: "slider.horizontal.3")
                        }
                        Spacer()
                        Button {
                            showingPreview = true
                        } label: {
                            Label("Preview Prompt", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingLibrary) {
                TagLibraryManagerSheet()
                    .environment(store)
                    .environment(toastCenter)
            }
            .sheet(isPresented: $showingPreview) {
                AIPromptPreviewSheet(projectID: projectID,
                                      draftSelection: dirty ? draft : nil)
                    .environment(store)
            }
            .onAppear { loadIfNeeded() }
        }
    }

    // MARK: - Context section

    @ViewBuilder
    private func contextSection(_ ctx: InvestigationContext) -> some View {
        let isIncluded = draft.contextIDs.contains(ctx.id)
        Section {
            if isIncluded {
                if ctx.primaries.isEmpty {
                    Text("No primary tags in this context. Use Manage Library to add some.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(ctx.primaries) { primary in
                    primaryRow(ctx: ctx, primary: primary)
                    if expandedPrimaries.contains(primary.id),
                       draft.isPrimarySelected(primary.id, in: ctx.id) {
                        ForEach(primary.secondaries) { secondary in
                            secondaryRow(primary: primary, secondary: secondary)
                        }
                    }
                }
            }
        } header: {
            contextHeader(ctx, isIncluded: isIncluded)
        }
    }

    @ViewBuilder
    private func contextHeader(_ ctx: InvestigationContext, isIncluded: Bool) -> some View {
        Button {
            toggleContext(ctx)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isIncluded ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("INVESTIGATION CONTEXT")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(ctx.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
                Spacer()
                if isIncluded {
                    let picked = draft.primariesByContext[ctx.id]?.count ?? 0
                    Text("\(picked)/\(ctx.primaries.count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Primary row

    @ViewBuilder
    private func primaryRow(ctx: InvestigationContext, primary: PrimaryTagEntry) -> some View {
        let isPicked = draft.isPrimarySelected(primary.id, in: ctx.id)
        HStack(spacing: 10) {
            Button {
                togglePrimary(primary, in: ctx)
            } label: {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary.name)
                    .font(.callout)
                if isPicked {
                    Text(secondaryCountLabel(for: primary))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isPicked && !primary.secondaries.isEmpty {
                Button {
                    toggleExpansion(primary.id)
                } label: {
                    Image(systemName: expandedPrimaries.contains(primary.id)
                          ? "chevron.down"
                          : "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isPicked && !primary.secondaries.isEmpty {
                toggleExpansion(primary.id)
            } else {
                togglePrimary(primary, in: ctx)
            }
        }
    }

    private func secondaryCountLabel(for primary: PrimaryTagEntry) -> String {
        let deselected = draft.deselectedSecondariesByPrimary[primary.id]?.count ?? 0
        let active = primary.secondaries.count - deselected
        return "\(active)/\(primary.secondaries.count) secondaries"
    }

    // MARK: - Secondary row (indented under a primary)

    @ViewBuilder
    private func secondaryRow(primary: PrimaryTagEntry, secondary: SecondaryTagEntry) -> some View {
        let isActive = draft.isSecondaryActive(secondary.id, under: primary.id)
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .font(.body)
                .padding(.leading, 26)
            Text(secondary.name)
                .font(.callout)
                .foregroundStyle(isActive ? .primary : .secondary)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggleSecondary(secondary, under: primary)
        }
    }

    // MARK: - Toggle helpers (operate on the draft)

    private func toggleContext(_ ctx: InvestigationContext) {
        if let idx = draft.contextIDs.firstIndex(of: ctx.id) {
            // Unpick: drop the context and clear any nested picks.
            draft.contextIDs.remove(at: idx)
            draft.primariesByContext.removeValue(forKey: ctx.id)
            for primary in ctx.primaries {
                draft.deselectedSecondariesByPrimary.removeValue(forKey: primary.id)
                expandedPrimaries.remove(primary.id)
            }
        } else {
            // Pick: include context + all its primaries by default.
            draft.contextIDs.append(ctx.id)
            draft.primariesByContext[ctx.id] = Set(ctx.primaries.map(\.id))
        }
        Haptics.tap()
    }

    private func togglePrimary(_ primary: PrimaryTagEntry, in ctx: InvestigationContext) {
        var picked = draft.primariesByContext[ctx.id] ?? []
        if picked.contains(primary.id) {
            picked.remove(primary.id)
            draft.deselectedSecondariesByPrimary.removeValue(forKey: primary.id)
            expandedPrimaries.remove(primary.id)
        } else {
            picked.insert(primary.id)
            // New picks include every secondary by default — clear any
            // leftover deselections from a previous pick of this same
            // primary so we start with a clean slate.
            draft.deselectedSecondariesByPrimary.removeValue(forKey: primary.id)
        }
        draft.primariesByContext[ctx.id] = picked.isEmpty ? nil : picked
        Haptics.tap()
    }

    private func toggleSecondary(_ secondary: SecondaryTagEntry, under primary: PrimaryTagEntry) {
        var deselected = draft.deselectedSecondariesByPrimary[primary.id] ?? []
        if deselected.contains(secondary.id) {
            deselected.remove(secondary.id)
        } else {
            deselected.insert(secondary.id)
        }
        draft.deselectedSecondariesByPrimary[primary.id] = deselected.isEmpty ? nil : deselected
        Haptics.tap()
    }

    private func toggleExpansion(_ primaryID: UUID) {
        if expandedPrimaries.contains(primaryID) {
            expandedPrimaries.remove(primaryID)
        } else {
            expandedPrimaries.insert(primaryID)
        }
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded, let project else { return }
        draft = project.tagSelection ?? ProjectTagSelection()
        loaded = true
    }

    private func save() {
        guard let project else { return }
        let cleaned = sanitize(draft)
        _ = store.setTagSelection(project, cleaned.isEmpty ? nil : cleaned)
        Haptics.success()
        toastCenter.post("AI Tags saved", kind: .success)
        dismiss()
    }

    /// Strip empty per-context primary sets + empty deselect sets so the
    /// stored selection stays compact. Helps `isEmpty` resolve cleanly
    /// when the user un-picks everything and saves.
    private func sanitize(_ s: ProjectTagSelection) -> ProjectTagSelection {
        var out = s
        out.primariesByContext = out.primariesByContext.filter { !$0.value.isEmpty }
        out.deselectedSecondariesByPrimary = out.deselectedSecondariesByPrimary
            .filter { !$0.value.isEmpty }
        // Drop context IDs whose primary set ended up empty (user
        // unpicked every primary).
        out.contextIDs = out.contextIDs.filter { id in
            (out.primariesByContext[id]?.isEmpty == false)
                || s.primariesByContext[id]?.isEmpty == true
        }
        // Final coherence pass: a context with zero picked primaries is
        // effectively unpicked, even if the user toggled it on then
        // unpicked every primary individually.
        out.contextIDs = out.contextIDs.filter { id in
            !(out.primariesByContext[id]?.isEmpty ?? true)
        }
        return out
    }
}
