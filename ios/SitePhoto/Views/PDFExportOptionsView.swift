import SwiftUI

/// Pre-export options screen for the PDF report. Lets the engineer pick
/// photos-per-page density, toggle bucket grouping + the metadata table,
/// and re-order the variable sections (Plan / Contact sheets / Metadata
/// table). Cover is always page 1 and is rendered as a non-draggable
/// header for clarity.
///
/// State lives in a `@State` mirror so the SwiftUI controls re-render
/// reliably; the mirror writes back to `@AppStorage` (Codable Data) on
/// every change so the picks persist across exports and launches.
struct PDFExportOptionsView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store

    @AppStorage("sitephoto.pdfExportOptions") private var storedData: Data = Data()

    @State private var options: PDFExportOptions = .defaults
    @State private var loaded: Bool = false

    private let perPageChoices: [Int] = Array(1...12)

    private var project: Project? {
        store.project(withID: projectID)
    }

    var body: some View {
        Form {
            Section {
                Picker("Photos per page", selection: $options.perPage) {
                    ForEach(perPageChoices, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Layout")
            } footer: {
                Text("2 photos per page = full-width cells, ideal when each photo needs to read large. 6 is the legacy default.")
            }

            if let project, project.floorPlans.count > 1 {
                floorsSection(project)
            }
            if let project, project.floorPlan != nil {
                planRenderingSection(project)
            }

            Section {
                Toggle(isOn: $options.groupByBucket) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Group photos by bucket")
                        Text("Insert a section divider page before each bucket's contact sheets, in bucket sort order. Photos with no bucket appear last under \"Unbucketed\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $options.includeMetadataTable) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include evidence metadata table")
                        Text("Append a tabular section listing #, time, bucket, lens/zoom, flash, position source, and plan position for every photo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sections")
            }

            Section {
                Toggle("Tags",
                       isOn: $options.annotations.includeTags)
                Toggle("Caption",
                       isOn: $options.annotations.includeCaption)
                Toggle("Summary observation",
                       isOn: $options.annotations.includeObservation)
                Toggle("Measurement readout",
                       isOn: $options.annotations.includeMeasurement)
                Toggle("Reviewer flag",
                       isOn: $options.annotations.includeReviewerFlag)
            } header: {
                Text("Per-photo annotations")
            } footer: {
                Text("Pick which AI annotations render under each contact-sheet photo. Tags appear grouped under their primary (secondaries indented). Caption + observation use the engineer's overrides when present, otherwise the AI draft. The caption area below each photo grows to fit whatever you enable; if it gets cramped, switch to fewer photos per page above.")
            }

            Section {
                // Cover row is locked — present visually so the engineer
                // sees the full page sequence, but not draggable.
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Page 1 · Cover")
                            .font(.body)
                        Text("Always first; can't be moved or removed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                ForEach(options.sectionOrder) { section in
                    sectionRow(section)
                }
                .onMove { source, destination in
                    options.sectionOrder.move(fromOffsets: source,
                                                toOffset: destination)
                }
            } header: {
                HStack {
                    Text("Section order")
                    Spacer()
                    EditButton()
                        .font(.caption)
                        .textCase(nil)
                }
            } footer: {
                Text("Drag the rows to change the order sections appear after the cover. Sections without data (e.g. no floor plan) are skipped silently.")
            }

            Section {
                NavigationLink {
                    PDFExportRunner(projectID: projectID, options: options)
                } label: {
                    Label("Start Export", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .navigationTitle("PDF Report")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadIfNeeded() }
        .onChange(of: options) { _, newValue in
            // Persist on every change so the next export sees the same
            // picks without an explicit save action.
            storedData = newValue.jsonData()
        }
    }

    @ViewBuilder
    private func floorsSection(_ project: Project) -> some View {
        Section {
            ForEach(project.floorPlans) { plan in
                Button {
                    toggleFloor(plan.id, in: project)
                } label: {
                    HStack {
                        Image(systemName: isSelected(plan.id, in: project)
                              ? "checkmark.square.fill"
                              : "square")
                            .foregroundStyle(isSelected(plan.id, in: project)
                                              ? Color.accentColor
                                              : .secondary)
                        Text(plan.label)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text("Floors to include")
                Spacer()
                Button("All") {
                    options.selectedFloorIDs = nil
                }
                .font(.caption)
                .textCase(nil)
            }
        } footer: {
            Text("Tick the floors you want in this PDF. The report renders each selected floor's plan(s) followed by that floor's photos, then a separator page and a final section of photos not located on any plan.")
        }
    }

    /// Returns whether `planID` is currently included in the export.
    /// `selectedFloorIDs == nil` is the "all included" sentinel.
    private func isSelected(_ planID: UUID, in project: Project) -> Bool {
        if let selected = options.selectedFloorIDs {
            return selected.contains(planID)
        }
        return true
    }

    /// Toggle a floor's inclusion. Migrates the sentinel `nil` to an
    /// explicit set when the engineer first deselects a floor; collapses
    /// back to `nil` when the explicit set re-includes every floor.
    private func toggleFloor(_ planID: UUID, in project: Project) {
        let allIDs = Set(project.floorPlans.map(\.id))
        var current = options.selectedFloorIDs ?? allIDs
        if current.contains(planID) {
            current.remove(planID)
        } else {
            current.insert(planID)
        }
        options.selectedFloorIDs = (current == allIDs) ? nil : current
    }

    @ViewBuilder
    private func planRenderingSection(_ project: Project) -> some View {
        Section {
            Picker("Plan pages", selection: $options.planMode) {
                ForEach(PDFExportOptions.PlanRenderMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Plan rendering")
        } footer: {
            Text("Choose what each floor's `.plan` section contains. \"Distress\" pages render the door + crack marks you placed on the plan. \"Merged\" overlays the photo pins and distress marks on a single page.")
        }
    }

    @ViewBuilder
    private func sectionRow(_ section: PDFExportOptions.Section) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: section))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.displayName)
                Text(detail(for: section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func icon(for section: PDFExportOptions.Section) -> String {
        switch section {
        case .plan:           return "map"
        case .contactSheets:  return "rectangle.grid.2x2"
        case .metadataTable:  return "tablecells"
        }
    }

    private func detail(for section: PDFExportOptions.Section) -> String {
        switch section {
        case .plan:           return "Annotated floor plan with photo bubbles. Skipped if no plan is set."
        case .contactSheets:  return options.groupByBucket
            ? "One header page + contact sheets per bucket."
            : "All photos in a single \(options.perPage)-up grid."
        case .metadataTable:  return options.includeMetadataTable
            ? "Tabular metadata for every photo."
            : "Off — toggle above to enable."
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        options = PDFExportOptions.from(jsonData: storedData)
        if let layout = store.project(withID: projectID)?.reportLayout {
            options.perPage = layout.perPage
            options.groupByBucket = layout.groupByBucket
            options.includeMetadataTable = layout.includeMetadataTable
        }
        loaded = true
    }
}
