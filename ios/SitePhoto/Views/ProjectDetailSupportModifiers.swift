// Split out of ProjectDetailView.swift (Build #6.23.1 — iOS
// decomposition part 1). File-scope support types moved verbatim;
// the only change is dropping the file-scope `fileprivate`/`private`
// (these are now internal, same module). No behavior change.

import SwiftUI

/// Bundles the four batch-tagging-related view modifiers (3 alerts + 1
/// overlay) into a single `ViewModifier`. Keeps `ProjectDetailView.body`
/// short enough for the SwiftUI type checker to handle without timing out.
/// Bundles five view modifiers (1 confirmationDialog + 3 alerts + 1
/// sheet) into a single `ViewModifier`. Cuts the type-check budget
/// `ProjectDetailView.body` consumes — without this, the body's modifier
/// chain trips Swift's "compiler is unable to type-check this
/// expression in reasonable time" wall.
struct PlanAndDeletionModifiers: ViewModifier {
    let project: Project
    let projectID: UUID
    let selectedCount: Int
    @Binding var planPendingRemoval: FloorPlan?
    @Binding var confirmingPlanRemoval: Bool
    @Binding var renamingPlan: FloorPlan?
    @Binding var renamePlanDraft: String
    @Binding var pendingPhotoDelete: Photo?
    @Binding var confirmingBatchDelete: Bool
    @Binding var pendingPlanAssignment: Set<UUID>
    let onRemovePlan: (FloorPlan) -> Void
    let onRenamePlanCommit: () -> Void
    let onDeletePhoto: (Photo) -> Void
    let onDeleteSelectedPhotos: () -> Void
    /// Fires after the assignment sheet dismisses successfully. The
    /// caller uses this to exit multi-select mode when the assignment
    /// came from the "Move to Level" path; the import-time path has
    /// nothing to do here.
    let onAssignmentCompleted: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                removePlanTitle,
                isPresented: $confirmingPlanRemoval,
                titleVisibility: .visible,
                presenting: planPendingRemoval
            ) { plan in
                Button("Remove", role: .destructive) {
                    onRemovePlan(plan)
                    planPendingRemoval = nil
                }
                Button("Cancel", role: .cancel) {
                    planPendingRemoval = nil
                }
            } message: { plan in
                Text(removePlanMessage(for: plan))
            }
            .alert(
                "Rename plan",
                isPresented: renamingPlanIsPresented
            ) {
                TextField("Name", text: $renamePlanDraft)
                    .textInputAutocapitalization(.words)
                Button("Save") {
                    onRenamePlanCommit()
                    renamingPlan = nil
                    renamePlanDraft = ""
                }
                Button("Cancel", role: .cancel) {
                    renamingPlan = nil
                    renamePlanDraft = ""
                }
            }
            .alert(
                "Delete photo?",
                isPresented: pendingPhotoDeleteIsPresented,
                presenting: pendingPhotoDelete
            ) { photo in
                Button("Delete", role: .destructive) {
                    onDeletePhoto(photo)
                    pendingPhotoDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingPhotoDelete = nil
                }
            } message: { photo in
                Text("Photo #\(photo.sequenceNumber) will be deleted and the remaining photos renumbered. This cannot be undone.")
            }
            .alert(
                batchDeleteTitle,
                isPresented: $confirmingBatchDelete
            ) {
                Button("Delete", role: .destructive) {
                    onDeleteSelectedPhotos()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The selected photos will be deleted and the remaining photos will be renumbered. This cannot be undone.")
            }
            .sheet(isPresented: planAssignmentIsPresented) {
                FloorPlanAssignmentSheet(
                    projectID: projectID,
                    photoIDs: pendingPlanAssignment,
                    onCompleted: {
                        pendingPlanAssignment = []
                        onAssignmentCompleted()
                    }
                )
            }
    }

    // MARK: - Computed helpers (extracted so the modifier chain above
    // stays simple enough for the SwiftUI type checker).

    private var renamingPlanIsPresented: Binding<Bool> {
        Binding(
            get: { renamingPlan != nil },
            set: { if !$0 { renamingPlan = nil } }
        )
    }

    private var pendingPhotoDeleteIsPresented: Binding<Bool> {
        Binding(
            get: { pendingPhotoDelete != nil },
            set: { if !$0 { pendingPhotoDelete = nil } }
        )
    }

    private var planAssignmentIsPresented: Binding<Bool> {
        Binding(
            get: { !pendingPlanAssignment.isEmpty },
            set: { if !$0 { pendingPlanAssignment = [] } }
        )
    }

    private var removePlanTitle: String {
        if let plan = planPendingRemoval {
            return "Remove \"\(plan.label)\"?"
        }
        return "Remove plan?"
    }

    private var batchDeleteTitle: String {
        let n = selectedCount
        let suffix = n == 1 ? "" : "s"
        return "Delete \(n) photo\(suffix)?"
    }

    /// Plan-deletion alert body. Counts photos placed on this plan so
    /// the engineer knows what's about to detach.
    private func removePlanMessage(for plan: FloorPlan) -> String {
        let count = project.photos.reduce(0) {
            $0 + ($1.floorPlanID == plan.id ? 1 : 0)
        }
        if count == 0 {
            return "The plan image will be deleted from this project."
        }
        let suffix = count == 1 ? "" : "s"
        return "The plan image will be deleted. \(count) photo\(suffix) placed on this plan will be detached but their saved real-world coordinates are preserved — adding a new plan with calibration + origin re-derives their positions automatically."
    }
}


/// Applies `.searchable` only when `show` is true. Used by the workspace
/// shell to keep the search bar on the Photos tab and hide it from the
/// Plan / AI / Export / More tabs (where it has nothing to search).
///
/// Implemented as a ViewModifier because SwiftUI's built-in modifier
/// chain has no inline conditional and chaining `if show { .searchable }`
/// inside a builder breaks the resulting type.
struct SearchableIfPhotos: ViewModifier {
    let show: Bool
    @Binding var searchText: String

    func body(content: Content) -> some View {
        if show {
            content.searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search photos by tag, caption, or #"
            )
        } else {
            content
        }
    }
}
