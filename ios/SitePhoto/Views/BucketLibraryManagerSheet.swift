import SwiftUI

/// Curate the app-wide bucket library: add/rename/delete *Primary
/// Investigation Type* categories and the *Observation Buckets* inside
/// them. All edits persist immediately through `ProjectStore`. Reorder
/// is supported at both levels via the system EditMode.
///
/// Two presentation modes share this view:
///  1. The default browse mode (categories + their entries inline).
///  2. A drill-in detail mode for one category, used when the engineer
///     wants to focus on adding buckets to a single category without
///     scrolling past the others.
struct BucketLibraryManagerSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var addingCategoryName: String = ""
    @State private var showingAddCategoryPrompt: Bool = false

    @State private var renamingCategory: BucketLibraryCategory?
    @State private var renameCategoryDraft: String = ""

    @State private var deletingCategory: BucketLibraryCategory?

    @State private var addingEntryToCategory: BucketLibraryCategory?
    @State private var newEntryName: String = ""
    @State private var newEntryColor: String = Bucket.palette[0]

    @State private var renamingEntry: EntryRef?
    @State private var renameEntryDraft: String = ""

    private var library: [BucketLibraryCategory] { store.bucketLibrary }

    var body: some View {
        NavigationStack {
            Group {
                if library.isEmpty {
                    EmptyStateView(
                        icon: "books.vertical",
                        title: "Library is empty",
                        message: "Add a Primary Investigation Type to start. Each one holds a list of observation buckets you can drop into any project."
                    )
                } else {
                    List {
                        ForEach(library) { category in
                            categorySection(category)
                        }
                        .onMove(perform: moveCategories)
                    }
                }
            }
            .navigationTitle("Bucket Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            addingCategoryName = ""
                            showingAddCategoryPrompt = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .accessibilityLabel("Add Primary Investigation Type")
                        EditButton()
                    }
                }
            }
            .alert("New Primary Investigation Type",
                   isPresented: $showingAddCategoryPrompt) {
                TextField("Name (e.g. Roofing)", text: $addingCategoryName)
                    .textInputAutocapitalization(.words)
                Button("Add") { addCategory() }
                    .disabled(addingCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Categories group observation buckets by investigation type so they're easy to find when you build a project.")
            }
            .alert("Rename category",
                   isPresented: Binding(
                    get: { renamingCategory != nil },
                    set: { if !$0 { renamingCategory = nil } }
                   )) {
                TextField("Name", text: $renameCategoryDraft)
                Button("Save") { commitCategoryRename() }
                Button("Cancel", role: .cancel) { renamingCategory = nil }
            }
            .alert("Delete category?",
                   isPresented: Binding(
                    get: { deletingCategory != nil },
                    set: { if !$0 { deletingCategory = nil } }
                   ),
                   presenting: deletingCategory) { cat in
                Button("Delete", role: .destructive) {
                    deleteCategory(cat)
                    deletingCategory = nil
                }
                Button("Cancel", role: .cancel) { deletingCategory = nil }
            } message: { cat in
                Text("\"\(cat.name)\" and its \(cat.entries.count) observation bucket\(cat.entries.count == 1 ? "" : "s") will be removed from the library. Projects that previously copied buckets from it are not affected.")
            }
            .sheet(item: $addingEntryToCategory) { category in
                AddEntrySheet(
                    category: category,
                    initialName: $newEntryName,
                    initialColor: $newEntryColor,
                    onSave: { name, color in
                        commitNewEntry(in: category, name: name, color: color)
                    }
                )
                .environment(store)
                .presentationDetents([.medium])
            }
            .alert("Rename observation bucket",
                   isPresented: Binding(
                    get: { renamingEntry != nil },
                    set: { if !$0 { renamingEntry = nil } }
                   )) {
                TextField("Name", text: $renameEntryDraft)
                Button("Save") { commitEntryRename() }
                Button("Cancel", role: .cancel) { renamingEntry = nil }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func categorySection(_ category: BucketLibraryCategory) -> some View {
        Section {
            ForEach(category.entries) { entry in
                entryRow(category: category, entry: entry)
            }
            .onMove { source, dest in
                store.reorderLibraryEntries(inCategory: category.id,
                                              from: source, to: dest)
            }
            .onDelete { offsets in
                for offset in offsets {
                    let entry = category.entries[offset]
                    _ = store.deleteLibraryEntry(inCategory: category.id, entry: entry.id)
                }
                Haptics.confirm()
            }
            Button {
                newEntryName = ""
                newEntryColor = Bucket.palette[category.entries.count % Bucket.palette.count]
                addingEntryToCategory = category
            } label: {
                Label("Add Observation Bucket", systemImage: "plus")
                    .font(.callout)
            }
        } header: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Primary Investigation Type")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(category.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Menu {
                    Button {
                        renamingCategory = category
                        renameCategoryDraft = category.name
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deletingCategory = category
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .textCase(nil)
            }
        }
    }

    @ViewBuilder
    private func entryRow(category: BucketLibraryCategory,
                           entry: BucketLibraryCategory.Entry) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(Bucket.palette, id: \.self) { hex in
                    Button {
                        _ = store.recolorLibraryEntry(inCategory: category.id,
                                                       entry: entry.id,
                                                       to: hex)
                        Haptics.tap()
                    } label: {
                        if hex.lowercased() == entry.colorHex.lowercased() {
                            Label(hex, systemImage: "checkmark")
                        } else {
                            Text(hex)
                        }
                    }
                }
            } label: {
                Circle()
                    .fill(Color(bucketHex: entry.colorHex) ?? .accentColor)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                    )
            }
            Text(entry.name)
                .font(.callout)
            Spacer()
            Button {
                renamingEntry = EntryRef(categoryID: category.id, entryID: entry.id)
                renameEntryDraft = entry.name
            } label: {
                Image(systemName: "pencil")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func moveCategories(from source: IndexSet, to destination: Int) {
        store.reorderLibraryCategories(from: source, to: destination)
    }

    private func addCategory() {
        guard let cat = store.addLibraryCategory(name: addingCategoryName) else { return }
        Haptics.success()
        toastCenter.post("Added category \"\(cat.name)\"", kind: .success)
        addingCategoryName = ""
    }

    private func commitCategoryRename() {
        guard let cat = renamingCategory else { return }
        _ = store.renameLibraryCategory(cat.id, to: renameCategoryDraft)
        renamingCategory = nil
        renameCategoryDraft = ""
        Haptics.tap()
    }

    private func deleteCategory(_ cat: BucketLibraryCategory) {
        if store.deleteLibraryCategory(cat.id) {
            Haptics.confirm()
            toastCenter.post("Deleted category \"\(cat.name)\"", kind: .success)
        }
    }

    private func commitNewEntry(in category: BucketLibraryCategory,
                                  name: String,
                                  color: String) {
        if store.addLibraryEntry(toCategory: category.id, name: name, colorHex: color) != nil {
            Haptics.success()
            toastCenter.post("Added bucket to \"\(category.name)\"", kind: .success)
        }
        addingEntryToCategory = nil
    }

    private func commitEntryRename() {
        guard let ref = renamingEntry else { return }
        _ = store.renameLibraryEntry(inCategory: ref.categoryID,
                                      entry: ref.entryID,
                                      to: renameEntryDraft)
        renamingEntry = nil
        renameEntryDraft = ""
        Haptics.tap()
    }
}

private struct EntryRef: Identifiable {
    let categoryID: UUID
    let entryID: UUID
    var id: String { "\(categoryID)-\(entryID)" }
}

/// Sheet for picking a name + colour when adding a new observation
/// bucket to a category. Inline alert wouldn't carry the colour swatch
/// row, so we use a dedicated half-height sheet.
private struct AddEntrySheet: View {
    let category: BucketLibraryCategory
    @Binding var initialName: String
    @Binding var initialColor: String
    var onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Cracks", text: $initialName)
                        .textInputAutocapitalization(.words)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                              count: 6),
                               spacing: 12) {
                        ForEach(Bucket.palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(bucketHex: hex) ?? .gray)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Circle().stroke(
                                        hex.lowercased() == initialColor.lowercased()
                                          ? Color.primary
                                          : Color.primary.opacity(0.18),
                                        lineWidth: hex.lowercased() == initialColor.lowercased() ? 2.5 : 0.5
                                    )
                                )
                                .onTapGesture {
                                    initialColor = hex
                                    Haptics.tap()
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Add to \(category.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        onSave(initialName, initialColor)
                    }
                    .bold()
                    .disabled(initialName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
