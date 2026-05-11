import SwiftUI

/// One-shot picker shown after a Photos-library or Files import to ask
/// the engineer which floor plan the just-imported batch belongs to.
/// Mirrors the simple list-and-tap pattern of `BucketPickerSheet`.
///
/// Imported photos already exist on disk by the time this sheet
/// appears — the picker just stamps `floorPlanID` onto each via
/// `ProjectStore.assignFloorPlan(_:photoIDs:planID:)`. Picking
/// "Unassigned" leaves the photos with no plan reference (matches the
/// pre-multi-plan behaviour when the project had no plan at all).
///
/// The picker also updates the project's `activeFloorPlanID` so the
/// next capture / next import defaults to the same plan — the
/// "sticky" behaviour the engineer asked for.
struct FloorPlanAssignmentSheet: View {
    let projectID: UUID
    let photoIDs: Set<UUID>
    /// Caller-provided closure invoked after the engineer picks (or
    /// skips). The sheet dismisses itself after this fires.
    let onCompleted: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    private var project: Project? { store.project(withID: projectID) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(headerText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let project, !project.floorPlans.isEmpty {
                    Section("Floor plans") {
                        ForEach(project.floorPlans) { plan in
                            planRow(project: project, plan: plan)
                        }
                    }
                    Section {
                        unassignedRow
                    }
                } else {
                    Section {
                        unassignedRow
                    }
                }
            }
            .navigationTitle("Assign to floor plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Skip") {
                        finish(planID: nil, updateActive: false)
                    }
                }
            }
        }
    }

    private var headerText: String {
        let n = photoIDs.count
        return "\(n) photo\(n == 1 ? "" : "s") imported. Pick the floor plan they belong to — you can re-place each photo on the plan later from the Locate sheet."
    }

    @ViewBuilder
    private func planRow(project: Project, plan: FloorPlan) -> some View {
        let isActive = plan.id == project.floorPlan?.id
        Button {
            finish(planID: plan.id, updateActive: true)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.image")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.label)
                        .foregroundStyle(.primary)
                    if isActive {
                        Text("Active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var unassignedRow: some View {
        Button {
            finish(planID: nil, updateActive: false)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.app.dashed")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unassigned")
                        .foregroundStyle(.primary)
                    Text("Photos won't appear on any floor plan until assigned later.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func finish(planID: UUID?, updateActive: Bool) {
        guard let project else {
            dismiss()
            onCompleted()
            return
        }
        var p = store.assignFloorPlan(project, photoIDs: photoIDs, planID: planID)
        if updateActive, let planID {
            p = store.setActiveFloorPlan(p, planID: planID)
        }
        _ = p
        Haptics.success()
        if let planID,
           let plan = project.floorPlan(id: planID) {
            toastCenter.post("Assigned \(photoIDs.count) photo\(photoIDs.count == 1 ? "" : "s") to \(plan.label)",
                              kind: .success)
        }
        dismiss()
        onCompleted()
    }
}
