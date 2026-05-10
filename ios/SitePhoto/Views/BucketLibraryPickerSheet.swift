import SwiftUI

/// Pick individual observation buckets from the app-wide library and
/// add them to a project as fresh, project-owned buckets. The library
/// is two-level — a *Primary Investigation Type* (Foundation, Roofing,
/// …) holds a list of *Observation Buckets* (Cracks, Stains, …). The
/// engineer can multi-select across categories and tap **Add** once to
/// drop everything into the project at the bottom of the existing
/// bucket list.
///
/// Buckets that already exist in the project (matched by case-folded
/// name) are dimmed and rendered with a "Already added" annotation so
/// the engineer doesn't accidentally double-add a bucket they kept from
/// a previous step.
struct BucketLibraryPickerSheet: View {
    let projectID: UUID
    let onApplied: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<UUID> = []
    @State private var expanded: Set<UUID> = []
    @State private var showingManager: Bool = false

    private var project: Project? { store.project(withID: projectID) }
    private var categories: [BucketLibraryCategory] { store.bucketLibrary }

    /// Names already in the project, lower-cased + trimmed. Used to flag
    /// library entries the user shouldn't be encouraged to re-add.
    private var existingBucketNames: Set<String> {
        guard let project else { return [] }
        return Set(project.buckets.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
    }

    var body: some View {
        NavigationStack {
            Group {
                if categories.isEmpty {
                    EmptyStateView(
                        icon: "books.vertical",
                        title: "Library is empty",
                        message: "Open Manage Library to add a Primary Investigation Type and its observation buckets, then come back here to pick them.")
                } else {
                    List {
                        ForEach(categories) { category in
                            categorySection(category)
                        }
                    }
                }
            }
            .navigationTitle("Add from Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addSelected()
                    } label: {
                        Text(selected.isEmpty
                              ? "Add"
                              : "Add (\(selected.count))")
                            .bold()
                    }
                    .disabled(selected.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showingManager = true
                    } label: {
                        Label("Manage Library", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showingManager) {
                BucketLibraryManagerSheet()
                    .environment(store)
                    .environment(toastCenter)
            }
        }
    }

    @ViewBuilder
    private func categorySection(_ category: BucketLibraryCategory) -> some View {
        let isExpanded = expanded.contains(category.id) || expanded.isEmpty
        Section {
            if isExpanded {
                ForEach(category.entries) { entry in
                    entryRow(category: category, entry: entry)
                }
            }
        } header: {
            Button {
                toggleExpansion(category.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Primary Investigation Type")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(category.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                    Spacer()
                    Text("\(category.entries.count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            if isExpanded && !category.entries.isEmpty {
                Text("Observation Buckets")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func entryRow(category: BucketLibraryCategory,
                           entry: BucketLibraryCategory.Entry) -> some View {
        let alreadyInProject = existingBucketNames.contains(
            entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        let isPicked = selected.contains(entry.id)
        Button {
            guard !alreadyInProject else { return }
            toggleSelection(entry.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
                    .font(.title3)
                Circle()
                    .fill(Color(bucketHex: entry.colorHex) ?? .accentColor)
                    .frame(width: 14, height: 14)
                Text(entry.name)
                    .font(.callout)
                    .foregroundStyle(alreadyInProject ? Color.secondary : .primary)
                Spacer()
                if alreadyInProject {
                    Text("In project")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .opacity(alreadyInProject ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(alreadyInProject)
    }

    private func toggleSelection(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
            Haptics.tap()
        }
    }

    private func toggleExpansion(_ id: UUID) {
        if expanded.isEmpty {
            // First tap on any header switches us out of "all expanded"
            // (the default) into manually-tracked mode.
            expanded = Set(categories.map(\.id))
        }
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func addSelected() {
        guard let project else { return }
        let count = selected.count
        guard count > 0 else { return }
        _ = store.addLibraryEntries(withIDs: selected, to: project)
        Haptics.success()
        toastCenter.post(
            "Added \(count) bucket\(count == 1 ? "" : "s") from library",
            kind: .success
        )
        onApplied()
        dismiss()
    }
}
