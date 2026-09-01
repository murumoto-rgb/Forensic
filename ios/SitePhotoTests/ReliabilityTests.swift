import XCTest
import PDFKit
import UIKit
@testable import SitePhoto

@MainActor
final class ReliabilityTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        // Spaces reproduce real iCloud paths ("Mobile Documents"). FileManager
        // requires URL.path, not the percent-encoded URL.path() string.
        let url = FileManager.default.temporaryDirectory.appending(path: "Forensic audit \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitFor(
        _ description: String, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return false
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    func testFailedSaveKeepsLatestEditAndBlocksPullUntilRetrySucceeds() throws {
        var fail = false
        let store = ProjectStore(storageRoot: try temporaryRoot()) { bytes, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try bytes.write(to: url, options: .atomic)
        }
        var project = Project(name: "Before")
        store.save(project)
        let savedAt = store.lastSavedAt
        var acknowledgements = 0
        store.onAfterSave = { _ in acknowledgements += 1 }
        fail = true
        project.name = "Latest local edit"
        store.save(project)
        XCTAssertEqual(store.lastSavedAt, savedAt)
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertTrue(store.hasUnsavedChanges(projectID: project.id))
        var remote = project
        remote.name = "Remote must not erase unsaved work"
        XCTAssertFalse(store.applyServerProject(remote))
        XCTAssertEqual(store.project(withID: project.id)?.name, "Latest local edit")
        fail = false
        XCTAssertTrue(store.retryPendingSave(projectID: project.id))
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertNil(store.saveFailures[project.id])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(Project.self, from: Data(contentsOf: store.manifestURL(for: project)))
        XCTAssertEqual(restored.name, "Latest local edit")
    }

    func testPhotoSyncPrecheckMarksOnlyObjectStoreVerifiedAssets() {
        let projectID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let photoID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let assets = [
            ProjectHealthAsset(entityId: photoID.uuidString, kind: .photo,
                filename: "verified.jpg", objectKey: "\(projectID)/\(photoID)/photo/verified.jpg", state: "available"),
            ProjectHealthAsset(entityId: photoID.uuidString, kind: .thumb,
                filename: "registered.jpg", objectKey: "\(projectID)/\(photoID)/thumb/registered.jpg", state: "registered"),
            ProjectHealthAsset(entityId: photoID.uuidString, kind: .markupPng,
                filename: "missing.png", objectKey: "\(projectID)/\(photoID)/markup_png/missing.png", state: "missing"),
            ProjectHealthAsset(entityId: photoID.uuidString, kind: .markupDrawing,
                filename: "unverified", objectKey: "\(projectID)/\(photoID)/markup_drawing/unverified", state: "unverified")
        ]
        let health = ProjectHealthResponse(projectId: projectID.uuidString,
            revision: "r1", checkedAt: Date(), verification: "object-store",
            assets: assets, expected: assets.count, registered: 4, available: 1, missing: 1)

        let keys = PhotoSyncer.verifiedUploadedKeys(projectId: projectID, health: health)

        XCTAssertEqual(keys, [PhotoSyncer.objectKey(projectId: projectID, photoId: photoID, kind: .photo) + "/verified.jpg"])
    }

    func testPlanReplacementFailurePreservesOldImageAndCalibration() throws {
        var fail = false
        let store = ProjectStore(storageRoot: try temporaryRoot()) { bytes, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try bytes.write(to: url, options: .atomic)
        }
        var project = Project(name: "Plan rollback")
        let plan = FloorPlan(label: "First", imageFilename: "old.jpg", pixelsPerFoot: 10,
            calibrationDistanceFeet: 5, anchorPixelX: 0, anchorPixelY: 0,
            anchorLocalXFeet: 0, anchorLocalYFeet: 0, northDeg: 0)
        project.floorPlans = [plan]
        store.save(project)
        let oldURL = store.planImageURL(for: plan, in: project)
        let oldBytes = Data([1, 2, 3])
        try oldBytes.write(to: oldURL)
        fail = true
        XCTAssertThrowsError(try store.replaceFloorPlan(in: project, planID: plan.id,
            imageData: Data([4, 5]), pixelsPerFoot: 20, calibrationDistanceFeet: 10,
            anchorPixelX: 1, anchorPixelY: 1, northDeg: 90))
        XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes)
        XCTAssertEqual(store.project(withID: project.id)?.floorPlans, [plan])
        let names = try FileManager.default.contentsOfDirectory(atPath: store.projectURL(project).path)
        XCTAssertFalse(names.contains(where: { $0.hasPrefix("plan-") }))
    }

    func testFrozenProjectRejectsBundledUnlockEditButAllowsPureUnlock() throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        var project = Project(name: "Final")
        project.isFrozen = true
        store.save(project)
        var incoming = project
        incoming.name = "Changed while locked"
        incoming.isFrozen = false
        XCTAssertEqual(store.save(incoming), project)
        incoming.name = project.name
        XCTAssertFalse(store.save(incoming).isFrozen)
    }

    func testLockCapabilityFailsClosedAfterAccessIsKnownButAllowsLocalCreation() async throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        let project = store.save(Project(name: "Access gated"))

        // A brand-new local project can be finalized before its first server
        // response; the creator is the only actor who can reach this state.
        XCTAssertTrue(store.canManageLock(project))

        // A response with omitted legacy access fields still establishes that
        // this is an existing server project. Unknown access must not expose
        // a local freeze mutation while the caller's role is unresolved.
        store.updateProjectAccess(id: project.id, role: nil, isOwner: nil)
        XCTAssertFalse(store.canManageLock(project))
        XCTAssertEqual(store.setFrozen(project, frozen: true), project)
        XCTAssertFalse(store.project(withID: project.id)!.isFrozen)

        store.updateProjectAccess(id: project.id, role: "editor", isOwner: false)
        XCTAssertFalse(store.canManageLock(project))
        store.updateProjectAccess(id: project.id, role: "admin", isOwner: false)
        XCTAssertTrue(store.canManageLock(project))
        store.updateProjectAccess(id: project.id, role: nil, isOwner: nil)
        XCTAssertFalse(store.canManageLock(project))
        store.updateProjectAccess(id: project.id, role: "editor", isOwner: true)
        XCTAssertTrue(store.canManageLock(project))
        store.resetProjectAccess()
        XCTAssertFalse(store.canManageLock(project))
        XCTAssertEqual(store.setFrozen(project, frozen: true), project)

        // A later authoritative response must revoke stale owner/admin
        // capability when both optional fields are absent.
        store.updateProjectAccess(id: project.id, role: nil, isOwner: nil)
        XCTAssertFalse(store.canManageLock(project))
        store.updateProjectAccess(id: project.id, role: "viewer", isOwner: false)
        XCTAssertFalse(store.canManageLock(project))

        // A project loaded from disk is an existing project, even before its
        // first access response on this device; it must not inherit the
        // locally-created exception.
        let reloadedStore = ProjectStore(storageRoot: store.rootURL)
        await reloadedStore.loadInitial()
        let reloaded = try XCTUnwrap(reloadedStore.project(withID: project.id))
        XCTAssertFalse(reloadedStore.canManageLock(reloaded))
    }

    func testCachedRevisionRefreshesAccessWithoutReplacingLocalProject() async throws {
        let store = ProjectStore(storageRoot: try temporaryRoot()) { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let local = Project(name: "Local edit")
        store.save(local)
        store.resetProjectAccess()
        XCTAssertTrue(store.hasUnsavedChanges(projectID: local.id))
        XCTAssertFalse(store.canManageLock(local))
        let userID = UUID()
        let transport = TestManifestTransport()
        transport.listResponse = ProjectListResponse(projects: [
            ProjectListItem(id: local.id, name: local.name, manifestSchemaVersion: 4,
                revision: "same", createdAt: local.createdAt, updatedAt: local.createdAt)
        ])
        var remote = local; remote.name = "Remote replacement"
        transport.getResponse = GetManifestResponse(project: remote, revision: "same", role: "editor", isOwner: true)
        let revisionKey = "sitephoto.serverRevision.\(local.id.uuidString.lowercased())"
        UserDefaults.standard.set("same", forKey: revisionKey)
        defer { UserDefaults.standard.removeObject(forKey: revisionKey) }

        let syncer = ManifestSyncer(transport: transport, currentUserID: { userID }, toast: ToastCenter())
        syncer.store = store
        await syncer.pullAllFromServer()

        XCTAssertEqual(transport.getCalls, 1)
        XCTAssertEqual(store.project(withID: local.id)?.name, "Local edit")
        XCTAssertTrue(store.canManageLock(local))
        XCTAssertTrue(store.isProjectAccessKnown(id: local.id))
    }

    func testLateAccessResponseAfterResetCannotRestoreOldGrant() async throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        let local = store.save(Project(name: "Late response"))
        var currentUser: UUID? = UUID()
        let transport = TestManifestTransport()
        transport.listResponse = ProjectListResponse(projects: [
            ProjectListItem(id: local.id, name: local.name, manifestSchemaVersion: 4,
                revision: "same", createdAt: local.createdAt, updatedAt: local.createdAt)
        ])
        var remote = local; remote.name = "Old account project"
        transport.getResponse = GetManifestResponse(project: remote, revision: "same", role: "admin", isOwner: true)
        transport.delayGet = true
        let revisionKey = "sitephoto.serverRevision.\(local.id.uuidString.lowercased())"
        UserDefaults.standard.set("same", forKey: revisionKey)
        let syncer = ManifestSyncer(transport: transport, currentUserID: { currentUser }, toast: ToastCenter())
        syncer.store = store
        defer { syncer.resetRevisions(); transport.cancelPending() }
        let finished = expectation(description: "old access request completed")
        Task { await syncer.pullAllFromServer(); finished.fulfill() }
        guard await waitFor("access GET", { transport.getStarted }) else { return }
        let restoreContext = try XCTUnwrap(syncer.captureContext())
        currentUser = nil
        syncer.resetRevisions()
        store.resetProjectAccess()
        transport.resumeGet()
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertFalse(store.isProjectAccessKnown(id: local.id))
        XCTAssertFalse(store.canManageLock(local))
        XCTAssertEqual(store.project(withID: local.id)?.name, "Late response")
        XCTAssertNil(UserDefaults.standard.string(forKey: revisionKey))
        XCTAssertThrowsError(try syncer.adoptRestored(
            GetManifestResponse(project: remote, revision: "same", role: "admin", isOwner: true),
            context: restoreContext
        ))
    }

    func testOldQueueFailureCannotClearReplacementAccountWork() async throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        let project = store.save(Project(name: "Queued project"))
        var currentUser: UUID? = UUID()
        let transport = TestManifestTransport(); transport.delayPut = true
        let syncer = ManifestSyncer(transport: transport, currentUserID: { currentUser }, toast: ToastCenter())
        syncer.store = store
        defer { syncer.resetRevisions(); transport.cancelPending() }
        let oldFinished = expectation(description: "old failed drain completed")
        Task { await syncer.syncNow(projectID: project.id); oldFinished.fulfill() }
        guard await waitFor("old PUT", { transport.putCalls == 1 }) else { return }
        currentUser = UUID(); syncer.resetRevisions(); store.resetProjectAccess()
        var replacement = project; replacement.name = "Replacement account snapshot"
        store.save(replacement)
        let newFinished = expectation(description: "replacement drain completed")
        Task { await syncer.syncNow(projectID: project.id); newFinished.fulfill() }
        guard await waitFor("replacement PUT", { transport.putCalls == 2 }) else { return }

        transport.resumePut(call: 1, with: .failure(NSError(domain: "test", code: 1)))
        await fulfillment(of: [oldFinished], timeout: 3)
        XCTAssertTrue(syncer.inFlight.contains(project.id), "old failure must not clear the replacement drain")
        XCTAssertFalse(syncer.pendingRetry.contains(project.id), "old failure must not enqueue a retry for the new account")
        transport.resumePut(call: 2, with: .success(PutManifestResponse(revision: "replacement", project: nil)))
        await fulfillment(of: [newFinished], timeout: 3)
        XCTAssertFalse(syncer.inFlight.contains(project.id))
        XCTAssertEqual(store.project(withID: project.id)?.name, replacement.name)
    }

    func testOldQueueSuccessCannotAdoptOverReplacementAccountSave() async throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        let project = store.save(Project(name: "Original"))
        var currentUser: UUID? = UUID()
        let transport = TestManifestTransport(); transport.delayPut = true
        let syncer = ManifestSyncer(transport: transport, currentUserID: { currentUser }, toast: ToastCenter())
        syncer.store = store
        defer { syncer.resetRevisions(); transport.cancelPending() }
        let revisionKey = "sitephoto.serverRevision.\(project.id.uuidString.lowercased())"
        let oldFinished = expectation(description: "old successful drain completed")
        Task { await syncer.syncNow(projectID: project.id); oldFinished.fulfill() }
        guard await waitFor("old PUT", { transport.putCalls == 1 }) else { return }
        currentUser = UUID(); syncer.resetRevisions(); store.resetProjectAccess()
        var replacement = project; replacement.name = "Saved by replacement account"
        store.save(replacement)
        let newFinished = expectation(description: "replacement drain completed")
        Task { await syncer.syncNow(projectID: project.id); newFinished.fulfill() }
        guard await waitFor("replacement PUT", { transport.putCalls == 2 }) else { return }
        var staleResponse = project; staleResponse.name = "Must never be adopted"
        transport.resumePut(call: 1, with: .success(PutManifestResponse(revision: "old", project: staleResponse)))
        await fulfillment(of: [oldFinished], timeout: 3)
        XCTAssertEqual(store.project(withID: project.id)?.name, replacement.name)
        XCTAssertNil(UserDefaults.standard.string(forKey: revisionKey))
        XCTAssertTrue(syncer.inFlight.contains(project.id))
        transport.resumePut(call: 2, with: .success(PutManifestResponse(revision: "new", project: nil)))
        await fulfillment(of: [newFinished], timeout: 3)
        XCTAssertFalse(syncer.inFlight.contains(project.id))
        XCTAssertEqual(UserDefaults.standard.string(forKey: revisionKey), "new")
    }

    func testResetBeforeDelayedDrainStartsCannotConsumeReplacementSnapshot() async throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        let project = store.save(Project(name: "A"))
        var currentUser: UUID? = UUID()
        let transport = TestManifestTransport(); transport.delayPut = true
        let syncer = ManifestSyncer(transport: transport, currentUserID: { currentUser }, toast: ToastCenter())
        syncer.store = store
        defer { syncer.resetRevisions(); transport.cancelPending() }
        // No suspension before both enqueue operations: the first drain can
        // start only after its account context has already been invalidated.
        syncer.sync(project)
        currentUser = UUID(); syncer.resetRevisions(); store.resetProjectAccess()
        var replacement = project; replacement.name = "B"
        store.save(replacement); syncer.sync(replacement)
        guard await waitFor("replacement PUT", { transport.putCalls == 1 }) else { return }
        XCTAssertEqual(transport.putProjects[1]?.name, "B")
        XCTAssertTrue(syncer.inFlight.contains(project.id))
        transport.resumePut(call: 1, with: .success(PutManifestResponse(revision: "B", project: nil)))
        guard await waitFor("replacement completion", { !syncer.inFlight.contains(project.id) }) else { return }
        XCTAssertEqual(transport.putCalls, 1)
        XCTAssertEqual(store.project(withID: project.id)?.name, "B")
    }

    func testResetResumesPushAllWaiterWithoutStartingNextOldProject() async throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        store.save(Project(name: "First")); store.save(Project(name: "Second"))
        let first = try XCTUnwrap(store.activeProjects.first)
        var currentUser: UUID? = UUID()
        let transport = TestManifestTransport(); transport.delayPut = true
        let syncer = ManifestSyncer(transport: transport, currentUserID: { currentUser }, toast: ToastCenter())
        syncer.store = store
        defer { syncer.resetRevisions(); transport.cancelPending() }
        let oldFinished = expectation(description: "original drain completed")
        Task { await syncer.syncNow(projectID: first.id); oldFinished.fulfill() }
        guard await waitFor("first PUT", { transport.putCalls == 1 }) else { return }
        let sweepFinished = expectation(description: "invalidated sweep completed")
        Task { await syncer.pushAllToServer(); sweepFinished.fulfill() }
        guard await waitFor("sweep's actual queued waiter", {
            syncer.pendingWaiterCount(projectID: first.id) == 1
        }) else { return }
        currentUser = UUID(); syncer.resetRevisions(); store.resetProjectAccess()
        await fulfillment(of: [sweepFinished], timeout: 3)
        XCTAssertEqual(transport.putCalls, 1, "old sweep must not start the second project")
        transport.resumePut(call: 1, with: .success(PutManifestResponse(revision: "old", project: nil)))
        await fulfillment(of: [oldFinished], timeout: 3)
        XCTAssertTrue(syncer.inFlight.isEmpty)
        XCTAssertEqual(transport.putCalls, 1)
    }

    func testMissingEvidenceFailsPDFInsteadOfProducingPartialSuccess() async throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        var project = Project(name: "Missing evidence")
        project.photos = [Photo(sequenceNumber: 1, imageFilename: "missing.jpg")]
        store.save(project)
        do {
            _ = try await PDFExportService(project: project, store: store).buildPDF { _ in }
            XCTFail("A missing photo must block a final PDF")
        } catch let error as PDFExportService.IncompleteExportError {
            XCTAssertEqual(error.missingItems, ["photo #1"])
        }
    }

    func testSessionResumeRetainsPreviousVisitAndDoesNotDuplicateAnOpenVisit() throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        let project = store.save(Project(name: "Visits"))
        let first = store.startSession(project)
        XCTAssertEqual(store.startSession(first).inspectionSessions.count, 1)
        let stopped = store.stopSession(first)
        let resumed = store.startSession(stopped)
        XCTAssertEqual(resumed.inspectionSessions.count, 2)
        XCTAssertNotNil(resumed.inspectionSessions[0].endedAt)
        XCTAssertNil(resumed.inspectionSessions[1].endedAt)
    }

    func testSpreadsheetTextNeutralizesLeadingFormulasWithoutChangingPlainText() {
        for text in ["=1+1", "  +cmd", "-2+3", "@SUM(A1)", "\ttext"] {
            XCTAssertEqual(SpreadsheetText.neutralize(text), "'" + text)
        }
        XCTAssertEqual(SpreadsheetText.neutralize("Crack width 1/8\""), "Crack width 1/8\"")
    }

    func testPlanCacheUsesPublicationGenerationAndDoesNotRebuildDuringGestures() throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        var project = store.save(Project(name: "Plan cache"))
        let cache = PlanLayoutCache()
        var builds = 0
        func lookup(_ fit: Double = 1) {
            _ = cache.value(projectID: project.id, revision: store.projectGeneration, fit: fit, bubbleScale: 1) {
                builds += 1
                return PlanLayoutSnapshot(primaries: [], arrowLengths: [:])
            }
        }
        for _ in 0..<120 { lookup() }
        XCTAssertEqual(builds, 1)
        project.name = "A real project mutation"
        store.save(project)
        lookup()
        XCTAssertEqual(builds, 2)
        lookup(2)
        XCTAssertEqual(builds, 3)
    }

    func testSpatialClustersKeepTransitiveGroupsAndExactDistanceBoundary() {
        let points = [CGPoint(x: -9, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 9, y: 0), CGPoint(x: 19, y: 0)]
        let clusters = ClusterFanning.detectPrimaryClusters(markers: Array(points.indices), position: { points[$0] }, isPrimary: { _ in true }, collisionRadius: 10)
        XCTAssertEqual(clusters.map(\.members), [[0, 1, 2], [3]])
        XCTAssertEqual(clusters[0].centroid, .zero)
        let origin = UUID(), obstacle = UUID()
        let arrows = ClusterFanning.arrowLengthAdjustments(markers: [origin, obstacle], id: { $0 }, position: { $0 == origin ? .zero : CGPoint(x: 25, y: 0) }, isPrimary: { _ in true }, bearingDegrees: { _ in 90 }, primaryRadius: 5, secondaryRadius: 3, defaultArrowLength: 40)
        XCTAssertEqual(arrows[origin], 16)
        XCTAssertEqual(arrows[obstacle], 40)
    }

    func testEverySharedReportDensityFitsItsEntirePage() {
        for count in 1...12 {
            let (columns, rows) = PDFExportService.gridDimensions(perPage: count)
            XCTAssertGreaterThanOrEqual(columns * rows, count)
            XCTAssertEqual(columns, count <= 3 ? 1 : count <= 6 ? 2 : 3)
        }
        XCTAssertEqual(PDFExportOptions.from(jsonData: Data("{\"perPage\":0}".utf8)).perPage, 1)
    }

    private func squareImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
    }

    func testBrandingReplacementFailurePreservesThePreviousLogo() throws {
        let root = try temporaryRoot()
        let store = ProjectStore(storageRoot: root)
        let first = store.setBrandingLogo(squareImage(.red))
        let firstURL = try XCTUnwrap(store.brandingLogoURL)
        let firstBytes = try Data(contentsOf: firstURL)
        XCTAssertTrue(first.logoNeedsUpload == true)
        let metadata = root.appending(path: "branding.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        let failed = store.setBrandingLogo(squareImage(.blue))
        XCTAssertEqual(failed, first)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
    }

    func testBrandingAcknowledgementCannotReplaceANewerLogoPick() throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        let first = store.setBrandingLogo(squareImage(.red))
        let second = store.setBrandingLogo(squareImage(.blue))
        try store.acknowledgeBrandingLogo(filename: try XCTUnwrap(first.logoFilename), objectKey: "old-upload")
        XCTAssertEqual(store.reportBranding, second)
        try store.acknowledgeBrandingLogo(filename: try XCTUnwrap(second.logoFilename), objectKey: "new-upload")
        XCTAssertEqual(store.reportBranding.logoCachedStoragePath, "new-upload")
        XCTAssertFalse(store.reportBranding.logoNeedsUpload == true)
    }

    func testPDFUsesVerifiedMarkupEvenIfItsLocalFileDisappearsAfterPreflight() async throws {
        let store = ProjectStore(storageRoot: try temporaryRoot())
        var project = Project(name: "Markup snapshot")
        var photo = Photo(sequenceNumber: 1, imageFilename: "original.jpg")
        photo.markupOverlayFilename = "overlay.png"
        project.photos = [photo]
        store.save(project)
        try XCTUnwrap(squareImage(.blue).jpegData(compressionQuality: 1)).write(to: store.imageURL(for: photo, in: project))
        let overlay = store.markupsFolder(for: project).appending(path: "overlay.png")
        try FileManager.default.createDirectory(at: overlay.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(squareImage(.red).pngData()).write(to: overlay)
        XCTAssertEqual(store.markupOverlayURL(for: photo, in: project), overlay)
        let service = PDFExportService(project: project, store: store)
        let firstURL = try await service.buildPDF { _ in }
        let first = try XCTUnwrap(PDFDocument(url: firstURL))
        let expected = try XCTUnwrap(first.page(at: first.pageCount - 1)?.thumbnail(of: CGSize(width: 500, height: 700), for: .mediaBox).pngData())
        var removed = false
        let secondURL = try await service.buildPDF { message in
            if message == "Generating map…" {
                try? FileManager.default.removeItem(at: overlay)
                removed = true
            }
        }
        XCTAssertTrue(removed)
        let second = try XCTUnwrap(PDFDocument(url: secondURL))
        XCTAssertEqual(second.pageCount, first.pageCount)
        let actual = second.page(at: second.pageCount - 1)?.thumbnail(of: CGSize(width: 500, height: 700), for: .mediaBox).pngData()
        XCTAssertEqual(actual, expected)
    }
}

@MainActor
private final class TestManifestTransport: ManifestSyncTransport {
    var listResponse = ProjectListResponse(projects: [])
    var getResponse: GetManifestResponse?
    var getCalls = 0
    var getStarted = false
    var delayGet = false
    private var getContinuation: CheckedContinuation<GetManifestResponse, Error>?
    var putCalls = 0
    var delayPut = false
    private var putContinuations: [Int: CheckedContinuation<PutManifestResponse, Error>] = [:]
    var putProjects: [Int: Project] = [:]

    func listProjects() async throws -> ProjectListResponse { listResponse }

    func getProject(id: UUID) async throws -> GetManifestResponse {
        getCalls += 1
        getStarted = true
        if let getResponse, !delayGet { return getResponse }
        return try await withCheckedThrowingContinuation { continuation in
            getContinuation = continuation
        }
    }

    func resumeGet() {
        guard let continuation = getContinuation, let getResponse else { return }
        getContinuation = nil
        continuation.resume(returning: getResponse)
    }

    func putProject(id: UUID, project: Project, expectedRevision: String?, baseManifest: Project?) async throws -> PutManifestResponse {
        putCalls += 1
        putProjects[putCalls] = project
        if delayPut {
            return try await withCheckedThrowingContinuation { continuation in
                putContinuations[putCalls] = continuation
            }
        }
        return PutManifestResponse(revision: "next", project: nil)
    }

    func resumePut(call: Int, with result: Result<PutManifestResponse, Error>) {
        guard let continuation = putContinuations.removeValue(forKey: call) else {
            XCTFail("No pending PUT for call \(call)")
            return
        }
        continuation.resume(with: result)
    }

    func cancelPending() {
        let get = getContinuation
        getContinuation = nil
        get?.resume(throwing: CancellationError())
        let puts = putContinuations
        putContinuations.removeAll()
        for continuation in puts.values { continuation.resume(throwing: CancellationError()) }
    }
}
