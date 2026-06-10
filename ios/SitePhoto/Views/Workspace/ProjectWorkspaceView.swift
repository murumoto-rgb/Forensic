import SwiftUI

/// The project workspace shell (Build #5.127.1 — iOS IA refactor, PR 1/7).
///
/// Replaces `ProjectDetailView` as the navigation destination for a
/// `Project`. Hosts a `TabView(selection:)` with five tabs:
///
///   Photos · Plan · AI · Export · More
///
/// PR 1's shape: the **Photos** tab embeds today's full
/// `ProjectDetailView` so the app keeps every feature it has today, just
/// behind one tab. The remaining four tabs render a "Coming soon"
/// placeholder explaining which PR will land their content.
///
/// PRs 2-6 carve sections out of `ProjectDetailView` and into the proper
/// tabs one at a time. The forwarding shim makes that incremental
/// migration safe — every PR keeps the app running.
struct ProjectWorkspaceView: View {
    let projectID: UUID

    @Environment(ProjectStore.self) private var store
    @State private var workspace: ProjectWorkspaceModel?
    /// Advisory edit-lock presence (Build #6.21.1). Created alongside
    /// the workspace model; nil when the device has no API client
    /// (signed out / previews) — the workspace then simply shows no
    /// lock banner, exactly the pre-#6.21.1 behavior.
    @State private var lockController: ProjectLockController?

    var body: some View {
        Group {
            if let workspace, let project = store.project(withID: projectID) {
                VStack(spacing: 0) {
                    if case let .heldByOther(email, client) = lockController?.status ?? .unknown {
                        lockAdvisoryBanner(email: email, client: client)
                    }
                    workspaceTabs(project: project, workspace: workspace)
                }
            } else if store.project(withID: projectID) == nil {
                EmptyStateView(
                    icon: "questionmark.folder",
                    title: "Project not found",
                    message: "It may have been removed or the link is stale."
                )
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // `ProjectStore` enters via @Environment, which isn't readable in
        // an init. The standard SwiftUI workaround is to allocate the
        // model in the first body pass via `.task`. Keyed by `projectID`
        // so navigating between two different projects rebuilds the model.
        .task(id: projectID) {
            if workspace == nil || workspace?.projectID != projectID {
                workspace = ProjectWorkspaceModel(projectID: projectID)
            }
            if lockController == nil, let api = store.apiClient {
                let controller = ProjectLockController(api: api, projectID: projectID)
                lockController = controller
                controller.start()
            }
        }
        .onDisappear {
            // Release the advisory lock when leaving the workspace so
            // web reviewers regain editability promptly (the 10-min
            // TTL is the backstop if this never runs).
            lockController?.stop()
            lockController = nil
        }
    }

    /// Thin amber strip shown when a *different* account holds a live
    /// edit lock. Advisory only — iOS editing stays enabled (the
    /// server-side 3-way merge protects concurrent edits), and the
    /// copy says so to preempt "will I lose my photos?" worry.
    private func lockAdvisoryBanner(email: String, client: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.clock")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(email) is editing on \(client == "ios" ? "another iPhone" : "web")")
                    .font(.caption.weight(.semibold))
                Text("You can keep working — changes from both sides merge on sync.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    @ViewBuilder
    private func workspaceTabs(
        project: Project,
        workspace: ProjectWorkspaceModel
    ) -> some View {
        TabView(selection: Binding(
            get: { workspace.selectedTab },
            set: { workspace.selectedTab = $0 }
        )) {
            // Build #5.128.1: each tab renders a `.scope`-filtered slice
            // of ProjectDetailView. The view's body conditionally shows
            // only the sections that belong to the active tab. State
            // (filter chips, search text, sheet visibility) survives tab
            // switches via SwiftUI's TabView state preservation —
            // ProjectDetailView keeps its @State on the Photos tab, and
            // each other tab's slice has its own state because each
            // ProjectDetailView instance is independent.
            ProjectDetailView(projectID: projectID, scope: .photos)
                .tabItem {
                    Label(ProjectTab.photos.label,
                          systemImage: ProjectTab.photos.systemImage)
                }
                .tag(ProjectTab.photos)

            ProjectDetailView(projectID: projectID, scope: .plan)
                .tabItem {
                    Label(ProjectTab.plan.label,
                          systemImage: ProjectTab.plan.systemImage)
                }
                .tag(ProjectTab.plan)

            ProjectDetailView(projectID: projectID, scope: .ai)
                .tabItem {
                    Label(ProjectTab.ai.label,
                          systemImage: ProjectTab.ai.systemImage)
                }
                .tag(ProjectTab.ai)

            ProjectDetailView(projectID: projectID, scope: .buckets)
                .tabItem {
                    Label(ProjectTab.buckets.label,
                          systemImage: ProjectTab.buckets.systemImage)
                }
                .tag(ProjectTab.buckets)

            ProjectDetailView(projectID: projectID, scope: .more)
                .tabItem {
                    Label(ProjectTab.more.label,
                          systemImage: ProjectTab.more.systemImage)
                }
                .tag(ProjectTab.more)
        }
    }
}
