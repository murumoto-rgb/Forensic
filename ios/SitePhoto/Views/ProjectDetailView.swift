import SwiftUI

struct ProjectDetailView: View {
    @Environment(ProjectStore.self) private var store
    let projectID: UUID

    private var project: Project? {
        store.project(withID: projectID)
    }

    var body: some View {
        Group {
            if let project {
                List {
                    metadataSection(project)
                    actionsSection(project)
                    photosSection(project)
                    placeholdersSection
                }
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView(
                    "Project not found",
                    systemImage: "questionmark.folder",
                    description: Text("This project may have been deleted.")
                )
            }
        }
    }

    @ViewBuilder
    private func metadataSection(_ project: Project) -> some View {
        Section("Details") {
            LabeledContent("Created", value: project.createdAt.formatted(date: .abbreviated, time: .shortened))

            HStack {
                Text("Status")
                Spacer()
                statusText(project)
            }

            if let gps = project.projectGPS {
                LabeledContent("GPS") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.5f, %.5f", gps.latitude, gps.longitude))
                            .font(.caption.monospaced())
                        if let acc = gps.accuracyFeet {
                            Text(String(format: "± %.1f ft", acc))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let address = project.projectAddress {
                LabeledContent("Address") {
                    Text(address)
                        .multilineTextAlignment(.trailing)
                }
            } else if project.projectGPS != nil {
                LabeledContent("Address", value: "looking up…")
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ project: Project) -> some View {
        Section("Session") {
            Button {
                // TODO: wire to LocationService in next push
            } label: {
                Label(startStopLabel(project), systemImage: startStopIcon(project))
            }
            .disabled(true)
            .foregroundStyle(.secondary)

            Button {
                // TODO: open camera in next push
            } label: {
                Label("Take Photo", systemImage: "camera")
            }
            .disabled(true)
            .foregroundStyle(.secondary)

            Text("Camera, location capture, and PDF export are wired in upcoming pushes. The placeholder above is intentional.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func photosSection(_ project: Project) -> some View {
        Section("Photos · \(project.photos.count)") {
            if project.photos.isEmpty {
                Text("No photos yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(project.photos) { photo in
                    HStack {
                        Text("#\(photo.sequenceNumber)")
                            .font(.headline.monospaced())
                        Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var placeholdersSection: some View {
        Section("Roadmap") {
            roadmapItem(
                done: true,
                title: "Project list, create, delete",
                subtitle: "You're using it now."
            )
            roadmapItem(
                done: false,
                title: "Camera capture (AVFoundation)",
                subtitle: "0.5x / 1x / 2x / 4x / 8x lens picker, true flash control, full-resolution capture."
            )
            roadmapItem(
                done: false,
                title: "Location & address",
                subtitle: "GPS on session start, reverse geocoded address with caching."
            )
            roadmapItem(
                done: false,
                title: "Floor plan + photo bubbles",
                subtitle: "Pan/zoom, calibration, group bubbles, blink-on-select."
            )
            roadmapItem(
                done: false,
                title: "PDF export",
                subtitle: "Map page, plan page with bubbles, contact sheet."
            )
            roadmapItem(
                done: false,
                title: "AI photo analysis",
                subtitle: "Forensic description via Claude Opus 4.7."
            )
        }
    }

    @ViewBuilder
    private func roadmapItem(done: Bool, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .strikethrough(done, color: .secondary)
                    .font(.subheadline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusText(_ project: Project) -> Text {
        if project.isActive { return Text("Recording").foregroundStyle(.red) }
        if project.hasBeenStarted { return Text("Paused").foregroundStyle(.orange) }
        return Text("Not started").foregroundStyle(.secondary)
    }

    private func startStopLabel(_ project: Project) -> String {
        if project.isActive { return "Stop" }
        if project.hasBeenStarted { return "Resume" }
        return "Start"
    }

    private func startStopIcon(_ project: Project) -> String {
        project.isActive ? "stop.fill" : "play.fill"
    }
}

#Preview {
    let store = ProjectStore()
    let p = Project(name: "Demo project")
    let saved = store.save(p)
    return NavigationStack {
        ProjectDetailView(projectID: saved.id)
            .environment(store)
    }
}
