import SwiftUI

struct ProjectDetailView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(LocationService.self) private var location
    let projectID: UUID

    @State private var sessionWorking = false
    @State private var addressLookupRunning = false
    @State private var sessionError: String?
    @State private var showingCamera = false
    @State private var captureError: String?

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
                .fullScreenCover(isPresented: $showingCamera) {
                    CameraView(
                        onCapture: { captured in
                            handleCapture(captured)
                            showingCamera = false
                        },
                        onCancel: { showingCamera = false }
                    )
                }
            } else {
                ContentUnavailableView(
                    "Project not found",
                    systemImage: "questionmark.folder",
                    description: Text("This project may have been deleted.")
                )
            }
        }
    }

    private func handleCapture(_ captured: CapturedPhoto) {
        guard let project = store.project(withID: projectID) else { return }
        do {
            try store.addPhoto(to: project, captured: captured)
            captureError = nil
        } catch {
            captureError = "Could not save photo: \(error.localizedDescription)"
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
                LabeledContent("Address", value: addressLookupRunning ? "looking up…" : "—")
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ project: Project) -> some View {
        Section("Session") {
            Button {
                Task { await toggleStartStop() }
            } label: {
                Label(startStopLabel(project), systemImage: startStopIcon(project))
            }
            .disabled(sessionWorking)
            .foregroundStyle(project.isActive ? .red : .accentColor)

            Button {
                showingCamera = true
            } label: {
                Label("Take Photo", systemImage: "camera")
            }
            .disabled(!project.isActive)
            .foregroundStyle(project.isActive ? .accentColor : .secondary)

            if !project.isActive && project.hasBeenStarted {
                Text("Resume the session to take photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !project.hasBeenStarted {
                Text("Start the session, then tap Take Photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let err = sessionError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let err = captureError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func toggleStartStop() async {
        guard var current = store.project(withID: projectID) else { return }
        sessionWorking = true
        sessionError = nil
        defer { sessionWorking = false }

        if current.isActive {
            store.stopSession(current)
            return
        }

        let isFirstStart = current.startedAt == nil
        current = store.startSession(current)

        guard isFirstStart, current.projectGPS == nil else { return }

        let auth = await location.requestPermission()
        guard auth == .authorizedAlways || auth == .authorizedWhenInUse else {
            sessionError = "Location permission denied. Open Settings → SitePhoto → Location to allow."
            return
        }

        do {
            let loc = try await location.currentLocation()
            let gps = ProjectGPS(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                altitude: loc.altitude.isFinite ? loc.altitude : nil,
                accuracyFeet: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy * 3.28084 : nil,
                timestamp: Date()
            )
            current = store.updateGPS(current, gps)

            addressLookupRunning = true
            if let address = await location.reverseGeocode(loc) {
                _ = store.updateAddress(current, address)
            }
            addressLookupRunning = false
        } catch LocationError.denied {
            sessionError = "Location permission denied."
        } catch {
            sessionError = "Could not get GPS: \(error.localizedDescription)"
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
                    PhotoRow(photo: photo, project: project, store: store)
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
                done: true,
                title: "Location & address",
                subtitle: "GPS on session start, CLGeocoder reverse-geocode for the address."
            )
            roadmapItem(
                done: true,
                title: "Camera capture (AVFoundation)",
                subtitle: "Lens picker (0.5x/1x/2x/4x/8x), Auto/On/Off flash, full-resolution save."
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

private struct PhotoRow: View {
    let photo: Photo
    let project: Project
    let store: ProjectStore

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 64, height: 48)
                .clipped()
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(photo.sequenceNumber)")
                        .font(.headline.monospaced())
                    if photo.positionSource == .none {
                        Text("NO LOC")
                            .font(.caption2.bold().monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(photo.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(metaLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = store.thumbnailURL(for: photo, in: project),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let lens = photo.lensName { parts.append(lens.uppercased()) }
        parts.append(zoomLabel(photo.cameraZoom))
        parts.append("flash \(photo.flashMode.rawValue)")
        return parts.joined(separator: " · ")
    }

    private func zoomLabel(_ z: Double) -> String {
        if z == floor(z) { return "\(Int(z))x" }
        return String(format: "%.1fx", z)
    }
}

#Preview {
    let store = ProjectStore()
    let location = LocationService()
    let p = Project(name: "Demo project")
    let saved = store.save(p)
    return NavigationStack {
        ProjectDetailView(projectID: saved.id)
            .environment(store)
            .environment(location)
    }
}
