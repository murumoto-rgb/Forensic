import SwiftUI

struct ProjectHealthView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(ManifestSyncer.self) private var syncer
    @Environment(PhotoSyncer.self) private var photoSyncer
    @Environment(BinaryBackfillService.self) private var backfill
    @Environment(\.dismiss) private var dismiss
    @State private var health: ProjectHealthResponse?
    @State private var versions: [ProjectVersionSummary] = []
    @State private var missingLocal: [LocalProjectAsset] = []
    @State private var localTotal = 0
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var versionPreview: ProjectVersionResponse?
    @State private var previewLocal: Project?
    @State private var previewRevision: String?
    @State private var previewContext: ManifestSyncer.SyncContext?
    @State private var confirmingRestore = false
    private var project: Project? { store.project(withID: projectID) }

    var body: some View {
        NavigationStack {
            Form {
                if let project {
                    Section("Save and sync") {
                        if let failure = store.saveFailures[projectID] {
                            Label("Not saved on this device", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Text(failure).font(.caption)
                            Text("Keep the app open until Retry succeeds. These edits have not been acknowledged as saved.")
                                .font(.caption)
                        } else {
                            Label("Saved locally", systemImage: "internaldrive")
                        }
                        Text(syncer.inFlight.contains(projectID) ? "Syncing…" :
                            syncer.hasPendingChanges(projectID: projectID) ? "Changes waiting for sync" : "No pending manifest changes")
                        Button("Retry save, sync, and missing files") { Task { await recover() } }
                            .disabled(busy || store.projectRoles[projectID] == "viewer")
                        if project.isFrozen { Text("Finalized project: downloads are allowed; uploads and edits require unlocking.").font(.caption) }
                    }
                    Section("Files on this device") {
                        Text("\(localTotal - missingLocal.count) of \(localTotal) expected files present")
                        ForEach(missingLocal.prefix(50)) { asset in
                            Label(asset.filename, systemImage: "exclamationmark.triangle").font(.caption)
                        }
                        if missingLocal.count > 50 { Text("And \(missingLocal.count - 50) more missing files").font(.caption) }
                    }
                    cloudSection
                    Section("Version history") {
                        Text("Manifests and protected assets are retained from this update onward. Older or incomplete snapshots can be reviewed but cannot be restored.")
                            .font(.caption)
                        ForEach(versions) { version in
                            Button { Task { await preview(version) } } label: {
                                VStack(alignment: .leading) {
                                    Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    Text("\(version.photoCount) photos · \(version.planCount) plans · \(version.restorable ? "Protected snapshot" : "Assets incomplete")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(busy)
                        }
                        if versions.isEmpty { Text("No retained versions yet.").foregroundStyle(.secondary) }
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).accessibilityLabel("Recovery error: " + errorMessage) }
                }
                if busy { ProgressView("Checking…") }
            }
            .navigationTitle("Project Health")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await refresh() }
            .sheet(item: $versionPreview) { preview in versionSheet(preview) }
        }
    }

    @ViewBuilder private var cloudSection: some View {
        Section("Cloud assets") {
            if let health {
                Text(health.verification == "object-store"
                    ? "\(health.available) of \(health.expected) files verified in storage"
                    : "\(health.registered) of \(health.expected) files registered")
                Text(health.verification == "registry"
                    ? "Registration is a database record, not proof that the file is currently readable."
                    : "Checks file presence and size; does not certify photo content or cryptographic integrity.")
                    .font(.caption)
                ForEach(health.assets.filter { $0.state == "missing" || $0.state == "unverified" }.prefix(50)) { asset in
                    Text("\(asset.filename) — \(asset.state)").font(.caption)
                }
                Text("Checked \(health.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            }
            Button("Verify cloud files") { Task { await refresh(verify: true) } }.disabled(busy)
        }
    }

    private func versionSheet(_ preview: ProjectVersionResponse) -> some View {
        NavigationStack {
            List {
                Section("Restore preview") {
                    Text(preview.project.name).font(.headline)
                    Text("Photos: \(project?.photos.count ?? 0) → \(preview.project.photos.count)")
                    Text("Plans: \(project?.floorPlans.count ?? 0) → \(preview.project.floorPlans.count)")
                    Text("Checklist: \(project?.inspectionChecklist.count ?? 0) → \(preview.project.inspectionChecklist.count)")
                    Text("Address: \(preview.project.projectAddress ?? "None")")
                    Text("AI notes: \(preview.project.aiInstructions ?? "None")")
                }
                Section("Changed photo captions and placements") {
                    ForEach(preview.project.photos.filter { previous in
                        project?.photos.first(where: { $0.id == previous.id }) != previous
                    }.prefix(30)) { photo in
                        Text("#\(photo.sequenceNumber): \(photo.userCaption ?? "No caption")")
                    }
                }
                Section {
                    if !preview.version.restorable { Text("Restoration is blocked: \(preview.version.missingAssetCount) asset references are incomplete or unprotected.") }
                    Button("Restore this version", role: .destructive) { confirmingRestore = true }
                        .disabled(!preview.version.restorable || busy || project.map(store.isReadOnly) != false)
                    Text("This replaces the current project with the reviewed snapshot. The current version remains in history. A concurrent save will stop the restore.").font(.caption)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Version Preview")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { versionPreview = nil } } }
            .confirmationDialog("Restore this project version?", isPresented: $confirmingRestore, titleVisibility: .visible) {
                Button("Restore reviewed version", role: .destructive) { Task { await restore(preview) } }
            }
        }
    }

    private func scanLocal() async {
        guard let project else { return }
        let assets = store.localAssets(in: project)
        let missing = await Task.detached(priority: .utility) {
            assets.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        }.value
        localTotal = assets.count
        missingLocal = missing
    }
    private func refresh(verify: Bool = false) async {
        guard !busy else { return }
        guard let context = syncer.captureContext() else {
            errorMessage = "Sign in to check cloud storage."; return
        }
        busy = true; errorMessage = nil
        defer { busy = false }
        await scanLocal()
        guard syncer.isCurrent(context) else { return }
        guard let api = store.apiClient else { errorMessage = "Sign in to check cloud storage."; return }
        do {
            let fetchedHealth = try await api.projectHealth(id: projectID, verify: verify)
            guard syncer.isCurrent(context) else { return }
            health = fetchedHealth
            let fetchedVersions = try await api.projectVersions(id: projectID).versions
            guard syncer.isCurrent(context) else { return }
            versions = fetchedVersions
            let response = try await api.getProject(id: projectID)
            guard syncer.isCurrent(context) else { return }
            store.updateProjectAccess(id: projectID, role: response.role, isOwner: response.isOwner)
        } catch {
            if syncer.isCurrent(context) { errorMessage = error.localizedDescription }
        }
    }
    private func recover() async {
        guard !busy else { return }
        guard let context = syncer.captureContext() else {
            errorMessage = "Sign in again before retrying recovery."; return
        }
        busy = true; errorMessage = nil
        defer { busy = false }
        guard store.retryPendingSave(projectID: projectID) else { return }
        await syncer.syncNow(projectID: projectID)
        guard syncer.isCurrent(context) else { return }
        if let project {
            await backfill.backfillProject(project)
            guard syncer.isCurrent(context) else { return }
            if let latest = self.project { await photoSyncer.syncProject(latest) }
            guard syncer.isCurrent(context) else { return }
        }
        busy = false
        await refresh(verify: true)
    }
    private func preview(_ version: ProjectVersionSummary) async {
        guard let api = store.apiClient, !busy,
              let context = syncer.captureContext() else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            previewLocal = project
            previewContext = context
            let current = try await api.getProject(id: projectID)
            guard syncer.isCurrent(context) else { return }
            previewRevision = current.revision
            let response = try await api.projectVersion(id: projectID, versionID: version.id)
            guard syncer.isCurrent(context) else { return }
            versionPreview = response
        } catch {
            if syncer.isCurrent(context) { errorMessage = error.localizedDescription }
        }
    }
    private func restore(_ preview: ProjectVersionResponse) async {
        guard let api = store.apiClient, let revision = previewRevision, !busy else { return }
        guard let context = previewContext, syncer.isCurrent(context) else {
            errorMessage = "Sign in again before restoring a project version."; return
        }
        guard !syncer.hasPendingChanges(projectID: projectID), project == previewLocal else {
            errorMessage = "Save and sync pending edits, then open a fresh restore preview."; return
        }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let response = try await api.restoreVersion(id: projectID, versionID: preview.id, expectedRevision: revision)
            try syncer.adoptRestored(response, context: context)
            await backfill.backfillProject(response.project)
            guard syncer.isCurrent(context) else { return }
            versionPreview = nil
        } catch {
            if syncer.isCurrent(context) { errorMessage = error.localizedDescription }
        }
        busy = false
        if versionPreview == nil { await refresh(verify: true) }
    }
}
