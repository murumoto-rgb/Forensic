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
