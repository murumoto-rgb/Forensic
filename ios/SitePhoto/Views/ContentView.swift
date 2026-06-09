import SwiftUI

struct ContentView: View {
    /// Reports whether the navigation stack is at its root — wired through
    /// to SitePhotoApp so the App-level Baykal logo footer can hide itself
    /// while a project detail or sheet is open.
    @Binding var atRoot: Bool

    @Environment(ProjectStore.self) private var store
    @Environment(AuthService.self) private var auth
    @Environment(BinaryBackfillService.self) private var backfill

    @State private var path = NavigationPath()
    @State private var showingNew = false
    @State private var pendingDelete: Project?
    @State private var pendingPermanentDelete: Project?
    @State private var pendingRename: Project?
    @State private var renameDraft: String = ""
    @State private var showingSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.activeProjects.isEmpty && store.deletedProjects.isEmpty {
                    EmptyProjectsView { showingNew = true }
                } else {
                    List {
                        Section("Active Projects") {
                            ForEach(store.activeProjects) { project in
                                NavigationLink(value: project) {
                                    ProjectRow(project: project)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDelete = project
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        renameDraft = project.name
                                        pendingRename = project
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
                        }

                        if !store.deletedProjects.isEmpty {
                            Section("Deleted Projects") {
                                ForEach(store.deletedProjects) { project in
                                    DeletedProjectRow(project: project)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                pendingPermanentDelete = project
                                            } label: {
                                                Label("Delete Forever", systemImage: "trash.fill")
                                            }
                                        }
                                        .swipeActions(edge: .leading) {
                                            Button {
                                                store.restore(project)
                                            } label: {
                                                Label("Restore", systemImage: "arrow.uturn.backward")
                                            }
                                            .tint(.green)
                                        }
                                }
                            }
                        }

                        Section { StorageStatusFooter(store: store, auth: auth, backfill: backfill) }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: Project.self) { project in
                // Build #5.127.1: the project detail behind a five-tab
                // shell (Photos / Plan / AI / Export / More). PR 1 ships
                // the shell with Photos embedding today's ProjectDetailView;
                // PRs 2-6 carve sections into their proper tabs.
                ProjectWorkspaceView(projectID: project.id)
            }
            .sheet(isPresented: $showingNew) {
                NewProjectView { newProject in
                    showingNew = false
                    path.append(newProject)
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet()
            }
            .alert(
                "Move to Deleted Projects?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { project in
                Button("Delete", role: .destructive) {
                    store.delete(project)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            } message: { project in
                Text("\"\(project.name)\" will be moved to Deleted Projects. You can restore it from there until you delete it permanently.")
            }
            .alert(
                "Delete forever?",
                isPresented: Binding(
                    get: { pendingPermanentDelete != nil },
                    set: { if !$0 { pendingPermanentDelete = nil } }
                ),
                presenting: pendingPermanentDelete
            ) { project in
                Button("Delete Forever", role: .destructive) {
                    store.permanentlyDelete(project)
                    pendingPermanentDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingPermanentDelete = nil
                }
            } message: { project in
                Text("\"\(project.name)\" and all its photos will be permanently removed from iCloud. This cannot be undone.")
            }
            .alert(
                "Rename project",
                isPresented: Binding(
                    get: { pendingRename != nil },
                    set: { if !$0 { pendingRename = nil } }
                )
            ) {
                TextField("Project name", text: $renameDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button("Save") {
                    if let project = pendingRename {
                        store.renameProject(project, to: renameDraft)
                    }
                    pendingRename = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingRename = nil
                }
            } message: {
                Text("Enter a new name for this project.")
            }
            .onChange(of: path.isEmpty) { _, isEmpty in
                withAnimation(.easeInOut(duration: 0.25)) {
                    atRoot = isEmpty
                }
            }
        }
    }
}

private struct DeletedProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(project.photos.count) photo\(project.photos.count == 1 ? "" : "s") · created \(project.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Swipe right to restore, left to delete forever")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(project.photos.count) photo\(project.photos.count == 1 ? "" : "s") · \(project.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let address = project.projectAddress {
                    Text(address)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if project.projectGPS != nil {
                    Text("address pending…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyProjectsView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            EmptyStateView(
                icon: "folder.badge.plus",
                title: "No projects yet",
                message: "Create a project to start documenting a site. Each project tracks its own photos and floor plan."
            )
            Button("New Project", action: onCreate)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 40)
        }
    }
}

private struct StorageStatusFooter: View {
    let store: ProjectStore
    let auth: AuthService
    let backfill: BinaryBackfillService

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(headlineText)
                    .font(.caption.bold())
                Text(subtitleText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // Backfill chip — visible while running AND after
                // completion (Build #5.50.1) so the counts persist
                // when the sweep finishes too quickly to notice.
                // Hidden only when nothing was attempted this
                // session (`totalFiles == 0`).
                if backfill.progress.totalFiles > 0 {
                    Text(backfillChipText)
                        .font(.caption2)
                        .foregroundStyle(backfillChipColor)
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    // Three combined states the footer reflects (Build #5.49.1):
    //  * iCloud + backend — strongest persistence.
    //  * No iCloud, backend signed in — local + Supabase + R2.
    //    Was misleadingly labelled "Local storage only" before this
    //    build; the simulator + any fresh install hit this branch
    //    and the user thought their work wasn't being saved
    //    anywhere off-device.
    //  * No iCloud, not signed in — truly local only.

    private var isOnBackend: Bool { auth.session != nil }

    // Backfill chip — phrased differently while the sweep is in
    // flight vs after it's done, so the user can tell the
    // distinction at a glance.
    private var backfillChipText: String {
        let p = backfill.progress
        if backfill.isRunning {
            let failureTail = p.failedFiles > 0 ? " (\(p.failedFiles) failed)" : ""
            return "Backfilling files: \(p.downloadedFiles)/\(p.totalFiles)\(failureTail)"
        }
        // Finished — show results until the user signs out or the
        // next sweep starts.
        if p.failedFiles == 0 {
            return "Backfill: downloaded \(p.downloadedFiles) of \(p.totalFiles) files."
        }
        return "Backfill: \(p.downloadedFiles) of \(p.totalFiles) downloaded; \(p.failedFiles) couldn't be fetched."
    }
    private var backfillChipColor: Color {
        if backfill.isRunning { return .blue }
        return backfill.progress.failedFiles > 0 ? .orange : .green
    }

    private var iconName: String {
        if store.usingICloud { return "icloud.fill" }
        if isOnBackend { return "externaldrive.fill.badge.icloud" }
        return "iphone"
    }
    private var iconTint: Color {
        if store.usingICloud { return .blue }
        if isOnBackend { return .blue }
        return .orange
    }
    private var headlineText: String {
        if store.usingICloud {
            return isOnBackend ? "Saved to iCloud + backend" : "Saved to iCloud Drive"
        }
        if isOnBackend {
            return "Saved to backend (no iCloud)"
        }
        return "Local storage only"
    }
    private var subtitleText: String {
        if store.usingICloud {
            if isOnBackend {
                return "Projects sync to iCloud Drive AND the Forensic backend (Supabase + R2). Open Files app to browse the local copy."
            }
            return "Projects sync to iCloud Drive → SitePhoto. Open the Files app to browse them."
        }
        if isOnBackend {
            // The simulator default — used to read "Local storage only".
            return "iCloud Drive is unavailable, but your work syncs to the Forensic backend (Supabase + R2). Photos + plans backfill from R2 on launch so a fresh install / restored device fills in."
        }
        return store.iCloudUnavailableReason ?? "Sign in (Settings → Account) to back up to the Forensic team server."
    }
}

#Preview {
    let toast = ToastCenter()
    let auth = AuthService()
    let api = APIClient(auth: auth)
    let store = ProjectStore()
    let backfill = BinaryBackfillService(api: api,
                                          auth: auth,
                                          store: store,
                                          toast: toast)
    return ContentView(atRoot: .constant(true))
        .environment(store)
        .environment(LocationService())
        .environment(auth)
        .environment(backfill)
}
