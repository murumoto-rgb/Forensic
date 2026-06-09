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

    var body: some View {
        Group {
            if let workspace, let project = store.project(withID: projectID) {
                workspaceTabs(project: project, workspace: workspace)
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
        }
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
            // Photos tab — embeds today's full ProjectDetailView. Every
            // existing per-project workflow remains accessible here while
            // PRs 2-6 incrementally carve sections into their own tabs.
            ProjectDetailView(projectID: projectID)
                .tabItem {
                    Label(ProjectTab.photos.label,
                          systemImage: ProjectTab.photos.systemImage)
                }
                .tag(ProjectTab.photos)

            ComingSoonTab(
                tab: .plan,
                explainer: "Floor plan list + embedded plan viewer move here in PR 4. For now use the Photos tab."
            )
            .tabItem {
                Label(ProjectTab.plan.label,
                      systemImage: ProjectTab.plan.systemImage)
            }
            .tag(ProjectTab.plan)

            ComingSoonTab(
                tab: .ai,
                explainer: "Consolidated AI configuration (Prompt / Vocabulary / Notes / Run) moves here in PR 3. For now use the AI Tagging section on the Photos tab."
            )
            .tabItem {
                Label(ProjectTab.ai.label,
                      systemImage: ProjectTab.ai.systemImage)
            }
            .tag(ProjectTab.ai)

            ComingSoonTab(
                tab: .export,
                explainer: "Export chooser (PDF / Folder / CSV) moves here in PR 5. For now use the Export section on the Photos tab."
            )
            .tabItem {
                Label(ProjectTab.export.label,
                      systemImage: ProjectTab.export.systemImage)
            }
            .tag(ProjectTab.export)

            ComingSoonTab(
                tab: .more,
                explainer: "Project info, buckets, members, danger zone move here in PR 6. For now use the Photos tab."
            )
            .tabItem {
                Label(ProjectTab.more.label,
                      systemImage: ProjectTab.more.systemImage)
            }
            .tag(ProjectTab.more)
        }
    }
}

/// Placeholder body for the four tabs whose content lands in PR 2-6.
/// Keeps the shell shippable on PR 1 without rewriting any content.
private struct ComingSoonTab: View {
    let tab: ProjectTab
    let explainer: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("\(tab.label) tab")
                .font(.title2.weight(.semibold))
            Text(explainer)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
