import Foundation
import Observation

@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []

    private let fileManager = FileManager.default

    var rootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appending(path: "Projects", directoryHint: .isDirectory)
    }

    init() {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        load()
    }

    func projectURL(_ project: Project) -> URL {
        rootURL.appending(path: project.id.uuidString, directoryHint: .isDirectory)
    }

    func photosFolder(for project: Project) -> URL {
        projectURL(project).appending(path: "photos", directoryHint: .isDirectory)
    }

    func manifestURL(for project: Project) -> URL {
        projectURL(project).appending(path: "manifest.json")
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    func load() {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            projects = []
            return
        }
        var loaded: [Project] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let manifest = dir.appending(path: "manifest.json")
            guard let data = try? Data(contentsOf: manifest) else { continue }
            do {
                let project = try decoder().decode(Project.self, from: data)
                loaded.append(project)
            } catch {
                #if DEBUG
                print("Failed to decode project at \(manifest.path): \(error)")
                #endif
            }
        }
        projects = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ project: Project) -> Project {
        let dir = projectURL(project)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: photosFolder(for: project), withIntermediateDirectories: true)
        do {
            let data = try encoder().encode(project)
            try data.write(to: manifestURL(for: project), options: .atomic)
        } catch {
            #if DEBUG
            print("Failed to save project: \(error)")
            #endif
        }
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        } else {
            projects.insert(project, at: 0)
        }
        return project
    }

    func delete(_ project: Project) {
        let dir = projectURL(project)
        try? fileManager.removeItem(at: dir)
        projects.removeAll { $0.id == project.id }
    }

    func project(withID id: UUID) -> Project? {
        projects.first { $0.id == id }
    }
}
