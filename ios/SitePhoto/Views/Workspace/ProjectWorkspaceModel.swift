import Foundation
import Observation

/// Owns state that crosses the project workspace tabs (Build #5.127.1 —
/// iOS IA refactor, PR 1/7).
///
/// In PR 1 the model only owns `selectedTab` — that's enough to make a
/// `TabView(selection:)` work and to support cross-tab navigation from
/// FABs later. Subsequent PRs lift more state off `ProjectDetailView`
/// into here as each tab carves out its content:
///   * PR 2 (Photos): searchText, all filter fields, selectionMode,
///     selectedPhotoIDs, scrollToPhotoID.
///   * PR 3 (AI): batchTagInFlight (cross-tab signal so Photos can show
///     "AI tagging in progress").
///   * PR 4 (Plan): scrollToPhotoID is also written by the Plan tab when
///     the user taps "open in list" on a plan bubble.
///   * PR 5 (Export): none — Export tab is self-contained.
///   * PR 6 (More): none — danger zone confirms are local.
///
/// The model is held by `ProjectWorkspaceView` via `@State`. It's only
/// allocated once per `projectID`; tab switches don't reset it. State
/// preservation across tab switches is the entire point.
@Observable
@MainActor
final class ProjectWorkspaceModel {
    let projectID: UUID
    var selectedTab: ProjectTab = .photos

    init(projectID: UUID) {
        self.projectID = projectID
    }
}
