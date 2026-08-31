import SwiftUI

struct ProjectSearchView: View {
    var onOpenProject: (UUID) -> Void
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var filter = SearchFilter()
    @State private var fromDate = ""
    @State private var toDate = ""
    @State private var hits: [ProjectSearchHit] = []
    @State private var nextOffset: Int?
    @State private var library = WorkflowLibrary()
    @State private var libraryRevision: String?
    @State private var libraryLoaded = false
    @State private var filterName = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var offline = false

    var body: some View {
        NavigationStack {
            List {
                Section("Search across projects") {
                    TextField("Project, address, caption or tag", text: $filter.query)
                        .submitLabel(.search).onSubmit { Task { await search() } }
                    TextField("From date (YYYY-MM-DD)", text: $fromDate).textInputAutocapitalization(.never)
                    TextField("Through date (YYYY-MM-DD)", text: $toDate).textInputAutocapitalization(.never)
                    Toggle("Favorites only", isOn: $filter.favoritesOnly)
                    Button("Search") { Task { await search() } }.disabled(busy)
                }
                Section("Saved searches") {
                    ForEach(library.savedSearches) { saved in
                        Button(saved.name) {
                            filter = saved.filter
                            fromDate = filter.fromDate ?? ""; toDate = filter.toDate ?? ""
                            Task { await search() }
                        }
                        .swipeActions { Button("Delete", role: .destructive) {
                            var next = library
                            next.savedSearches.removeAll { $0.id == saved.id }
                            Task { await saveLibrary(next) }
                        }.disabled(busy) }
                    }
                    TextField("Name this filter", text: $filterName)
                    Button("Save filter") {
                        var next = library
                        next.savedSearches.append(.init(name: filterName.trimmingCharacters(in: .whitespacesAndNewlines), filter: currentFilter))
                        Task { await saveLibrary(next) }
                    }.disabled(!libraryLoaded || busy || filterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if offline {
                    Section { Text("Offline results from this device. Cloud projects and recent changes may be missing.").font(.caption) }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        Button("Reload saved filters") { Task { await loadLibrary() } }.disabled(busy)
                    }
                }
                Section("Results") {
                    ForEach(hits) { hit in
                        Button { Task { await open(hit.projectId) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.projectName).font(.headline)
                                if let sequence = hit.sequenceNumber { Text("Photo #\(sequence): \(hit.caption ?? "No caption")") }
                                if let address = hit.projectAddress { Text(address).font(.caption) }
                                Text(hit.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            }
                        }
                    }
                    if hits.isEmpty && !busy { Text("No results. Try a broader search.").foregroundStyle(.secondary) }
                    if let nextOffset { Button("Load more") { Task { await search(offset: nextOffset) } }.disabled(busy) }
                    if busy { ProgressView("Searching…") }
                }
            }
            .navigationTitle("Find Evidence")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await loadLibrary() }
        }
    }

    private var currentFilter: SearchFilter {
        var value = filter
        value.fromDate = fromDate.isEmpty ? nil : fromDate
        value.toDate = toDate.isEmpty ? nil : toDate
        return value
    }
    private func search(offset: Int = 0) async {
        guard !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        let query = currentFilter
        for date in [query.fromDate, query.toDate].compactMap({ $0 }) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else {
                errorMessage = "Use valid dates in YYYY-MM-DD format."; return
            }
        }
        if let from = query.fromDate, let to = query.toDate, from > to {
            errorMessage = "The from date must be on or before the through date."; return
        }
        do {
            guard let api = store.apiClient else { throw APIClient.APIError.notAuthenticated }
            let response = try await api.searchProjects(filter: query, offset: offset)
            hits = offset == 0 ? response.hits : hits + response.hits
            nextOffset = response.nextOffset; offline = false
        } catch {
            let all = localResults(query)
            let page = Array(all.dropFirst(offset).prefix(50))
            hits = offset == 0 ? page : hits + page
            nextOffset = offset + page.count < all.count ? offset + page.count : nil
            offline = true
            errorMessage = "Cloud search unavailable: " + error.localizedDescription
        }
    }
    private func localResults(_ filter: SearchFilter) -> [ProjectSearchHit] {
        let q = filter.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return store.activeProjects.flatMap { project -> [ProjectSearchHit] in
            let projectMatch = (project.name + " " + (project.projectAddress ?? "")).lowercased().contains(q)
            var found: [ProjectSearchHit] = []
            if projectMatch && !filter.favoritesOnly && filter.fromDate == nil && filter.toDate == nil {
                found.append(.init(projectId: project.id, projectName: project.name, projectAddress: project.projectAddress,
                    photoId: nil, sequenceNumber: nil, caption: nil, timestamp: project.createdAt))
            }
            for photo in project.photos {
                if filter.favoritesOnly && !photo.isFavorite { continue }
                let date = formatter.string(from: photo.timestamp)
                if let from = filter.fromDate, date < from { continue }
                if let to = filter.toDate, date > to { continue }
                let text = [photo.userCaption ?? "", photo.userObservation ?? "", photo.aiDescription ?? "",
                    photo.tags.map(\.label).joined(separator: " ")].joined(separator: " ").lowercased()
                guard q.isEmpty || projectMatch || text.contains(q) else { continue }
                found.append(.init(projectId: project.id, projectName: project.name, projectAddress: project.projectAddress,
                    photoId: photo.id, sequenceNumber: photo.sequenceNumber, caption: photo.userCaption, timestamp: photo.timestamp))
            }
            return found
        }.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
    }
    private func loadLibrary() async {
        guard let api = store.apiClient else { return }
        do {
            let response = try await api.workflowLibrary()
            library = response.library; libraryRevision = response.revision; libraryLoaded = true
        } catch { errorMessage = "Saved filters unavailable: " + error.localizedDescription }
    }
    private func saveLibrary(_ next: WorkflowLibrary) async {
        guard let api = store.apiClient, libraryLoaded, !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let response = try await api.saveWorkflowLibrary(next, expectedRevision: libraryRevision)
            library = next; libraryRevision = response.revision; filterName = ""
        } catch { errorMessage = "Filter not saved: " + error.localizedDescription + " Reload saved filters before retrying a conflict." }
    }
    private func open(_ id: UUID) async {
        do {
            if store.project(withID: id) == nil, let api = store.apiClient {
                let response = try await api.getProject(id: id)
                guard store.applyServerProject(response.project) else { errorMessage = "Could not save this project locally."; return }
                store.updateProjectAccess(id: id, role: response.role, isOwner: response.isOwner)
            }
            guard store.project(withID: id) != nil else { return }
            onOpenProject(id); dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
