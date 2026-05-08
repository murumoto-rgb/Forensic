import SwiftUI

struct ContentView: View {
    @Environment(ProjectStore.self) private var store

    @State private var path = NavigationPath()
    @State private var showingNew = false
    @State private var pendingDelete: Project?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.projects.isEmpty {
                    EmptyProjectsView { showingNew = true }
                } else {
                    List {
                        Section {
                            ForEach(store.projects) { project in
                                NavigationLink(value: project) {
                                    ProjectRow(project: project)
                                }
                            }
                            .onDelete { indexSet in
                                // First-tap-to-confirm via the system swipe-to-delete affordance.
                                for i in indexSet {
                                    pendingDelete = store.projects[i]
                                }
                            }
                        } footer: {
                            StorageStatusFooter(store: store)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: Project.self) { project in
                ProjectDetailView(projectID: project.id)
            }
            .sheet(isPresented: $showingNew) {
                NewProjectView { newProject in
                    showingNew = false
                    path.append(newProject)
                }
            }
            .alert(
                "Delete project?",
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
                Text("\"\(project.name)\" and all its photos will be deleted from this device. This cannot be undone.")
            }
        }
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.headline)
                        .lineLimit(2)
                    if project.isActive {
                        StatusBadge(text: "REC", style: .recording)
                    } else if project.hasBeenStarted {
                        StatusBadge(text: "PAUSED", style: .paused)
                    }
                }
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

private struct StatusBadge: View {
    enum Style { case recording, paused }
    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.caption2.bold().monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch style {
        case .recording: return .red
        case .paused: return Color.orange.opacity(0.2)
        }
    }

    private var foreground: Color {
        switch style {
        case .recording: return .white
        case .paused: return .orange
        }
    }
}

private struct EmptyProjectsView: View {
    let onCreate: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Create a project to start documenting a site. Each project tracks its own photos and floor plan.")
        } actions: {
            Button("New Project", action: onCreate)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct StorageStatusFooter: View {
    let store: ProjectStore

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: store.usingICloud ? "icloud.fill" : "iphone")
                .foregroundStyle(store.usingICloud ? .blue : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.usingICloud ? "Saved to iCloud Drive" : "Local storage only")
                    .font(.caption.bold())
                if store.usingICloud {
                    Text("Projects sync to iCloud Drive → SitePhoto. Open the Files app to browse them.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let reason = store.iCloudUnavailableReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}

#Preview {
    ContentView()
        .environment(ProjectStore())
        .environment(LocationService())
}
