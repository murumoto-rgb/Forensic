import Foundation

struct LocalProjectAsset: Identifiable, Sendable {
    let entityID: UUID
    let kind: FileKind
    let url: URL
    var id: String { entityID.uuidString + "/" + kind.rawValue }
    var filename: String { url.lastPathComponent }
}

extension ProjectStore {
    /// Includes retained trash and markup originals, not just visible photos.
    func localAssets(in project: Project) -> [LocalProjectAsset] {
        var result: [LocalProjectAsset] = []
        for photo in project.photos + project.trashedPhotos {
            result.append(.init(entityID: photo.id, kind: .photo, url: imageURL(for: photo, in: project)))
            if let url = thumbnailURL(for: photo, in: project) {
                result.append(.init(entityID: photo.id, kind: .thumb, url: url))
            }
            if let name = photo.markupOverlayFilename {
                result.append(.init(entityID: photo.id, kind: .markupPng, url: markupsFolder(for: project).appending(path: name)))
            }
            if let name = photo.markupDrawingFilename {
                result.append(.init(entityID: photo.id, kind: .markupDrawing, url: markupsFolder(for: project).appending(path: name)))
            }
        }
        for plan in project.floorPlans {
            result.append(.init(entityID: plan.id, kind: .plan, url: planImageURL(for: plan, in: project)))
        }
        return result
    }
}
