import Foundation

struct InspectionChecklistItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var label: String
    var isComplete: Bool = false
}
struct InspectionSession: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var startedAt: Date
    var endedAt: Date?
}
struct InspectionReportLayout: Codable, Hashable {
    var perPage: Int = 6
    var groupByBucket: Bool = false
    var includeMetadataTable: Bool = false
}
struct SearchFilter: Codable, Equatable {
    var query: String = ""
    var fromDate: String?
    var toDate: String?
    var favoritesOnly: Bool = false
}
struct SavedSearch: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var filter: SearchFilter
}
struct InspectionPreset: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var projectNamePrefix: String = ""
    var projectAddress: String?
    var aiInstructions: String?
    var tagSelection: ProjectTagSelection?
    var aiExtraVocabulary: ProjectExtraVocabulary?
    var buckets: [Bucket] = []
    var checklist: [String] = []
    var reportLayout: InspectionReportLayout = .init()

    func preview(on project: Project) -> Project {
        guard !project.isFrozen else { return project }
        var result = project
        if result.projectAddress?.isEmpty != false { result.projectAddress = projectAddress }
        result.aiInstructions = aiInstructions
        result.tagSelection = tagSelection
        result.aiExtraVocabulary = aiExtraVocabulary
        for (index, bucket) in buckets.enumerated() {
            result.buckets.append(Bucket(name: bucket.name, colorHex: bucket.colorHex,
                sortOrder: project.buckets.count + index, libraryCategoryID: bucket.libraryCategoryID))
        }
        result.inspectionChecklist += checklist.map { InspectionChecklistItem(label: $0) }
        result.reportLayout = reportLayout
        result.manifestSchemaVersion = 4
        return result
    }
}
struct WorkflowLibrary: Codable {
    var savedSearches: [SavedSearch] = []
    var inspectionPresets: [InspectionPreset] = []
}
struct WorkflowLibraryResponse: Decodable {
    var library: WorkflowLibrary
    var revision: String?
}
struct WorkflowLibraryWrite: Encodable {
    let library: WorkflowLibrary
    let expectedRevision: String?
    enum CodingKeys: String, CodingKey { case library, expectedRevision }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(library, forKey: .library)
        try c.encode(expectedRevision, forKey: .expectedRevision)
    }
}
struct WorkflowLibraryWriteResponse: Decodable { let revision: String }
struct ProjectHealthAsset: Decodable, Identifiable {
    var id: String { entityId + "/" + kind.rawValue }
    let entityId: String
    let kind: FileKind
    let filename: String
    let objectKey: String?
    let state: String
}
struct ProjectHealthResponse: Decodable {
    let projectId: String
    let revision: String
    let checkedAt: Date
    let verification: String
    let assets: [ProjectHealthAsset]
    let expected: Int
    let registered: Int
    let available: Int
    let missing: Int
}
struct ProjectVersionSummary: Decodable, Identifiable {
    let id: String
    let revision: String
    let createdAt: Date
    let photoCount: Int
    let planCount: Int
    let restorable: Bool
    let missingAssetCount: Int
}
struct ProjectVersionsResponse: Decodable { let versions: [ProjectVersionSummary] }
struct ProjectVersionResponse: Decodable, Identifiable {
    var id: String { version.id }
    let version: ProjectVersionSummary
    let project: Project
}
struct ProjectSearchHit: Decodable, Identifiable {
    var id: String { projectId.uuidString + (photoId?.uuidString ?? "") }
    let projectId: UUID
    let projectName: String
    let projectAddress: String?
    let photoId: UUID?
    let sequenceNumber: Int?
    let caption: String?
    let timestamp: Date
}
struct ProjectSearchResponse: Decodable {
    let hits: [ProjectSearchHit]
    let nextOffset: Int?
}
