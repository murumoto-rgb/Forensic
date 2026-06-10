// Split out of ProjectDetailView.swift (Build #6.24.1 — iOS
// decomposition part 2). Members moved verbatim into a same-module
// extension; `private` dropped on the struct's members because Swift
// scopes private to the file and these now cross file boundaries.
// No behavior change.

import SwiftUI

extension ProjectDetailView {

    func floorPlanSection(_ project: Project) -> some View {
        Section("Floor Plans") {
            if project.floorPlans.isEmpty {
                Text("No floor plans set. Photos will be saved without a recorded location until a plan is imported and calibrated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(project.floorPlans) { plan in
                    planRow(project: project, plan: plan)
                }
            }
            if !project.isFrozen {
                Button {
                    showingFloorPlanSetup = true
                } label: {
                    Label(project.floorPlans.isEmpty
                           ? "Set Up Floor Plan"
                           : "Add Floor Plan",
                          systemImage: "plus.circle")
                }
            }
        }
    }

    /// One row per floor plan. Tapping the row makes that plan active
    /// + opens the viewer; the trailing menu surfaces the existing
    /// per-plan editors (Origin, North, Recalibrate, Replace) and
    /// destructive Remove. Editor sheets read `project.floorPlan` (the
    /// active plan accessor), so we set active before opening.
    @ViewBuilder
    func planRow(project: Project, plan: FloorPlan) -> some View {
        let isActive = plan.id == project.floorPlan?.id
        Button {
            _ = store.setActiveFloorPlan(project, planID: plan.id)
            showingPlanViewer = true
        } label: {
            HStack(spacing: 10) {
                planThumbnail(project: project, planID: plan.id)
                    .frame(width: 56, height: 42)
                    .clipped()
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.label)
                        .foregroundStyle(.primary)
                    Text(planRowSubtitle(project: project, planID: plan.id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Text("ACTIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                // Build #6.1.1: a locked project hides the per-plan
                // editor menu — rows stay tappable for viewing only.
                if !project.isFrozen {
                    Menu {
                        Button {
                            renamingPlan = plan
                            renamePlanDraft = plan.label
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        if !isActive {
                            Button {
                                _ = store.setActiveFloorPlan(project, planID: plan.id)
                            } label: {
                                Label("Set as active", systemImage: "checkmark.circle")
                            }
                        }
                        Divider()
                        // Build #6.8.1: the five calibration-class
                        // actions fold into one drill-in submenu —
                        // the row menu had grown to 8 items, and the
                        // "Edit Distance" vs "Re-calibrate" pair was
                        // hard to tell apart in a flat list. Every
                        // action's flow is unchanged; only its spot
                        // in the menu moved.
                        Menu {
                            Button {
                                _ = store.setActiveFloorPlan(project, planID: plan.id)
                                showingPlanOrigin = true
                            } label: {
                                Label("Set Origin", systemImage: "scope")
                            }
                            Button {
                                _ = store.setActiveFloorPlan(project, planID: plan.id)
                                showingPlanNorth = true
                            } label: {
                                Label("Set North", systemImage: "location.north")
                            }
                            Button {
                                editingDistanceFor = plan
                                editDistanceDraft = trimmedFeet(plan.calibrationDistanceFeet)
                            } label: {
                                Label("Edit Calibration Distance", systemImage: "pencil")
                            }
                            Button {
                                _ = store.setActiveFloorPlan(project, planID: plan.id)
                                showingPlanRecalibrate = true
                            } label: {
                                Label("Re-calibrate Scale", systemImage: "ruler")
                            }
                            Divider()
                            Button {
                                _ = store.setActiveFloorPlan(project, planID: plan.id)
                                showingPlanReplace = true
                            } label: {
                                Label("Replace Image", systemImage: "rectangle.2.swap")
                            }
                        } label: {
                            Label("Calibrate & Image", systemImage: "ruler")
                        }
                        Divider()
                        Button(role: .destructive) {
                            planPendingRemoval = plan
                            confirmingPlanRemoval = true
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Plan actions")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Subtitle under the plan label — counts photos placed on this
    /// plan so the engineer can spot at-a-glance which plan is heavily
    /// used vs empty.
    func planRowSubtitle(project: Project, planID: UUID) -> String {
        let count = project.photos.reduce(0) { $0 + ($1.floorPlanID == planID ? 1 : 0) }
        return "\(count) photo\(count == 1 ? "" : "s")"
    }

    /// Format a feet value for prefilling the Edit Distance text field —
    /// strips the ".0" off whole-foot values so the engineer sees
    /// "12" instead of "12.0" when the plan was calibrated to a clean
    /// number.
    func trimmedFeet(_ value: Double) -> String {
        if value == floor(value) {
            return String(Int(value))
        }
        return String(value)
    }

    /// Apply the edited calibration distance. Computes the new
    /// pixels-per-foot from the existing pixel-distance between the
    /// original calibration points (recoverable as
    /// `pixelsPerFoot * calibrationDistanceFeet`) and the engineer's
    /// new distance, then routes through `store.recalibrateScale` which
    /// already preserves `planPixelX/Y` and re-derives `localXFeet/Y`
    /// so photos stay anchored to the same point on the drawing.
    func commitEditDistance(for plan: FloorPlan, project: Project) {
        defer {
            editingDistanceFor = nil
            editDistanceDraft = ""
        }
        guard let newFeet = Double(editDistanceDraft), newFeet > 0 else { return }
        let pixelDistance = plan.pixelsPerFoot * plan.calibrationDistanceFeet
        guard pixelDistance > 0 else { return }
        let newPixelsPerFoot = pixelDistance / newFeet
        store.recalibrateScale(
            project,
            planID: plan.id,
            pixelsPerFoot: newPixelsPerFoot,
            calibrationDistanceFeet: newFeet
        )
    }

    func planThumbnail(project: Project, planID: UUID) -> some View {
        // Build #6.4.1: async cached load. Plans have no dedicated
        // thumb file — the old code synchronously decoded the FULL
        // plan image on the MainActor for a 56×42 row. Downsample via
        // ImageIO so the cache holds a small bitmap instead.
        CachedThumbnail(url: store.floorPlanURL(for: project, planID: planID),
                        placeholderSystemImage: "doc",
                        maxPixelSize: 240)
    }

    @ViewBuilder
}
