import XCTest
import UIKit
@testable import SitePhoto

@MainActor
final class FolderExportTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Folder Export (UUID().uuidString) with spaces")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func imageData(_ color: UIColor) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { color.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 12, height: 12)) }
        return image.jpegData(compressionQuality: 0.9)!
    }

    private func fixture() throws -> (ProjectStore, Project, Data) {
        let store = ProjectStore(storageRoot: try root())
        var project = Project(name: "Case with spaces")
        var photo = Photo(sequenceNumber: 1, imageFilename: "original photo.jpg")
        photo.markupOverlayFilename = "overlay image.png"
        photo.markupDrawingFilename = "strokes drawing.data"
        project.photos = [photo]
        project.buckets = [Bucket(name: "Known", sortOrder: 0)]
        project.photos[0].bucketID = UUID()
        let plan = FloorPlan(label: "Plan A", imageFilename: "plan image.jpg", pixelsPerFoot: 1, calibrationDistanceFeet: 1, anchorPixelX: 0, anchorPixelY: 0, anchorLocalXFeet: 0, anchorLocalYFeet: 0, northDeg: 0)
        project.floorPlans = [plan]
        _ = store.save(project)
        try FileManager.default.createDirectory(at: store.photosFolder(for: project), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.markupsFolder(for: project), withIntermediateDirectories: true)
        let bytes = imageData(.systemBlue)
        return (store, project, bytes)
    }

    func testMissingRequiredMarkupFailsAndLeavesNoPublishedDirectory() async throws {
        let (store, project, bytes) = try fixture()
        try bytes.write(to: store.photosFolder(for: project).appending(path: project.photos[0].imageFilename))
        try bytes.write(to: store.planImageURL(for: project.floorPlans[0], in: project))
        try bytes.write(to: store.markupsFolder(for: project).appending(path: project.photos[0].markupOverlayFilename!))
        let service = FolderExportService(project: project, store: store)
        await XCTAssertThrowsErrorAsync(try await service.export(progress: { _ in })) { error in
            XCTAssertTrue(error.localizedDescription.contains("markup drawing"))
        }
        let exports = try FileManager.default.contentsOfDirectory(at: store.rootURL.appending(path: "Exports"), includingPropertiesForKeys: nil)
        XCTAssertTrue(exports.isEmpty)
    }

    func testCompleteExportPreservesOriginalAndIncludesRawMarkupPlanAndUnknownBucket() async throws {
        let (store, project, bytes) = try fixture()
        let photo = project.photos[0]
        try bytes.write(to: store.photosFolder(for: project).appending(path: photo.imageFilename))
        try bytes.write(to: store.markupsFolder(for: project).appending(path: photo.markupOverlayFilename!))
        try Data([1, 2, 3]).write(to: store.markupsFolder(for: project).appending(path: photo.markupDrawingFilename!))
        try bytes.write(to: store.planImageURL(for: project.floorPlans[0], in: project))
        let url = try await FolderExportService(project: project, store: store).export(progress: { _ in })
        XCTAssertTrue(url.path.contains("Case with spaces"))
        XCTAssertEqual(try Data(contentsOf: url.appending(path: "99 Unbucketed/original photo.jpg")), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appending(path: "01 Markups/overlay image.png").path))
        XCTAssertEqual(try Data(contentsOf: url.appending(path: "01 Markups/strokes drawing.data")), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appending(path: "00 Floor Plans/plan image.jpg").path))
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          _ handler: (Error) -> Void) async {
    do { _ = try await expression(); XCTFail("Expected export to fail") }
    catch { handler(error) }
}
