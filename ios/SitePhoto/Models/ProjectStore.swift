import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

@Observable
final class ProjectStore {
    private(set) var activeProjects: [Project] = []
    private(set) var deletedProjects: [Project] = []
    private(set) var usingICloud: Bool = false
    /// Human-readable explanation for why iCloud isn't being used (nil when it is).
    private(set) var iCloudUnavailableReason: String?
    /// App-wide report branding (cover text + logo + footer). Loaded once
    /// during `loadInitial()` and saved back to disk on every mutation
    /// through `updateBranding(_:)` / `setBrandingLogo(_:)`.
    private(set) var reportBranding: ReportBranding = .empty
    /// App-wide library of pickable observation buckets, grouped by
    /// "Primary Investigation Type" (Foundation, Framing, Roofing, …).
    /// The engineer adds individual buckets from this library to a
    /// project rather than applying whole templates wholesale; the
    /// library itself is fully editable through the Library Manager.
    /// Loaded during `loadInitial()` (with default seeds on first
    /// launch, plus a one-time migration from the older
    /// `bucketTemplates.json` shape).
    private(set) var bucketLibrary: [BucketLibraryCategory] = []
    /// App-wide library of saved per-project AI instruction prompts.
    /// Loaded during `loadInitial()`; seeded with the defaults on first
    /// launch. Mutations go through `addAIPromptTemplate(...)` etc.
    private(set) var aiPromptTemplates: [AIPromptTemplate] = []
    /// App-wide three-level catalog of investigation contexts, primary
    /// tags, and secondary tags used by the AI tagging pipeline. Each
    /// project picks a subset of this catalog (`Project.tagSelection`)
    /// to scope its AI prompt's vocabulary. Loaded during
    /// `loadInitial()`; seeded from `TagLibrary.defaultSeeds` on first
    /// launch.
    private(set) var tagLibrary: TagLibrary = TagLibrary()
    /// App-wide editable template for the rules / schema block at the
    /// top of Claude's system prompt. Per-project vocabulary is
    /// compiled separately and appended below this template at request
    /// time. Loaded during `loadInitial()`; defaults to
    /// `AIRulesTemplate.defaultText` on first launch.
    private(set) var aiRulesTemplate: String = AIRulesTemplate.defaultText
    /// True while a `save(_:)` call is writing to disk. Bound to the
    /// auto-save indicator chip in ProjectDetailView so the engineer
    /// can spot a stuck or slow save (e.g. iCloud throttling) at a
    /// glance.
    private(set) var isSaving: Bool = false
    /// Timestamp of the last successful project save. The save indicator
    /// pulses "Saved" briefly after each write, then fades out.
    private(set) var lastSavedAt: Date?
    /// Loose-coupled hook for surfacing toasts from the store layer
    /// (iCloud conflicts, sync failures). The hosting app wires the
    /// ToastCenter into this slot during init — `nil` is a perfectly
    /// valid state (e.g. unit tests, previews).
    var toastCenter: ToastCenter?
    /// Loose-coupled hook called after every successful `save(_:)`,
    /// including the implicit save that `loadInitial()` does after
    /// the iCloud migration. The hosting app wires this to push the
    /// project to the Forensic server (`ManifestSyncer.sync`). Nil
    /// in tests/previews — safe.
    var onAfterSave: ((Project) -> Void)?
    /// REST client wired in by `SitePhotoApp.init` after both the store
    /// and `APIClient` exist. Read by the AI-tagging dispatch in
    /// `batchAITag(...)` / `PhotoTagEditorSheet.runClaude` when the
    /// "AI via team server" Settings toggle is on. Nil in tests /
    /// previews, in which case callers fall back to the device-key
    /// path automatically.
    var apiClient: APIClient?
    /// Fired by `persistTagLibrary()` so an external syncer can push
    /// the new value to the server. Set by `SitePhotoApp.init`
    /// (`AppConfigSyncer.bindToStore`); nil in tests / previews —
    /// safe. Receives the current full tag library at the moment of
    /// the mutation; the syncer copies and queues so the caller isn't
    /// blocked on the network.
    var onTagLibraryChanged: ((TagLibrary) -> Void)?
    /// Fired by `persistAIRulesTemplate()` so an external syncer can
    /// push the new value to the server. Same wiring shape as
    /// `onTagLibraryChanged`.
    var onAIRulesTemplateChanged: ((String) -> Void)?
    /// True once `loadInitial()` has finished — the App scene's splash
    /// keeps showing until this flips, so the slow first-launch iCloud
    /// probe doesn't push the splash render back behind a blank screen.
    private(set) var isReady: Bool = false
    /// Human-readable description of what `loadInitial()` is currently
    /// doing. Rendered on the splash screen so the engineer can see
    /// which stage is stuck when a launch takes longer than expected
    /// (typically the iCloud container probe on a fresh install or a
    /// simulator with a wedged iCloud daemon).
    private(set) var loadStatus: String = "Starting up…"

    private let fileManager = FileManager.default
    /// Mutated once during `loadInitial()` when the iCloud probe finishes.
    /// Defaults to local while loadInitial is in flight so the rest of the
    /// API never has a nil rootURL to deal with.
    private var storageRoot: URL

    var rootURL: URL { storageRoot }

    /// "Active Projects" subfolder — projects shown in the main list.
    var activeRoot: URL {
        storageRoot.appending(path: Self.activeFolderName, directoryHint: .isDirectory)
    }

    /// "Deleted Projects" subfolder — soft-deleted projects, recoverable
    /// until permanently deleted.
    var deletedRoot: URL {
        storageRoot.appending(path: Self.deletedFolderName, directoryHint: .isDirectory)
    }

    static let activeFolderName  = "Active Projects"
    static let deletedFolderName = "Deleted Projects"

    /// Fast init — only sets up the local storage root. The slow iCloud
    /// probe + project load is in `loadInitial()` so the splash screen can
    /// render immediately and the user doesn't see a 1–3-second white
    /// pause before any UI appears.
    init() {
        let local = Self.localProjectsURL
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        Self.ensureSubfolders(in: local)
        self.storageRoot = local
    }

    /// Async setup: probe iCloud (slow on cold launch), promote storageRoot
    /// to iCloud if available, run the local→iCloud migration, then load
    /// projects. Safe to call multiple times — guarded by `isReady`.
    ///
    /// Sets `loadStatus` at each stage so the splash screen can show what
    /// the app is doing while the user waits. The iCloud probe is the
    /// dominant cost (1–3 s on a real device on cold launch; can be
    /// indefinitely stuck on a simulator where the iCloud daemon is
    /// wedged — flag for the user to recognize that case).
    @MainActor
    func loadInitial() async {
        guard !isReady else { return }

        loadStatus = "Checking iCloud Drive…"

        // The iCloud-container probe (`forUbiquityContainerIdentifier`)
        // is the dominant cost on first launch and *can hang
        // indefinitely* on the iOS Simulator when Apple's iCloud
        // daemon is wedged (a well-known simulator-side bug with no
        // fix from our side). On a real device the call returns in
        // 1–3 s. Compile-time `targetEnvironment(simulator)` skips
        // the probe entirely on simulator builds — engineering
        // preview / UI work in the simulator gets a fast launch;
        // iCloud sync is verified on real iPhone.
        let iCloudURL: URL? = await Task.detached {
            #if targetEnvironment(simulator)
            return nil
            #else
            guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                return nil
            }
            let docs = containerURL.appending(path: "Documents", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let projects = docs.appending(path: "Projects", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            return projects
            #endif
        }.value

        if let iCloud = iCloudURL {
            self.storageRoot = iCloud
            self.usingICloud = true
            self.iCloudUnavailableReason = nil
            loadStatus = "Setting up iCloud storage…"
        } else {
            self.usingICloud = false
            #if targetEnvironment(simulator)
            self.iCloudUnavailableReason = "Running in iOS Simulator — iCloud Drive intentionally disabled to avoid known simulator iCloud-daemon hangs. iCloud sync is verified on real iPhone."
            #else
            self.iCloudUnavailableReason = "iCloud Drive isn't enabled. Open Settings → Apple ID → iCloud → iCloud Drive and turn it on (and SitePhoto inside the app list) to back projects up to iCloud."
            #endif
            loadStatus = "Using local storage only…"
        }

        Self.ensureSubfolders(in: storageRoot)

        // Defensive only: copies any project folders the user created in
        // local storage (because iCloud was offline) up to iCloud now that
        // it's available. Fast no-op when local is empty.
        if usingICloud {
            loadStatus = "Migrating local projects to iCloud…"
            let local = Self.localProjectsURL
            let activeLocal   = local.appending(path: Self.activeFolderName,  directoryHint: .isDirectory)
            let activeICloud  = storageRoot.appending(path: Self.activeFolderName,  directoryHint: .isDirectory)
            let deletedLocal  = local.appending(path: Self.deletedFolderName, directoryHint: .isDirectory)
            let deletedICloud = storageRoot.appending(path: Self.deletedFolderName, directoryHint: .isDirectory)
            await Task.detached {
                Self.migrateProjects(from: activeLocal,  to: activeICloud)
                Self.migrateProjects(from: deletedLocal, to: deletedICloud)
            }.value
        }

        loadStatus = "Loading projects…"
        load()
        loadStatus = "Loading report branding…"
        loadBrandingFromDisk()
        loadStatus = "Loading bucket library…"
        loadBucketLibraryFromDisk()
        loadStatus = "Loading AI templates…"
        loadAIPromptTemplatesFromDisk()
        loadStatus = "Loading tag library…"
        loadTagLibraryFromDisk()
        loadAIRulesTemplateFromDisk()
        loadStatus = "Finalizing…"
        pruneStaleTagSelections()
        purgeOldTrash()
        loadStatus = "Ready."
        isReady = true
    }

    /// Walk every project (active + trashed) and remove any context,
    /// primary, or secondary reference in its `tagSelection` that no
    /// longer resolves in the current `tagLibrary`. Cheap on small
    /// libraries; runs once per launch right after the library is
    /// loaded. Only persists projects whose pruned selection actually
    /// differs from what's on disk — engineers whose selections are
    /// already clean pay zero write cost.
    ///
    /// Pruning is intentionally narrower than the old seed-version
    /// migration: it only removes dangling references, never resets
    /// or replaces engineer-curated state. Stale references are
    /// effectively data-rot — they don't refer to anything the user
    /// could ever see — so removing them is housekeeping, not loss.
    private func pruneStaleTagSelections() {
        let library = tagLibrary
        for project in activeProjects + deletedProjects {
            guard let selection = project.tagSelection else { continue }
            let pruned = selection.pruning(against: library)
            if pruned != selection {
                var p = project
                p.tagSelection = pruned.contextIDs.isEmpty ? nil : pruned
                _ = save(p)
            }
        }
    }

    private static var localProjectsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Projects", directoryHint: .isDirectory)
    }

    private static func ensureSubfolders(in root: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: root.appending(path: activeFolderName, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try? fm.createDirectory(
            at: root.appending(path: deletedFolderName, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    /// Move every project folder from `src` to `dst`. If a folder with the
    /// same name already exists in `dst` (e.g. a previous partial migration),
    /// skip it - the iCloud copy is treated as authoritative.
    private static func migrateProjects(from src: URL, to dst: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path()) else { return }
        guard let entries = try? fm.contentsOfDirectory(at: src,
                                                        includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let destEntry = dst.appending(path: entry.lastPathComponent, directoryHint: .isDirectory)
            if fm.fileExists(atPath: destEntry.path()) {
                // Already there from a previous run; remove the local copy
                // since iCloud is now the source of truth.
                try? fm.removeItem(at: entry)
                continue
            }
            do {
                try fm.copyItem(at: entry, to: destEntry)
                // Verify the manifest came through before deleting the source.
                let manifestExists = fm.fileExists(
                    atPath: destEntry.appending(path: "manifest.json").path()
                )
                if manifestExists {
                    try fm.removeItem(at: entry)
                }
            } catch {
                #if DEBUG
                print("iCloud migration failed for \(entry.lastPathComponent): \(error)")
                #endif
            }
        }
    }

    func projectURL(_ project: Project) -> URL {
        let folderName = project.folderName
            ?? Project.makeFolderName(id: project.id, name: project.name, createdAt: project.createdAt)
        let root = isDeleted(project) ? deletedRoot : activeRoot
        return root.appending(path: folderName, directoryHint: .isDirectory)
    }

    private func isDeleted(_ project: Project) -> Bool {
        deletedProjects.contains { $0.id == project.id }
    }

    func photosFolder(for project: Project) -> URL {
        projectURL(project).appending(path: "photos", directoryHint: .isDirectory)
    }

    func thumbnailsFolder(for project: Project) -> URL {
        projectURL(project).appending(path: "thumbnails", directoryHint: .isDirectory)
    }

    /// Directory holding PencilKit markup overlay files (one PNG per
    /// annotated photo, plus the matching `.drawing` data for re-editing).
    func markupsFolder(for project: Project) -> URL {
        projectURL(project).appending(path: "markups", directoryHint: .isDirectory)
    }

    /// Resolved URL of `photo`'s markup PNG overlay, or nil if the photo
    /// has no overlay or the file is missing on disk.
    func markupOverlayURL(for photo: Photo, in project: Project) -> URL? {
        guard let name = photo.markupOverlayFilename else { return nil }
        let url = markupsFolder(for: project).appending(path: name)
        guard fileManager.fileExists(atPath: url.path()) else { return nil }
        return url
    }

    /// Resolved URL of `photo`'s `.drawing` data, used to re-open the
    /// markup view with prior strokes intact.
    func markupDrawingURL(for photo: Photo, in project: Project) -> URL? {
        guard let name = photo.markupDrawingFilename else { return nil }
        let url = markupsFolder(for: project).appending(path: name)
        guard fileManager.fileExists(atPath: url.path()) else { return nil }
        return url
    }

    /// Persist a fresh PencilKit overlay for `photoID`. `pngData` is the
    /// rendered transparent overlay (full-photo-resolution); `drawingData`
    /// is the raw `PKDrawing.dataRepresentation()` so the next markup
    /// session can resume editing. Both files share the photo's stem and
    /// live under `markupsFolder(for:)`.
    @discardableResult
    func saveMarkup(_ project: Project,
                     photoID: UUID,
                     pngData: Data,
                     drawingData: Data) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let folder = markupsFolder(for: p)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = (p.photos[idx].imageFilename as NSString).deletingPathExtension
        let pngName = "\(stem)_markup.png"
        let drawingName = "\(stem)_markup.drawing"
        let pngURL = folder.appending(path: pngName)
        let drawingURL = folder.appending(path: drawingName)
        try? pngData.write(to: pngURL, options: .atomic)
        try? drawingData.write(to: drawingURL, options: .atomic)
        p.photos[idx].markupOverlayFilename = pngName
        p.photos[idx].markupDrawingFilename = drawingName
        return save(p)
    }

    // MARK: - Re-shoot relationships

    /// Stamp a freshly-captured photo as a re-shoot of `original`, copying
    /// the inheritable fields (bucket + confirmed tags) onto the new photo
    /// and writing the `reshootsPhotoID` linkage. Location/bearing are
    /// inherited separately via the `PhotoLocation` passed to `addPhoto`,
    /// so callers do that *and* call this helper to finish the wiring.
    @discardableResult
    func applyReshoot(to project: Project,
                       newPhotoID: UUID,
                       from original: Photo) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == newPhotoID }) else { return p }
        p.photos[idx].reshootsPhotoID = original.id
        p.photos[idx].bucketID = original.bucketID
        // Inherit confirmed tags only; pending suggestions belong to the
        // original's frame and have to be re-run on the new content.
        p.photos[idx].tags = original.tags
        return save(p)
    }

    /// Resolve the chain of photos that participate in a reshoot lineage:
    /// the root original first, then every reshoot in capture order
    /// (oldest → newest). Used by `PhotoComparisonView` to render the
    /// before/after spread. Returns `[photo]` (just the photo itself) when
    /// nothing else links to it.
    func reshootChain(for photo: Photo, in project: Project) -> [Photo] {
        // Walk back to the root.
        var root = photo
        var visited: Set<UUID> = [photo.id]
        while let parentID = root.reshootsPhotoID,
              let parent = project.photos.first(where: { $0.id == parentID }),
              !visited.contains(parent.id) {
            root = parent
            visited.insert(parent.id)
        }
        // Walk forward from the root, sorting reshoots by sequence number.
        var chain: [Photo] = [root]
        var frontier: [Photo] = [root]
        while !frontier.isEmpty {
            let next = project.photos
                .filter { $0.reshootsPhotoID == frontier[0].id }
                .sorted { $0.sequenceNumber < $1.sequenceNumber }
            chain.append(contentsOf: next)
            frontier.removeFirst()
            frontier.append(contentsOf: next)
        }
        return chain
    }

    /// Drop the markup overlay + drawing file from disk and clear the
    /// references on `photoID`.
    @discardableResult
    func clearMarkup(_ project: Project, photoID: UUID) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let folder = markupsFolder(for: p)
        if let name = p.photos[idx].markupOverlayFilename {
            try? fileManager.removeItem(at: folder.appending(path: name))
        }
        if let name = p.photos[idx].markupDrawingFilename {
            try? fileManager.removeItem(at: folder.appending(path: name))
        }
        p.photos[idx].markupOverlayFilename = nil
        p.photos[idx].markupDrawingFilename = nil
        return save(p)
    }

    func manifestURL(for project: Project) -> URL {
        projectURL(project).appending(path: "manifest.json")
    }

    // MARK: - Report branding (app-wide)

    /// Where the firm-level branding JSON lives. Sibling of `Active/` and
    /// `Deleted/` under the storage root so it survives the iCloud
    /// promotion path and isn't tied to any one project.
    private var brandingURL: URL {
        storageRoot.appending(path: "branding.json")
    }

    /// Where the optional custom logo lives. Stored as PNG with a stable
    /// filename so re-imports overwrite the same file (rather than
    /// accumulating orphan logos).
    var brandingLogoURL: URL? {
        let url = storageRoot.appending(path: "branding-logo.png")
        return fileManager.fileExists(atPath: url.path()) ? url : nil
    }

    /// Read the branding JSON from disk into `reportBranding`. Called
    /// during `loadInitial()` — silent no-op when the file doesn't exist
    /// (fresh install or user hasn't customised yet).
    fileprivate func loadBrandingFromDisk() {
        guard let data = try? Data(contentsOf: brandingURL),
              let decoded = try? decoder().decode(ReportBranding.self, from: data) else {
            reportBranding = .empty
            return
        }
        reportBranding = decoded
    }

    /// Persist `branding` to disk and publish it as the observable state.
    @discardableResult
    func updateBranding(_ branding: ReportBranding) -> ReportBranding {
        // If the user cleared the logo filename, scrub the file too so
        // the on-disk state matches the model.
        if branding.logoFilename == nil,
           let url = brandingLogoURL {
            try? fileManager.removeItem(at: url)
        }
        if let data = try? encoder().encode(branding) {
            try? data.write(to: brandingURL, options: .atomic)
        }
        reportBranding = branding
        return branding
    }

    /// Save a fresh logo image (downsampled to a sensible size — PDF
    /// cover renders at ~75pt wide, so 300px on the long edge is plenty)
    /// and update the branding manifest with the relative filename.
    @discardableResult
    func setBrandingLogo(_ image: UIImage?) -> ReportBranding {
        var branding = reportBranding
        if let image, let resized = Self.resizeForLogo(image),
           let data = resized.pngData() {
            let url = storageRoot.appending(path: "branding-logo.png")
            try? data.write(to: url, options: .atomic)
            branding.logoFilename = "branding-logo.png"
        } else {
            if let url = brandingLogoURL {
                try? fileManager.removeItem(at: url)
            }
            branding.logoFilename = nil
        }
        return updateBranding(branding)
    }

    /// Resolve the branding logo to a UIImage. Falls back to the bundled
    /// `BaykalLogo` asset when no custom logo has been uploaded so existing
    /// installs keep the same cover look until customised.
    func brandingLogoImage() -> UIImage? {
        if let url = brandingLogoURL,
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        return UIImage(named: "BaykalLogo")
    }

    // MARK: - Bucket library (app-wide)

    /// Where the library JSON lives. Sibling of branding.json under the
    /// storage root — survives iCloud promotion the same way.
    private var bucketLibraryURL: URL {
        storageRoot.appending(path: "bucketLibrary.json")
    }

    /// Path to the legacy template file we wrote during the
    /// short-lived "templates" iteration. Migrated forward and removed
    /// on first launch after the library rework.
    private var legacyBucketTemplatesURL: URL {
        storageRoot.appending(path: "bucketTemplates.json")
    }

    /// Hydrate `bucketLibrary` in priority order:
    ///  1. `bucketLibrary.json` if it already exists (steady state)
    ///  2. `bucketTemplates.json` from the older shape (one-time
    ///     migration: assign UUIDs to entries, save into the new file,
    ///     then delete the old)
    ///  3. seeded defaults from `BucketLibraryCategory.defaultSeeds`
    fileprivate func loadBucketLibraryFromDisk() {
        if let data = try? Data(contentsOf: bucketLibraryURL),
           let decoded = try? decoder().decode([BucketLibraryCategory].self, from: data) {
            bucketLibrary = decoded
            return
        }
        if let data = try? Data(contentsOf: legacyBucketTemplatesURL),
           let legacy = try? decoder().decode([LegacyBucketTemplate].self, from: data) {
            bucketLibrary = legacy.map { $0.upgraded() }
            persistBucketLibrary()
            try? fileManager.removeItem(at: legacyBucketTemplatesURL)
            return
        }
        bucketLibrary = BucketLibraryCategory.defaultSeeds
        persistBucketLibrary()
    }

    private func persistBucketLibrary() {
        if let data = try? encoder().encode(bucketLibrary) {
            try? data.write(to: bucketLibraryURL, options: .atomic)
        }
    }

    // Categories ---------------------------------------------------------

    @discardableResult
    func addLibraryCategory(name rawName: String) -> BucketLibraryCategory? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let category = BucketLibraryCategory(name: name, entries: [])
        bucketLibrary.append(category)
        persistBucketLibrary()
        return category
    }

    @discardableResult
    func renameLibraryCategory(_ id: UUID, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let idx = bucketLibrary.firstIndex(where: { $0.id == id }) else {
            return false
        }
        bucketLibrary[idx].name = name
        persistBucketLibrary()
        return true
    }

    @discardableResult
    func deleteLibraryCategory(_ id: UUID) -> Bool {
        let before = bucketLibrary.count
        bucketLibrary.removeAll { $0.id == id }
        let changed = bucketLibrary.count != before
        if changed { persistBucketLibrary() }
        return changed
    }

    func reorderLibraryCategories(from source: IndexSet, to destination: Int) {
        bucketLibrary.move(fromOffsets: source, toOffset: destination)
        persistBucketLibrary()
    }

    // Entries ------------------------------------------------------------

    @discardableResult
    func addLibraryEntry(toCategory categoryID: UUID,
                          name rawName: String,
                          colorHex: String) -> BucketLibraryCategory.Entry? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let idx = bucketLibrary.firstIndex(where: { $0.id == categoryID }) else {
            return nil
        }
        let entry = BucketLibraryCategory.Entry(name: name, colorHex: colorHex)
        bucketLibrary[idx].entries.append(entry)
        persistBucketLibrary()
        return entry
    }

    @discardableResult
    func renameLibraryEntry(inCategory categoryID: UUID,
                             entry entryID: UUID,
                             to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let cIdx = bucketLibrary.firstIndex(where: { $0.id == categoryID }),
              let eIdx = bucketLibrary[cIdx].entries.firstIndex(where: { $0.id == entryID }) else {
            return false
        }
        bucketLibrary[cIdx].entries[eIdx].name = name
        persistBucketLibrary()
        return true
    }

    @discardableResult
    func recolorLibraryEntry(inCategory categoryID: UUID,
                              entry entryID: UUID,
                              to colorHex: String) -> Bool {
        guard let cIdx = bucketLibrary.firstIndex(where: { $0.id == categoryID }),
              let eIdx = bucketLibrary[cIdx].entries.firstIndex(where: { $0.id == entryID }) else {
            return false
        }
        bucketLibrary[cIdx].entries[eIdx].colorHex = colorHex
        persistBucketLibrary()
        return true
    }

    @discardableResult
    func deleteLibraryEntry(inCategory categoryID: UUID, entry entryID: UUID) -> Bool {
        guard let cIdx = bucketLibrary.firstIndex(where: { $0.id == categoryID }) else {
            return false
        }
        let before = bucketLibrary[cIdx].entries.count
        bucketLibrary[cIdx].entries.removeAll { $0.id == entryID }
        let changed = bucketLibrary[cIdx].entries.count != before
        if changed { persistBucketLibrary() }
        return changed
    }

    func reorderLibraryEntries(inCategory categoryID: UUID,
                                from source: IndexSet,
                                to destination: Int) {
        guard let cIdx = bucketLibrary.firstIndex(where: { $0.id == categoryID }) else { return }
        bucketLibrary[cIdx].entries.move(fromOffsets: source, toOffset: destination)
        persistBucketLibrary()
    }

    // Project-side helpers ----------------------------------------------

    /// Add the library entries identified by `entryIDs` to `project` as
    /// fresh project buckets. The store resolves each entry back to its
    /// owning category so the new bucket's `libraryCategoryID` points
    /// at the right group — that's what makes the Bucket Manager's
    /// "subheadings" grouping work. Each new bucket gets a fresh UUID
    /// (no aliasing with the library entry id).
    @discardableResult
    func addLibraryEntries(withIDs entryIDs: Set<UUID>,
                            to project: Project) -> Project {
        guard !entryIDs.isEmpty else { return project }
        var p = project
        let baseOrder = p.buckets.map(\.sortOrder).max().map { $0 + 1 } ?? 0
        var offset = 0
        // Walk the library in render order so the added buckets fall in
        // the same visual order as the picker presented them.
        for category in bucketLibrary {
            for entry in category.entries where entryIDs.contains(entry.id) {
                p.buckets.append(Bucket(name: entry.name,
                                         colorHex: entry.colorHex,
                                         sortOrder: baseOrder + offset,
                                         libraryCategoryID: category.id))
                offset += 1
            }
        }
        return save(p)
    }

    /// Reverse direction: capture a project's existing bucket and stash
    /// it in the chosen library category so the engineer can reuse it
    /// on future projects. Returns the new entry on success.
    @discardableResult
    func saveBucketToLibrary(_ bucket: Bucket,
                              intoCategory categoryID: UUID) -> BucketLibraryCategory.Entry? {
        return addLibraryEntry(toCategory: categoryID,
                                name: bucket.name,
                                colorHex: bucket.colorHex)
    }

    /// Tag (or untag) a project bucket with the library category it
    /// belongs to. Drives the subheading grouping in BucketManagerSheet
    /// and lets "Save to Library" classify the bucket at the same time
    /// it copies the entry into the library.
    @discardableResult
    func setBucketLibraryCategory(_ project: Project,
                                   bucketID: UUID,
                                   libraryCategoryID: UUID?) -> Project {
        guard let idx = project.buckets.firstIndex(where: { $0.id == bucketID }) else {
            return project
        }
        var p = project
        p.buckets[idx].libraryCategoryID = libraryCategoryID
        return save(p)
    }

    // MARK: - AI prompt templates (app-wide)

    private var aiPromptTemplatesURL: URL {
        storageRoot.appending(path: "aiPromptTemplates.json")
    }

    fileprivate func loadAIPromptTemplatesFromDisk() {
        if let data = try? Data(contentsOf: aiPromptTemplatesURL),
           let decoded = try? decoder().decode([AIPromptTemplate].self, from: data) {
            aiPromptTemplates = decoded
            return
        }
        aiPromptTemplates = AIPromptTemplate.defaultSeeds
        persistAIPromptTemplates()
    }

    private func persistAIPromptTemplates() {
        if let data = try? encoder().encode(aiPromptTemplates) {
            try? data.write(to: aiPromptTemplatesURL, options: .atomic)
        }
    }

    @discardableResult
    func addAIPromptTemplate(name rawName: String,
                              prompt: String) -> AIPromptTemplate? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !body.isEmpty else { return nil }
        let template = AIPromptTemplate(name: name, prompt: body)
        aiPromptTemplates.append(template)
        persistAIPromptTemplates()
        return template
    }

    @discardableResult
    func renameAIPromptTemplate(_ id: UUID, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let idx = aiPromptTemplates.firstIndex(where: { $0.id == id }) else {
            return false
        }
        aiPromptTemplates[idx].name = name
        persistAIPromptTemplates()
        return true
    }

    @discardableResult
    func updateAIPromptTemplate(_ id: UUID, prompt: String) -> Bool {
        let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty,
              let idx = aiPromptTemplates.firstIndex(where: { $0.id == id }) else {
            return false
        }
        aiPromptTemplates[idx].prompt = body
        persistAIPromptTemplates()
        return true
    }

    @discardableResult
    func deleteAIPromptTemplate(_ id: UUID) -> Bool {
        let before = aiPromptTemplates.count
        aiPromptTemplates.removeAll { $0.id == id }
        let changed = aiPromptTemplates.count != before
        if changed { persistAIPromptTemplates() }
        return changed
    }

    // MARK: - Tag library (app-wide)

    /// Where the three-level tag library JSON lives. Sibling of
    /// `bucketLibrary.json` under the storage root so it follows the
    /// same iCloud-promotion path as every other shared catalog.
    private var tagLibraryURL: URL {
        storageRoot.appending(path: "tagLibrary.json")
    }

    /// Load the tag library from disk, falling back to the bundled
    /// starter pack (`TagLibrary.defaultSeeds`) when no file exists
    /// (fresh install). The starter pack is persisted immediately on
    /// first launch so subsequent reads are consistent.
    ///
    /// On every launch after the first, the persisted library is the
    /// source of truth — including any contexts, primaries, or
    /// secondaries the engineer added or renamed through the Tag
    /// Library Manager. The bundled defaults in code are NEVER merged
    /// in or used to overwrite the disk file, even when a new build
    /// of the app ships an updated seed. Customisations are durable
    /// across app updates by design.
    ///
    /// (Earlier builds carried a v1 → v2 migration here that wiped
    /// the persisted library + rules template + every project's tag
    /// selection. It was removed deliberately on the user's request
    /// once the v2 rollout had landed on every device that needed it.
    /// If a future schema reshape ever requires re-seeding, design
    /// the migration to be additive — append missing primaries /
    /// secondaries rather than replacing the file wholesale.)
    fileprivate func loadTagLibraryFromDisk() {
        if let data = try? Data(contentsOf: tagLibraryURL),
           let decoded = try? decoder().decode(TagLibrary.self, from: data) {
            // Gate: if the persisted library predates the currently
            // bundled seed version, force a one-shot reset onto the
            // new bundled defaults. The reset is intentionally wide
            // (library + rules template + every project's
            // tagSelection) because a vocab refresh changes primary /
            // secondary UUIDs and stale references would silently
            // drop out of the AI Tags picker — worse than wiping
            // them outright. After migration the new seed version is
            // persisted on disk so subsequent launches skip this
            // branch.
            if decoded.seedVersion < TagLibrary.currentSeedVersion {
                migrateLegacyTagLibraryToCurrentSeed()
                return
            }
            tagLibrary = decoded
            return
        }
        tagLibrary = TagLibrary.defaultSeeds
        persistTagLibrary()
    }

    /// One-shot upgrade path triggered by `loadTagLibraryFromDisk` when
    /// the persisted `seedVersion` is behind `TagLibrary.currentSeedVersion`.
    /// Adopts the bundled v3+ defaults wholesale — library, rules
    /// template, and every project's `tagSelection`. The engineer's
    /// post-upgrade customisations still persist normally; only the
    /// version-crossing forces a reset.
    private func migrateLegacyTagLibraryToCurrentSeed() {
        // 1. Library: drop whatever was on disk in favour of the
        //    bundled defaults, then persist so the new
        //    `seedVersion` lands on disk and gates the next launch
        //    out of this branch.
        tagLibrary = TagLibrary.defaultSeeds
        persistTagLibrary()

        // 2. Rules template: overwrite both in-memory and on disk.
        //    `loadAIRulesTemplateFromDisk` runs after this function in
        //    `init`, but because we just wrote the fresh default to
        //    disk it reads the same text back — no risk of stale
        //    in-memory text overriding what we just set here.
        aiRulesTemplate = AIRulesTemplate.defaultText
        persistAIRulesTemplate()

        // 3. Every project's tagSelection: replace with the new
        //    "all primaries selected in every context" default. The
        //    old selection's UUIDs reference the previous seed's
        //    primaries and would otherwise resolve to nothing
        //    (which the picker treats as "no contexts picked,"
        //    blocking AI tagging until the engineer re-selects).
        let everything = defaultTagSelection()
        let allProjects = activeProjects + deletedProjects
        for project in allProjects {
            var p = project
            p.tagSelection = everything
            _ = save(p)
        }
    }

    /// Build a "select every primary in every context" selection
    /// against the current library. Used for new projects so they
    /// don't ship with no vocabulary picked (which would trip the
    /// `noContextsPicked` guard before the engineer can even tag a
    /// photo). After the v2 flatten there's a single context, so this
    /// degenerates to "every primary selected in the Forensic
    /// Investigation context."
    func defaultTagSelection() -> ProjectTagSelection {
        var selection = ProjectTagSelection()
        for ctx in tagLibrary.contexts {
            selection.contextIDs.append(ctx.id)
            selection.primariesByContext[ctx.id] = Set(ctx.primaries.map(\.id))
        }
        return selection
    }

    private func persistTagLibrary() {
        if let data = try? encoder().encode(tagLibrary) {
            try? data.write(to: tagLibraryURL, options: .atomic)
        }
        onTagLibraryChanged?(tagLibrary)
    }

    /// Replace the persisted tag library with `TagLibrary.defaultSeeds`.
    /// Engineer-initiated path only — invoked from the "Restore to
    /// default seed" button in the Tag Library Manager. Intentionally
    /// scoped narrowly: project tag selections and the rules template
    /// are NOT touched. Selections that referenced a primary that no
    /// longer exists silently drop out of the picker on next read,
    /// which is the same behaviour the picker uses for any stale ID.
    func restoreTagLibraryToDefaults() {
        tagLibrary = TagLibrary.defaultSeeds
        persistTagLibrary()
    }

    // Contexts ----------------------------------------------------------

    @discardableResult
    func addTagContext(name rawName: String) -> InvestigationContext? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let ctx = InvestigationContext(name: name, primaries: [])
        tagLibrary.contexts.append(ctx)
        persistTagLibrary()
        return ctx
    }

    @discardableResult
    func renameTagContext(_ id: UUID, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let idx = tagLibrary.contexts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        tagLibrary.contexts[idx].name = name
        persistTagLibrary()
        return true
    }

    @discardableResult
    func deleteTagContext(_ id: UUID) -> Bool {
        let before = tagLibrary.contexts.count
        tagLibrary.contexts.removeAll { $0.id == id }
        let changed = tagLibrary.contexts.count != before
        if changed { persistTagLibrary() }
        return changed
    }

    func reorderTagContexts(from source: IndexSet, to destination: Int) {
        tagLibrary.contexts.move(fromOffsets: source, toOffset: destination)
        persistTagLibrary()
    }

    // Primaries ---------------------------------------------------------

    @discardableResult
    func addTagPrimary(toContext contextID: UUID,
                        name rawName: String) -> PrimaryTagEntry? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let cIdx = tagLibrary.contexts.firstIndex(where: { $0.id == contextID }) else {
            return nil
        }
        let entry = PrimaryTagEntry(name: name, secondaries: [])
        tagLibrary.contexts[cIdx].primaries.append(entry)
        persistTagLibrary()
        return entry
    }

    @discardableResult
    func renameTagPrimary(inContext contextID: UUID,
                           primary primaryID: UUID,
                           to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let cIdx = tagLibrary.contexts.firstIndex(where: { $0.id == contextID }),
              let pIdx = tagLibrary.contexts[cIdx].primaries.firstIndex(where: { $0.id == primaryID }) else {
            return false
        }
        tagLibrary.contexts[cIdx].primaries[pIdx].name = name
        persistTagLibrary()
        return true
    }

    @discardableResult
    func deleteTagPrimary(inContext contextID: UUID, primary primaryID: UUID) -> Bool {
        guard let cIdx = tagLibrary.contexts.firstIndex(where: { $0.id == contextID }) else {
            return false
        }
        let before = tagLibrary.contexts[cIdx].primaries.count
        tagLibrary.contexts[cIdx].primaries.removeAll { $0.id == primaryID }
        let changed = tagLibrary.contexts[cIdx].primaries.count != before
        if changed { persistTagLibrary() }
        return changed
    }

    func reorderTagPrimaries(inContext contextID: UUID,
                              from source: IndexSet,
                              to destination: Int) {
        guard let cIdx = tagLibrary.contexts.firstIndex(where: { $0.id == contextID }) else { return }
        tagLibrary.contexts[cIdx].primaries.move(fromOffsets: source, toOffset: destination)
        persistTagLibrary()
    }

    // Secondaries -------------------------------------------------------

    @discardableResult
    func addTagSecondary(inContext contextID: UUID,
                          primary primaryID: UUID,
                          name rawName: String) -> SecondaryTagEntry? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let cIdx = tagLibrary.contexts.firstIndex(where: { $0.id == contextID }),
              let pIdx = tagLibrary.contexts[cIdx].primaries.firstIndex(where: { $0.id == primaryID }) else {
            return nil
        }
        let entry = SecondaryTagEntry(name: name)
        tagLibrary.contexts[cIdx].primaries[pIdx].secondaries.append(entry)
        persistTagLibrary()
        return entry
    }

    @discardableResult
    func renameTagSecondary(inContext contextID: UUID,
                             primary primaryID: UUID,
                             secondary secondaryID: UUID,
                             to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let cIdx = tagLibrary.contexts.firstIndex(where: { $0.id == contextID }),
              let pIdx = tagLibrary.contexts[cIdx].primaries.firstIndex(where: { $0.id == primaryID }),
              let sIdx = tagLibrary.contexts[cIdx].primaries[pIdx].secondaries.firstIndex(where: { $0.id == secondaryID }) else {
            return false
        }
        tagLibrary.contexts[cIdx].primaries[pIdx].secondaries[sIdx].name = name
        persistTagLibrary()
        return true
    }

    @discardableResult
    func deleteTagSecondary(inContext contextID: UUID,
                             primary primaryID: UUID,
                             secondary secondaryID: UUID) -> Bool {
        guard let cIdx = tagLibrary.contexts.firstIndex(where: { $0.id == contextID }),
              let pIdx = tagLibrary.contexts[cIdx].primaries.firstIndex(where: { $0.id == primaryID }) else {
            return false
        }
        let before = tagLibrary.contexts[cIdx].primaries[pIdx].secondaries.count
        tagLibrary.contexts[cIdx].primaries[pIdx].secondaries.removeAll { $0.id == secondaryID }
        let changed = tagLibrary.contexts[cIdx].primaries[pIdx].secondaries.count != before
        if changed { persistTagLibrary() }
        return changed
    }

    func reorderTagSecondaries(inContext contextID: UUID,
                                 primary primaryID: UUID,
                                 from source: IndexSet,
                                 to destination: Int) {
        guard let cIdx = tagLibrary.contexts.firstIndex(where: { $0.id == contextID }),
              let pIdx = tagLibrary.contexts[cIdx].primaries.firstIndex(where: { $0.id == primaryID }) else { return }
        tagLibrary.contexts[cIdx].primaries[pIdx].secondaries.move(fromOffsets: source, toOffset: destination)
        persistTagLibrary()
    }

    // Project-side helper -----------------------------------------------

    /// Update a project's tag selection (or clear it with `nil`) and
    /// persist the manifest. Returns the saved project so call sites can
    /// chain.
    @discardableResult
    func setTagSelection(_ project: Project,
                          _ selection: ProjectTagSelection?) -> Project {
        var p = project
        p.tagSelection = selection
        return save(p)
    }

    // MARK: - AI rules template (app-wide)

    /// Where the rules-template text lives. Plain `.txt` so the
    /// engineer can spot-check it in Files.app without unwrapping a
    /// JSON envelope.
    private var aiRulesTemplateURL: URL {
        storageRoot.appending(path: "aiRulesTemplate.txt")
    }

    fileprivate func loadAIRulesTemplateFromDisk() {
        if let data = try? Data(contentsOf: aiRulesTemplateURL),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            aiRulesTemplate = text
            return
        }
        aiRulesTemplate = AIRulesTemplate.defaultText
        persistAIRulesTemplate()
    }

    private func persistAIRulesTemplate() {
        if let data = aiRulesTemplate.data(using: .utf8) {
            try? data.write(to: aiRulesTemplateURL, options: .atomic)
        }
        onAIRulesTemplateChanged?(aiRulesTemplate)
    }

    /// Replace the rules-template text and persist. Trimming + empty
    /// fallback keeps a blank editor save from wiping the prompt.
    @discardableResult
    func updateAIRulesTemplate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        aiRulesTemplate = trimmed.isEmpty ? AIRulesTemplate.defaultText : text
        persistAIRulesTemplate()
        return aiRulesTemplate
    }

    private static func resizeForLogo(_ image: UIImage) -> UIImage? {
        let maxSide: CGFloat = 600
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longSide = max(size.width, size.height)
        guard longSide > maxSide else { return image }
        let scale = maxSide / longSide
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
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
        activeProjects = loadProjects(in: activeRoot)
        deletedProjects = loadProjects(in: deletedRoot)
    }

    /// Walks one root (Active Projects or Deleted Projects) and decodes
    /// each manifest. Trusts the on-disk folder name as the canonical
    /// folderName for each project — no rename is performed.
    private func loadProjects(in root: URL) -> [Project] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        var loaded: [Project] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let manifest = dir.appending(path: "manifest.json")
            guard let data = try? Data(contentsOf: manifest) else { continue }
            do {
                var project = try decoder().decode(Project.self, from: data)
                // Defend against in-memory drift between project.folderName
                // and the actual folder name on disk: trust the folder name.
                let actualName = dir.lastPathComponent
                if project.folderName != actualName {
                    project.folderName = actualName
                }
                migrateLegacyFloorPlanIfNeeded(in: &project, projectDir: dir)
                loaded.append(project)
            } catch {
                #if DEBUG
                print("Failed to decode project at \(manifest.path): \(error)")
                #endif
            }
        }
        return loaded.sorted { $0.createdAt > $1.createdAt }
    }

    /// One-shot, idempotent migration: if `project` was loaded from a
    /// pre-multi-plan manifest (legacy `floorPlan` field decoded into a
    /// single-element `floorPlans` array via `Project.init(from:)`),
    /// rename the on-disk image from the legacy `plan.jpg` to the new
    /// `plan-<uuidPrefix>.jpg` and stamp every photo with placement
    /// data with the migrated `floorPlanID`. Manifest is re-saved if
    /// anything changes; running again is a no-op.
    private func migrateLegacyFloorPlanIfNeeded(in project: inout Project,
                                                  projectDir: URL) {
        guard project.floorPlans.count == 1,
              let plan = project.floorPlans.first,
              plan.imageFilename == "plan.jpg" else {
            return
        }
        let legacyURL = projectDir.appending(path: "plan.jpg")
        let newFilename = Self.floorPlanImageFilename(for: plan.id)
        let newURL = projectDir.appending(path: newFilename)
        let legacyExists = fileManager.fileExists(atPath: legacyURL.path())
        let newExists    = fileManager.fileExists(atPath: newURL.path())
        if legacyExists {
            do {
                try fileManager.moveItem(at: legacyURL, to: newURL)
            } catch {
                #if DEBUG
                print("Floor-plan migration: failed to rename \(legacyURL.lastPathComponent) → \(newFilename): \(error)")
                #endif
                return
            }
        } else if !newExists {
            // Manifest claims legacy filename but neither file is on
            // disk — leave the manifest alone so the user gets a
            // clearer "missing plan image" error rather than a silent
            // pointer to a fictional new file.
            return
        }
        project.floorPlans[0].imageFilename = newFilename

        // Stamp photos that already carry placement data with the
        // migrated plan's ID. Pre-migration photos always belonged to
        // the singular plan, so floorPlanID == nil + planPixelX/Y != nil
        // is unambiguous.
        for i in project.photos.indices {
            if project.photos[i].floorPlanID == nil
                && project.photos[i].planPixelX != nil
                && project.photos[i].planPixelY != nil {
                project.photos[i].floorPlanID = plan.id
            }
        }

        // Persist the updated manifest immediately so the next launch
        // sees the new shape.
        let manifest = projectDir.appending(path: "manifest.json")
        if let data = try? encoder().encode(project) {
            try? data.write(to: manifest, options: .atomic)
        }
    }

    @discardableResult
    func save(_ project: Project) -> Project {
        isSaving = true
        defer {
            isSaving = false
            lastSavedAt = Date()
        }
        let dir = projectURL(project)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: photosFolder(for: project), withIntermediateDirectories: true)
        let manifest = manifestURL(for: project)
        do {
            let data = try encoder().encode(project)
            try data.write(to: manifest, options: .atomic)
        } catch {
            #if DEBUG
            print("Failed to save project: \(error)")
            #endif
        }
        commitInMemory(project)
        checkForUnresolvedConflicts(at: manifest, projectName: project.name)
        onAfterSave?(project)
        return project
    }

    /// Update the in-memory `activeProjects` / `deletedProjects` arrays
    /// without touching disk. Lets long-running batch flows (e.g. AI
    /// tagging) accumulate many per-photo mutations and flush them with
    /// a single `save(_:)` at checkpoints instead of paying the full
    /// project-encode + atomic-write cost on every photo.
    private func commitInMemory(_ project: Project) {
        // Keep existing projects in their current list; new projects go into
        // Active Projects.
        if let idx = activeProjects.firstIndex(where: { $0.id == project.id }) {
            activeProjects[idx] = project
        } else if let idx = deletedProjects.firstIndex(where: { $0.id == project.id }) {
            deletedProjects[idx] = project
        } else {
            activeProjects.insert(project, at: 0)
        }
    }

    /// Apply a server-pulled project to the local store. Writes the
    /// manifest to disk in the project's folder (creating the folder
    /// structure if needed) and updates the in-memory list. **Does
    /// NOT call `onAfterSave`** — this is a pull from the server, not
    /// a local edit; firing the save hook would echo the same data
    /// straight back as a push and loop.
    ///
    /// Called by `ManifestSyncer.pullAllFromServer()` for projects
    /// whose server revision differs from the locally-cached one
    /// AND that aren't dirty (have no unsynced local edits).
    /// Replace the on-disk tag library + in-memory state with a value
    /// pulled from the server. Skips the change hook so a pull
    /// doesn't bounce back as a push (same discipline
    /// `applyServerProject` follows for manifests).
    func applyServerTagLibrary(_ library: TagLibrary) {
        tagLibrary = library
        if let data = try? encoder().encode(tagLibrary) {
            try? data.write(to: tagLibraryURL, options: .atomic)
        }
    }

    /// Replace the on-disk AI rules template + in-memory state with a
    /// value pulled from the server. Same pull-doesn't-echo
    /// discipline as `applyServerTagLibrary`.
    func applyServerAIRulesTemplate(_ text: String) {
        aiRulesTemplate = text
        if let data = aiRulesTemplate.data(using: .utf8) {
            try? data.write(to: aiRulesTemplateURL, options: .atomic)
        }
    }

    func applyServerProject(_ project: Project) {
        let dir = projectURL(project)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: photosFolder(for: project),
                                          withIntermediateDirectories: true)
        let manifest = manifestURL(for: project)
        do {
            let data = try encoder().encode(project)
            try data.write(to: manifest, options: .atomic)
        } catch {
            #if DEBUG
            print("applyServerProject failed to write manifest: \(error)")
            #endif
            return
        }
        commitInMemory(project)
        lastSavedAt = Date()
    }

    /// Surface a toast when iCloud reports the project manifest has been
    /// edited from two devices since the last sync. Auto-resolution
    /// (`removeOtherVersionsOfItem`) is offered as the toast's action —
    /// iCloud always preserves the winning local copy, so accepting just
    /// clears the conflict markers and keeps what's on this device.
    private func checkForUnresolvedConflicts(at url: URL, projectName: String) {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty,
              let toast = toastCenter else { return }
        let count = conflicts.count
        let message = count == 1
            ? "iCloud detected another edit of \"\(projectName)\" from a different device. The local version is shown."
            : "iCloud detected \(count) other edits of \"\(projectName)\" from different devices. The local version is shown."
        // ToastCenter is `@MainActor`; the surrounding save path is not.
        // Hop explicitly so the actor-isolation check is satisfied and the
        // toast renders on the right thread.
        Task { @MainActor in
            toast.post(message,
                       kind: .warning,
                       actionTitle: "Keep Local") {
                for version in conflicts {
                    version.isResolved = true
                }
                try? NSFileVersion.removeOtherVersionsOfItem(at: url)
            }
        }
    }

    /// Soft delete: move the project's folder from "Active Projects" to
    /// "Deleted Projects" so the data stays available for recovery. The
    /// permanent purge happens in `permanentlyDelete(_)`.
    ///
    /// Sets `project.isDeleted = true` and saves before the folder move
    /// so the manifest pushed to the server (via `save(_:)` → onAfterSave
    /// → SyncCoordinator) carries the trashed state. Without this, the
    /// web client would keep showing the project because the server
    /// only sees a stale manifest where isDeleted is still false.
    func delete(_ project: Project) {
        // 1. Mark deleted on the manifest + save, which triggers the
        //    server push via onAfterSave. The save writes to the
        //    project's current location (the active folder); the
        //    server gets the manifest with isDeleted=true.
        var deletedManifest = project
        deletedManifest.isDeleted = true
        save(deletedManifest)

        // 2. Now move the folder on disk + update in-memory arrays.
        let idPrefix = String(project.id.uuidString.lowercased().prefix(6))
        let fullUUID = project.id.uuidString.lowercased()

        moveMatchingFolders(idPrefix: idPrefix, fullUUID: fullUUID,
                            from: activeRoot, to: deletedRoot)
        if usingICloud {
            moveMatchingFolders(
                idPrefix: idPrefix, fullUUID: fullUUID,
                from: Self.localProjectsURL.appending(path: Self.activeFolderName, directoryHint: .isDirectory),
                to:   Self.localProjectsURL.appending(path: Self.deletedFolderName, directoryHint: .isDirectory)
            )
        }

        activeProjects.removeAll { $0.id == project.id }
        if !deletedProjects.contains(where: { $0.id == deletedManifest.id }) {
            deletedProjects.insert(deletedManifest, at: 0)
        }
    }

    /// Restore a soft-deleted project — move its folder from "Deleted
    /// Projects" back to "Active Projects". Mirrors `delete(_:)`:
    /// flips `isDeleted` back to false and saves so the server's
    /// manifest reflects the restored state.
    func restore(_ project: Project) {
        // 1. Flip the flag + save (pushes manifest with isDeleted=false
        //    to the server). Note: this save writes to the project's
        //    current location, which is the deleted folder. The move
        //    in step 2 carries the freshly-written manifest along.
        var restoredManifest = project
        restoredManifest.isDeleted = false
        save(restoredManifest)

        // 2. Move folder back to active + update in-memory arrays.
        let idPrefix = String(project.id.uuidString.lowercased().prefix(6))
        let fullUUID = project.id.uuidString.lowercased()

        moveMatchingFolders(idPrefix: idPrefix, fullUUID: fullUUID,
                            from: deletedRoot, to: activeRoot)
        if usingICloud {
            moveMatchingFolders(
                idPrefix: idPrefix, fullUUID: fullUUID,
                from: Self.localProjectsURL.appending(path: Self.deletedFolderName, directoryHint: .isDirectory),
                to:   Self.localProjectsURL.appending(path: Self.activeFolderName, directoryHint: .isDirectory)
            )
        }

        deletedProjects.removeAll { $0.id == project.id }
        if !activeProjects.contains(where: { $0.id == restoredManifest.id }) {
            activeProjects.insert(restoredManifest, at: 0)
        }
    }

    /// Permanently remove every folder for this project — from both
    /// Active/Deleted in the active root and the legacy local root.
    func permanentlyDelete(_ project: Project) {
        let idPrefix = String(project.id.uuidString.lowercased().prefix(6))
        let fullUUID = project.id.uuidString.lowercased()

        removeMatchingFolders(idPrefix: idPrefix, fullUUID: fullUUID, under: activeRoot)
        removeMatchingFolders(idPrefix: idPrefix, fullUUID: fullUUID, under: deletedRoot)
        if usingICloud {
            removeMatchingFolders(
                idPrefix: idPrefix, fullUUID: fullUUID,
                under: Self.localProjectsURL.appending(path: Self.activeFolderName, directoryHint: .isDirectory)
            )
            removeMatchingFolders(
                idPrefix: idPrefix, fullUUID: fullUUID,
                under: Self.localProjectsURL.appending(path: Self.deletedFolderName, directoryHint: .isDirectory)
            )
        }

        activeProjects.removeAll { $0.id == project.id }
        deletedProjects.removeAll { $0.id == project.id }
    }

    private func moveMatchingFolders(idPrefix: String, fullUUID: String,
                                      from src: URL, to dst: URL) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: src,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        try? fileManager.createDirectory(at: dst, withIntermediateDirectories: true)

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let nameLower = entry.lastPathComponent.lowercased()
            guard nameLower.hasSuffix("_\(idPrefix)") || nameLower == fullUUID else { continue }
            let target = dst.appending(path: entry.lastPathComponent, directoryHint: .isDirectory)
            coordinatedMove(from: entry, to: target)
        }
    }

    private func removeMatchingFolders(idPrefix: String, fullUUID: String, under root: URL) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let nameLower = entry.lastPathComponent.lowercased()
            guard nameLower.hasSuffix("_\(idPrefix)") || nameLower == fullUUID else { continue }
            coordinatedRemove(entry)
        }
    }

    /// File-coordinated move (for iCloud safety). If a folder already exists
    /// at the destination it is removed first so the move can proceed.
    private func coordinatedMove(from src: URL, to dst: URL) {
        if fileManager.fileExists(atPath: dst.path()) {
            coordinatedRemove(dst)
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(
            writingItemAt: src, options: .forMoving,
            writingItemAt: dst, options: .forReplacing,
            error: &coordError
        ) { newSrc, newDst in
            do {
                try fileManager.moveItem(at: newSrc, to: newDst)
            } catch {
                #if DEBUG
                print("coordinated move failed \(newSrc.lastPathComponent) → \(newDst.lastPathComponent): \(error)")
                #endif
            }
        }
        if let coordError {
            #if DEBUG
            print("move coordination failed for \(src.lastPathComponent): \(coordError)")
            #endif
            try? fileManager.moveItem(at: src, to: dst)
        }
    }

    /// Use NSFileCoordinator so the iCloud sync daemon registers the delete
    /// and won't push the folder back. Falls back to a direct remove if
    /// coordination itself fails.
    private func coordinatedRemove(_ url: URL) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { newURL in
            do {
                try fileManager.removeItem(at: newURL)
            } catch {
                #if DEBUG
                print("coordinated removeItem failed at \(newURL.lastPathComponent): \(error)")
                #endif
            }
        }
        if let coordError {
            #if DEBUG
            print("file coordination failed for \(url.lastPathComponent): \(coordError)")
            #endif
            try? fileManager.removeItem(at: url)
        }
    }

    func project(withID id: UUID) -> Project? {
        activeProjects.first { $0.id == id } ?? deletedProjects.first { $0.id == id }
    }

    // MARK: - Session lifecycle

    @discardableResult
    func startSession(_ project: Project) -> Project {
        var p = project
        if p.startedAt == nil {
            p.startedAt = Date()
        } else {
            p.lastResumedAt = Date()
        }
        p.stopped = false
        return save(p)
    }

    @discardableResult
    func stopSession(_ project: Project) -> Project {
        var p = project
        p.stopped = true
        p.lastStoppedAt = Date()
        return save(p)
    }

    @discardableResult
    func updateGPS(_ project: Project, _ gps: ProjectGPS) -> Project {
        var p = project
        p.projectGPS = gps
        return save(p)
    }

    @discardableResult
    func updateAddress(_ project: Project, _ address: String) -> Project {
        var p = project
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        p.projectAddress = trimmed.isEmpty ? nil : trimmed
        return save(p)
    }

    // MARK: - Floor plans (multi-plan)

    /// Disk filename for a plan's rasterised image. UUID-prefixed so
    /// multiple plans coexist in one project folder without collision.
    private static func floorPlanImageFilename(for planID: UUID) -> String {
        let prefix = planID.uuidString.lowercased().prefix(8)
        return "plan-\(prefix).jpg"
    }

    /// Suggest a label for the next plan being added to `project`,
    /// e.g. "Plan 1" / "Plan 2" / ... Skips numbers already in use so
    /// reorder + delete don't collide.
    private func suggestedNextPlanLabel(for project: Project) -> String {
        let used = Set(project.floorPlans.map { $0.label })
        for n in 1...999 {
            let candidate = "Plan \(n)"
            if !used.contains(candidate) { return candidate }
        }
        return "Plan"
    }

    /// Add a brand-new floor plan to the project. Used by both the
    /// initial setup flow (when `project.floorPlans` is empty) and the
    /// "+ Add Floor Plan" affordance in the multi-plan UI (P2).
    /// The new plan becomes the active plan.
    @discardableResult
    func addFloorPlan(
        to project: Project,
        label customLabel: String? = nil,
        imageData: Data,
        anchorPixelX: Double,
        anchorPixelY: Double,
        pixelsPerFoot: Double,
        calibrationDistanceFeet: Double,
        northDeg: Double
    ) throws -> (project: Project, plan: FloorPlan) {
        var p = project
        let dir = projectURL(p)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let planID = UUID()
        let filename = Self.floorPlanImageFilename(for: planID)
        let url = dir.appending(path: filename)
        try? fileManager.removeItem(at: url)
        try imageData.write(to: url, options: .atomic)

        let trimmed = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (trimmed?.isEmpty == false ? trimmed! : suggestedNextPlanLabel(for: p))
        let plan = FloorPlan(
            id: planID,
            label: label,
            imageFilename: filename,
            pixelsPerFoot: pixelsPerFoot,
            calibrationDistanceFeet: calibrationDistanceFeet,
            anchorPixelX: anchorPixelX,
            anchorPixelY: anchorPixelY,
            anchorLocalXFeet: 0,
            anchorLocalYFeet: 0,
            northDeg: northDeg
        )
        p.floorPlans.append(plan)
        p.activeFloorPlanID = planID

        // If any photos already carry localXFeet/Y (e.g. they were
        // orphaned when a previous plan was deleted), project them onto
        // the new plan so they reappear at the equivalent real-world
        // spot. Photos without local coords are unaffected.
        Self.recomputePixelCoords(in: &p, planID: planID, onlyOrphans: true)

        let saved = save(p)
        return (saved, plan)
    }

    /// Remove a single plan. Photos whose `floorPlanID == planID` have
    /// their `floorPlanID` and `planPixelX/Y` cleared, but their
    /// `localXFeet/Y` is preserved — the engineer's intent (per the
    /// plan deletion question) is that a future plan added with origin
    /// + scale should be able to recompute pixel positions automatically.
    @discardableResult
    func removeFloorPlan(_ project: Project, planID: UUID) -> Project {
        var p = project
        guard let idx = p.floorPlans.firstIndex(where: { $0.id == planID }) else {
            return p
        }
        let plan = p.floorPlans[idx]
        let url = projectURL(p).appending(path: plan.imageFilename)
        try? fileManager.removeItem(at: url)
        p.floorPlans.remove(at: idx)

        // Detach photos. Keep localXFeet/Y so a future plan can re-derive.
        for i in p.photos.indices where p.photos[i].floorPlanID == planID {
            p.photos[i].floorPlanID = nil
            p.photos[i].planPixelX = nil
            p.photos[i].planPixelY = nil
        }

        // If the removed plan was active, fall back to the first
        // remaining plan (or nil if there are none left).
        if p.activeFloorPlanID == planID {
            p.activeFloorPlanID = p.floorPlans.first?.id
        }
        return save(p)
    }

    /// Rename a plan. No-op when `planID` doesn't resolve or the
    /// trimmed label is empty.
    @discardableResult
    func renameFloorPlan(_ project: Project, planID: UUID, label: String) -> Project {
        var p = project
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = p.floorPlans.firstIndex(where: { $0.id == planID }) else {
            return p
        }
        p.floorPlans[idx].label = trimmed
        return save(p)
    }

    func reorderFloorPlans(_ project: Project,
                            from source: IndexSet,
                            to destination: Int) -> Project {
        var p = project
        p.floorPlans.move(fromOffsets: source, toOffset: destination)
        return save(p)
    }

    /// Set the "sticky" active plan. Pass `nil` to clear (falls back to
    /// the first plan via the `Project.floorPlan` accessor).
    @discardableResult
    func setActiveFloorPlan(_ project: Project, planID: UUID?) -> Project {
        var p = project
        if let planID, p.floorPlans.contains(where: { $0.id == planID }) {
            p.activeFloorPlanID = planID
        } else {
            p.activeFloorPlanID = nil
        }
        return save(p)
    }

    /// Replace the image of an existing plan. Photo `planPixelX/Y`
    /// values for photos on this plan are recomputed from their
    /// `localXFeet/Y` so they land at the same real-world position on
    /// the new image. Old image file is deleted.
    @discardableResult
    func replaceFloorPlan(in project: Project,
                           planID: UUID,
                           imageData: Data,
                           pixelsPerFoot: Double,
                           calibrationDistanceFeet: Double,
                           anchorPixelX: Double,
                           anchorPixelY: Double,
                           northDeg: Double) throws -> Project {
        var p = project
        guard let idx = p.floorPlans.firstIndex(where: { $0.id == planID }) else {
            return p
        }

        // Ensure photos on this plan have fresh local coords against
        // the OLD calibration before we swap calibration.
        Self.recomputeLocalCoords(in: &p, planID: planID)

        let dir = projectURL(p)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldFilename = p.floorPlans[idx].imageFilename
        let oldURL = dir.appending(path: oldFilename)
        try? fileManager.removeItem(at: oldURL)
        let newFilename = Self.floorPlanImageFilename(for: planID)
        let newURL = dir.appending(path: newFilename)
        try imageData.write(to: newURL, options: .atomic)

        var plan = p.floorPlans[idx]
        plan.imageFilename = newFilename
        plan.pixelsPerFoot = pixelsPerFoot
        plan.calibrationDistanceFeet = calibrationDistanceFeet
        plan.anchorPixelX = anchorPixelX
        plan.anchorPixelY = anchorPixelY
        plan.anchorLocalXFeet = 0
        plan.anchorLocalYFeet = 0
        plan.northDeg = northDeg
        p.floorPlans[idx] = plan

        // Project photo positions onto the new image.
        Self.recomputePixelCoords(in: &p, planID: planID)
        return save(p)
    }

    /// URL for a specific plan's rasterised image on disk.
    func floorPlanURL(for project: Project, planID: UUID) -> URL? {
        guard let plan = project.floorPlan(id: planID) else { return nil }
        return projectURL(project).appending(path: plan.imageFilename)
    }

    /// URL for a plan's rasterised image. Same as `floorPlanURL` but
    /// takes the `FloorPlan` directly so callers that already have
    /// one don't need to round-trip through `floorPlan(id:)`. Build
    /// #5.49.1 — used by `BinaryBackfillService` to know where to
    /// write a freshly-downloaded plan binary on disk.
    func planImageURL(for plan: FloorPlan, in project: Project) -> URL {
        projectURL(project).appending(path: plan.imageFilename)
    }

    /// Update calibration on a specific plan. Photo positions on this
    /// plan have their local coords re-derived so the readouts match.
    @discardableResult
    func updateFloorPlanOrigin(_ project: Project,
                                planID: UUID,
                                anchorPixelX: Double,
                                anchorPixelY: Double) -> Project {
        var p = project
        guard let idx = p.floorPlans.firstIndex(where: { $0.id == planID }) else {
            return p
        }
        p.floorPlans[idx].anchorPixelX = anchorPixelX
        p.floorPlans[idx].anchorPixelY = anchorPixelY
        Self.recomputeLocalCoords(in: &p, planID: planID)
        return save(p)
    }

    @discardableResult
    func recalibrateScale(_ project: Project,
                           planID: UUID,
                           pixelsPerFoot: Double,
                           calibrationDistanceFeet: Double) -> Project {
        var p = project
        guard let idx = p.floorPlans.firstIndex(where: { $0.id == planID }) else {
            return p
        }
        p.floorPlans[idx].pixelsPerFoot = pixelsPerFoot
        p.floorPlans[idx].calibrationDistanceFeet = calibrationDistanceFeet
        Self.recomputeLocalCoords(in: &p, planID: planID)
        return save(p)
    }

    @discardableResult
    func updateFloorPlanNorth(_ project: Project,
                                planID: UUID,
                                northDeg: Double) -> Project {
        var p = project
        guard let idx = p.floorPlans.firstIndex(where: { $0.id == planID }) else {
            return p
        }
        p.floorPlans[idx].northDeg = northDeg
        return save(p)
    }

    // MARK: - Distress marks

    @discardableResult
    func addDistress(_ project: Project,
                      planID: UUID,
                      mark: DistressMark) -> Project {
        var p = project
        guard let idx = p.floorPlans.firstIndex(where: { $0.id == planID }) else {
            return p
        }
        p.floorPlans[idx].distress.append(mark)
        return save(p)
    }

    @discardableResult
    func updateDistress(_ project: Project,
                         planID: UUID,
                         mark: DistressMark) -> Project {
        var p = project
        guard let planIdx = p.floorPlans.firstIndex(where: { $0.id == planID }),
              let markIdx = p.floorPlans[planIdx].distress.firstIndex(where: { $0.id == mark.id })
        else { return p }
        p.floorPlans[planIdx].distress[markIdx] = mark
        return save(p)
    }

    @discardableResult
    func removeDistress(_ project: Project,
                         planID: UUID,
                         markID: UUID) -> Project {
        var p = project
        guard let idx = p.floorPlans.firstIndex(where: { $0.id == planID }) else {
            return p
        }
        p.floorPlans[idx].distress.removeAll { $0.id == markID }
        return save(p)
    }

    /// Bulk variant — assign every photo in `photoIDs` to `planID` (or
    /// detach all of them with `nil`). Saves once instead of once per
    /// photo, so it stays fast on big imports. Mirrors
    /// `setPhotoFloorPlan` on the per-photo math: if the new plan has
    /// origin + scale and a photo already has saved `localXFeet/Y`,
    /// `planPixelX/Y` is derived automatically.
    @discardableResult
    func assignFloorPlan(_ project: Project,
                          photoIDs: Set<UUID>,
                          planID: UUID?) -> Project {
        guard !photoIDs.isEmpty else { return project }
        var p = project
        let plan = planID.flatMap { p.floorPlan(id: $0) }
        for i in p.photos.indices where photoIDs.contains(p.photos[i].id) {
            p.photos[i].floorPlanID = planID
            p.photos[i].planPixelX = nil
            p.photos[i].planPixelY = nil
            if let plan,
               let lx = p.photos[i].localXFeet,
               let ly = p.photos[i].localYFeet {
                p.photos[i].planPixelX = plan.anchorPixelX + lx * plan.pixelsPerFoot
                p.photos[i].planPixelY = plan.anchorPixelY + ly * plan.pixelsPerFoot
            }
        }
        return save(p)
    }

    /// Move a photo to a different plan (or detach with `nil`). When
    /// the new plan has origin + scale and the photo already has saved
    /// `localXFeet/Y`, pixel coords are derived automatically so the
    /// photo lands at the equivalent real-world spot without forcing
    /// the engineer to re-tap. Switching plans intentionally clears
    /// the previous `planPixelX/Y` (those were plan-specific).
    @discardableResult
    func setPhotoFloorPlan(_ project: Project,
                            photoID: UUID,
                            planID: UUID?) -> Project {
        var p = project
        guard let pIdx = p.photos.firstIndex(where: { $0.id == photoID }) else {
            return p
        }
        p.photos[pIdx].floorPlanID = planID
        p.photos[pIdx].planPixelX = nil
        p.photos[pIdx].planPixelY = nil
        if let planID,
           let plan = p.floorPlan(id: planID),
           let lx = p.photos[pIdx].localXFeet,
           let ly = p.photos[pIdx].localYFeet {
            p.photos[pIdx].planPixelX = plan.anchorPixelX + lx * plan.pixelsPerFoot
            p.photos[pIdx].planPixelY = plan.anchorPixelY + ly * plan.pixelsPerFoot
        }
        return save(p)
    }

    // MARK: - Floor plan (backward-compat shims operating on active plan)

    /// Shim — `FloorPlanSetupView`'s "first plan" call path. Adds a new
    /// plan with the default `"Plan N"` label. Multi-plan UI in P2 uses
    /// `addFloorPlan(to:label:imageData:…)` directly so the engineer
    /// can name the plan up front.
    @discardableResult
    func saveFloorPlan(
        to project: Project,
        imageData: Data,
        anchorPixelX: Double,
        anchorPixelY: Double,
        pixelsPerFoot: Double,
        calibrationDistanceFeet: Double,
        northDeg: Double
    ) throws -> Project {
        try addFloorPlan(
            to: project,
            label: nil,
            imageData: imageData,
            anchorPixelX: anchorPixelX,
            anchorPixelY: anchorPixelY,
            pixelsPerFoot: pixelsPerFoot,
            calibrationDistanceFeet: calibrationDistanceFeet,
            northDeg: northDeg
        ).project
    }

    /// Shim — removes the active plan (legacy "there's only one plan"
    /// behaviour).
    @discardableResult
    func clearFloorPlan(_ project: Project) -> Project {
        guard let planID = project.floorPlan?.id else { return project }
        return removeFloorPlan(project, planID: planID)
    }

    /// Shim — URL for the active plan's image. Returns nil when the
    /// project has no plans.
    func floorPlanURL(for project: Project) -> URL? {
        guard let planID = project.floorPlan?.id else { return nil }
        return floorPlanURL(for: project, planID: planID)
    }

    /// Shim — operates on the active plan.
    @discardableResult
    func updateFloorPlanOrigin(_ project: Project,
                                anchorPixelX: Double,
                                anchorPixelY: Double) -> Project {
        guard let planID = project.floorPlan?.id else { return project }
        return updateFloorPlanOrigin(project,
                                       planID: planID,
                                       anchorPixelX: anchorPixelX,
                                       anchorPixelY: anchorPixelY)
    }

    @discardableResult
    func recalibrateScale(_ project: Project,
                           pixelsPerFoot: Double,
                           calibrationDistanceFeet: Double) -> Project {
        guard let planID = project.floorPlan?.id else { return project }
        return recalibrateScale(project,
                                  planID: planID,
                                  pixelsPerFoot: pixelsPerFoot,
                                  calibrationDistanceFeet: calibrationDistanceFeet)
    }

    @discardableResult
    func updateFloorPlanNorth(_ project: Project, northDeg: Double) -> Project {
        guard let planID = project.floorPlan?.id else { return project }
        return updateFloorPlanNorth(project, planID: planID, northDeg: northDeg)
    }

    /// Shim — replaces the active plan with a new image + calibration.
    /// `FloorPlanReplaceView` keeps calling this; P2 adds an explicit
    /// per-plan replace flow when needed.
    @discardableResult
    func replaceFloorPlan(in project: Project,
                           imageData: Data,
                           pixelsPerFoot: Double,
                           calibrationDistanceFeet: Double,
                           anchorPixelX: Double,
                           anchorPixelY: Double,
                           northDeg: Double) throws -> Project {
        guard let planID = project.floorPlan?.id else {
            // No existing plan to replace — fall through to "add a new
            // plan" so the existing single-plan replace flow still
            // works on a project that somehow lost its plans.
            return try addFloorPlan(
                to: project,
                label: nil,
                imageData: imageData,
                anchorPixelX: anchorPixelX,
                anchorPixelY: anchorPixelY,
                pixelsPerFoot: pixelsPerFoot,
                calibrationDistanceFeet: calibrationDistanceFeet,
                northDeg: northDeg
            ).project
        }
        return try replaceFloorPlan(
            in: project,
            planID: planID,
            imageData: imageData,
            pixelsPerFoot: pixelsPerFoot,
            calibrationDistanceFeet: calibrationDistanceFeet,
            anchorPixelX: anchorPixelX,
            anchorPixelY: anchorPixelY,
            northDeg: northDeg
        )
    }

    // MARK: - Floor plan helpers (private)

    /// Derive `localXFeet/Y` from `planPixelX/Y` for every photo on the
    /// given plan. Scoped to one plan so re-calibrating one plan
    /// doesn't disturb photos placed on another plan.
    private static func recomputeLocalCoords(in project: inout Project, planID: UUID) {
        guard let plan = project.floorPlan(id: planID) else { return }
        for i in project.photos.indices where project.photos[i].floorPlanID == planID {
            let photo = project.photos[i]
            guard let px = photo.planPixelX, let py = photo.planPixelY else { continue }
            project.photos[i].localXFeet = (px - plan.anchorPixelX) / plan.pixelsPerFoot
            project.photos[i].localYFeet = (py - plan.anchorPixelY) / plan.pixelsPerFoot
        }
    }

    /// Derive `planPixelX/Y` from `localXFeet/Y` for photos on the
    /// given plan. When `onlyOrphans` is true, also attaches photos
    /// whose `floorPlanID == nil` AND who have saved `localXFeet/Y` —
    /// used by `addFloorPlan` so orphaned photos auto-attach to a
    /// fresh plan with matching real-world geometry.
    private static func recomputePixelCoords(in project: inout Project,
                                               planID: UUID,
                                               onlyOrphans: Bool = false) {
        guard let plan = project.floorPlan(id: planID) else { return }
        for i in project.photos.indices {
            let photo = project.photos[i]
            let isOnThisPlan = photo.floorPlanID == planID
            let isAdoptableOrphan = onlyOrphans
                && photo.floorPlanID == nil
                && photo.localXFeet != nil
                && photo.localYFeet != nil
            guard isOnThisPlan || isAdoptableOrphan else { continue }
            guard let lx = photo.localXFeet, let ly = photo.localYFeet else { continue }
            if isAdoptableOrphan {
                project.photos[i].floorPlanID = planID
            }
            project.photos[i].planPixelX = plan.anchorPixelX + lx * plan.pixelsPerFoot
            project.photos[i].planPixelY = plan.anchorPixelY + ly * plan.pixelsPerFoot
        }
    }

    // MARK: - Photos

    /// Optional location data attached when a photo is saved against a calibrated plan.
    /// `floorPlanID` defaults to `nil` so memberwise-init callers that
    /// don't yet thread the plan ID still compile (the back-compat
    /// path captures against the project's currently-active plan).
    struct PhotoLocation {
        var floorPlanID: UUID? = nil
        var planPixelX: Double
        var planPixelY: Double
        var localXFeet: Double
        var localYFeet: Double
        var headingDegrees: Double?
        var groupID: UUID?
        var isPrimary: Bool
    }

    /// Persist a captured photo to disk and append it to the project. Returns the updated project.
    @discardableResult
    func addPhoto(to project: Project, captured: CapturedPhoto, location: PhotoLocation? = nil) throws -> Project {
        var p = project
        let photosFolder = photosFolder(for: p)
        let thumbsFolder = thumbnailsFolder(for: p)
        try fileManager.createDirectory(at: photosFolder, withIntermediateDirectories: true)

        let photoID = UUID()
        let seq = p.photos.count + 1
        let now = Date()
        let imageName = Self.makePhotoFilename(sequenceNumber: seq, timestamp: now, projectName: p.name)
        let imageURL = photosFolder.appending(path: imageName)
        try captured.data.write(to: imageURL, options: .atomic)

        var thumbName: String?
        if let thumb = Self.makeThumbnail(from: captured.data, maxPixelSize: 256) {
            try? fileManager.createDirectory(at: thumbsFolder, withIntermediateDirectories: true)
            let n = "thumb_\(imageName)"
            let url = thumbsFolder.appending(path: n)
            try? thumb.write(to: url, options: .atomic)
            thumbName = n
        }

        var photo = Photo(id: photoID, sequenceNumber: seq, imageFilename: imageName)
        photo.timestamp = now
        photo.thumbnailFilename = thumbName
        photo.cameraZoom = captured.userZoom
        photo.lensName = captured.lensName
        photo.flashMode = captured.flashMode

        if let loc = location {
            photo.floorPlanID = loc.floorPlanID
            photo.planPixelX = loc.planPixelX
            photo.planPixelY = loc.planPixelY
            photo.localXFeet = loc.localXFeet
            photo.localYFeet = loc.localYFeet
            photo.headingDegrees = loc.headingDegrees
            photo.groupID = loc.groupID
            photo.isPrimary = loc.isPrimary
            photo.positionSource = .manual
        }

        p.photos.append(photo)
        return save(p)
    }

    func imageURL(for photo: Photo, in project: Project) -> URL {
        photosFolder(for: project).appending(path: photo.imageFilename)
    }

    func thumbnailURL(for photo: Photo, in project: Project) -> URL? {
        guard let name = photo.thumbnailFilename else { return nil }
        return thumbnailsFolder(for: project).appending(path: name)
    }

    // MARK: - Photo import (from Photos library / Files)

    /// Save an externally-sourced JPEG/HEIC into the project. Same naming and
    /// thumbnail behaviour as a camera capture, but the timestamp comes from
    /// the source EXIF/TIFF data when available so the filename reflects the
    /// real capture time rather than today's date.
    @discardableResult
    func importPhoto(to project: Project, imageData: Data, capturedAt: Date) throws -> Project {
        var p = project
        let photosFolder = photosFolder(for: p)
        let thumbsFolder = thumbnailsFolder(for: p)
        try fileManager.createDirectory(at: photosFolder, withIntermediateDirectories: true)

        let photoID = UUID()
        let seq = p.photos.count + 1
        let imageName = Self.makePhotoFilename(sequenceNumber: seq, timestamp: capturedAt, projectName: p.name)
        let imageURL = photosFolder.appending(path: imageName)
        try imageData.write(to: imageURL, options: .atomic)

        var thumbName: String?
        if let thumb = Self.makeThumbnail(from: imageData, maxPixelSize: 256) {
            try? fileManager.createDirectory(at: thumbsFolder, withIntermediateDirectories: true)
            let n = "thumb_\(imageName)"
            let url = thumbsFolder.appending(path: n)
            try? thumb.write(to: url, options: .atomic)
            thumbName = n
        }

        var photo = Photo(id: photoID, sequenceNumber: seq, imageFilename: imageName)
        photo.timestamp = capturedAt
        photo.thumbnailFilename = thumbName
        photo.cameraZoom = 1.0
        photo.lensName = "imported"
        photo.flashMode = .off

        p.photos.append(photo)
        return save(p)
    }

    /// Pull DateTimeOriginal (or TIFF DateTime) out of an image's metadata.
    /// Returns nil when the source has no usable date — caller should fall
    /// back to Date().
    static func extractCaptureDate(from imageData: Data) -> Date? {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current

        if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
           let d = formatter.date(from: s) {
            return d
        }
        if let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let s = tiff[kCGImagePropertyTIFFDateTime as String] as? String,
           let d = formatter.date(from: s) {
            return d
        }
        return nil
    }

    // MARK: - Photo location updates

    /// Set or replace the plan-pixel location of an existing photo,
    /// scoped to a specific plan. Also re-derives `localXFeet/Y` from
    /// that plan's calibration. When `planID` is nil, the location is
    /// applied against the project's currently-active plan (back-compat
    /// for callers that haven't been migrated).
    @discardableResult
    func setPhotoLocation(_ project: Project,
                          photoID: UUID,
                          planID: UUID? = nil,
                          planPixelX: Double,
                          planPixelY: Double,
                          headingDegrees: Double?) -> Project {
        var p = project
        let resolvedPlan: FloorPlan?
        if let planID, let plan = p.floorPlan(id: planID) {
            resolvedPlan = plan
        } else {
            resolvedPlan = p.floorPlan
        }
        guard let plan = resolvedPlan,
              let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        p.photos[idx].floorPlanID = plan.id
        p.photos[idx].planPixelX = planPixelX
        p.photos[idx].planPixelY = planPixelY
        p.photos[idx].localXFeet = (planPixelX - plan.anchorPixelX) / plan.pixelsPerFoot
        p.photos[idx].localYFeet = (planPixelY - plan.anchorPixelY) / plan.pixelsPerFoot
        p.photos[idx].headingDegrees = headingDegrees
        p.photos[idx].positionSource = .manual
        // A re-located photo is always treated as a standalone marker — don't
        // tail off some other group's lead just because it shares a groupID.
        p.photos[idx].groupID = nil
        p.photos[idx].isPrimary = false
        return save(p)
    }

    /// Attach `photoID` as a tail of `leadPhotoID`'s group. The photo inherits
    /// the lead's plan position; if the lead doesn't yet have a groupID, a new
    /// one is minted and the lead is marked as the group's primary. Used by
    /// the Locate / Change-Location flow's "Group with another photo" option.
    @discardableResult
    func attachToGroup(_ project: Project, photoID: UUID, leadPhotoID: UUID) -> Project {
        var p = project
        guard let leadIdx = p.photos.firstIndex(where: { $0.id == leadPhotoID }),
              let joinIdx = p.photos.firstIndex(where: { $0.id == photoID }),
              leadPhotoID != photoID,
              let lpx = p.photos[leadIdx].planPixelX,
              let lpy = p.photos[leadIdx].planPixelY else { return p }
        // Use the lead's plan (not the project's active plan) — the
        // lead might live on a different plan than the one the engineer
        // is currently viewing in another sheet, and the joiner should
        // adopt whatever plan the lead is on.
        let leadPlanID = p.photos[leadIdx].floorPlanID
        guard let plan = leadPlanID.flatMap({ p.floorPlan(id: $0) }) ?? p.floorPlan else {
            return p
        }

        let gid: UUID
        if let existing = p.photos[leadIdx].groupID {
            gid = existing
        } else {
            gid = UUID()
            p.photos[leadIdx].groupID = gid
            p.photos[leadIdx].isPrimary = true
        }

        p.photos[joinIdx].floorPlanID = plan.id
        p.photos[joinIdx].planPixelX = lpx
        p.photos[joinIdx].planPixelY = lpy
        p.photos[joinIdx].localXFeet = (lpx - plan.anchorPixelX) / plan.pixelsPerFoot
        p.photos[joinIdx].localYFeet = (lpy - plan.anchorPixelY) / plan.pixelsPerFoot
        // Tails don't carry a direction arrow — the lead owns the heading.
        p.photos[joinIdx].headingDegrees = nil
        p.photos[joinIdx].positionSource = .manual
        p.photos[joinIdx].groupID = gid
        p.photos[joinIdx].isPrimary = false

        return save(p)
    }

    /// Delete a single photo: remove its image + thumbnail from disk, drop
    /// it from the project's photos array, then renumber the remaining
    /// photos sequentially (1…N) — and rename their files on disk to match
    /// the new sequence numbers so the iCloud filenames stay consistent.
    @discardableResult
    func deletePhoto(_ project: Project, photoID: UUID) throws -> Project {
        return try deletePhotos(project, photoIDs: [photoID])
    }

    /// Soft-delete every photo in `photoIDs`: move them from
    /// `project.photos` into `project.trashedPhotos` with a `trashedAt`
    /// timestamp, then renumber the survivors so the active sequence
    /// stays contiguous (1…N). Image + thumbnail files stay on disk so
    /// restore is cheap; permanent removal happens in
    /// `permanentlyDeleteFromTrash(_:photoIDs:)` and the auto-purge.
    func deletePhotos(_ project: Project, photoIDs: Set<UUID>) throws -> Project {
        var p = project
        guard !photoIDs.isEmpty else { return p }

        let photosDir = photosFolder(for: p)
        let thumbsDir = thumbnailsFolder(for: p)

        let removed = p.photos.filter { photoIDs.contains($0.id) }
        guard !removed.isEmpty else { return p }
        p.photos.removeAll { photoIDs.contains($0.id) }

        let now = Date()
        for var photo in removed {
            photo.trashedAt = now
            p.trashedPhotos.append(photo)
        }

        for i in p.photos.indices {
            let oldSeq = p.photos[i].sequenceNumber
            let newSeq = i + 1
            guard oldSeq != newSeq else { continue }

            let timestamp = p.photos[i].timestamp
            let newImageName = Self.makePhotoFilename(
                sequenceNumber: newSeq,
                timestamp: timestamp,
                projectName: p.name
            )

            let oldImageURL = photosDir.appending(path: p.photos[i].imageFilename)
            let newImageURL = photosDir.appending(path: newImageName)
            try? fileManager.moveItem(at: oldImageURL, to: newImageURL)
            p.photos[i].imageFilename = newImageName

            if let oldThumb = p.photos[i].thumbnailFilename {
                let newThumb = "thumb_\(newImageName)"
                let oldThumbURL = thumbsDir.appending(path: oldThumb)
                let newThumbURL = thumbsDir.appending(path: newThumb)
                try? fileManager.moveItem(at: oldThumbURL, to: newThumbURL)
                p.photos[i].thumbnailFilename = newThumb
            }

            p.photos[i].sequenceNumber = newSeq
        }

        return save(p)
    }

    /// Move trashed photos back into the live list. Each restored photo
    /// is appended at the end (its old sequence number is gone) and the
    /// `sequenceNumber` is reassigned to follow the current tail so the
    /// numbering remains 1…N without gaps. Files stay where they are;
    /// only the manifest moves the entries between arrays.
    @discardableResult
    func restorePhotos(_ project: Project, photoIDs: Set<UUID>) -> Project {
        var p = project
        guard !photoIDs.isEmpty else { return p }
        let restored = p.trashedPhotos.filter { photoIDs.contains($0.id) }
        guard !restored.isEmpty else { return p }
        p.trashedPhotos.removeAll { photoIDs.contains($0.id) }

        let photosDir = photosFolder(for: p)
        let thumbsDir = thumbnailsFolder(for: p)
        var nextSeq = (p.photos.map(\.sequenceNumber).max() ?? 0) + 1
        for var photo in restored {
            photo.trashedAt = nil
            // Rename the on-disk files to match the new sequence number
            // so iCloud doesn't keep stale filenames floating around.
            let newImageName = Self.makePhotoFilename(
                sequenceNumber: nextSeq,
                timestamp: photo.timestamp,
                projectName: p.name
            )
            let oldImageURL = photosDir.appending(path: photo.imageFilename)
            let newImageURL = photosDir.appending(path: newImageName)
            try? fileManager.moveItem(at: oldImageURL, to: newImageURL)
            photo.imageFilename = newImageName

            if let oldThumb = photo.thumbnailFilename {
                let newThumb = "thumb_\(newImageName)"
                let oldThumbURL = thumbsDir.appending(path: oldThumb)
                let newThumbURL = thumbsDir.appending(path: newThumb)
                try? fileManager.moveItem(at: oldThumbURL, to: newThumbURL)
                photo.thumbnailFilename = newThumb
            }
            photo.sequenceNumber = nextSeq
            p.photos.append(photo)
            nextSeq += 1
        }
        return save(p)
    }

    @discardableResult
    func restorePhoto(_ project: Project, photoID: UUID) -> Project {
        return restorePhotos(project, photoIDs: [photoID])
    }

    /// Re-sort the project's active photos in ascending `timestamp`
    /// order and reassign `sequenceNumber` to 1…N, renaming the
    /// on-disk image + thumbnail files to match. Every other field on
    /// each `Photo` — tags, AI analysis, bucket, plan position,
    /// heading, group membership, favorites, markup — is preserved
    /// untouched because none of them depend on sequence number
    /// (groupID / bucketID are UUIDs). Use this after importing older
    /// photos whose EXIF date is earlier than already-captured ones
    /// to get a chronological numbering back.
    @discardableResult
    func renumberPhotosByDate(_ project: Project) -> Project {
        var p = project
        guard p.photos.count > 1 else { return p }

        // Sort by timestamp; tie-break on current sequence so a stable
        // burst of same-second captures keeps its existing order.
        let sorted = p.photos.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.sequenceNumber < rhs.sequenceNumber
        }

        // No-op if already in order.
        let alreadyOrdered = sorted.enumerated().allSatisfy { idx, photo in
            photo.sequenceNumber == idx + 1
        }
        if alreadyOrdered { return p }

        let photosDir = photosFolder(for: p)
        let thumbsDir = thumbnailsFolder(for: p)

        // Two-pass rename so any photo's old name can collide with any
        // other photo's new name without clobbering. Pass 1 moves every
        // file to a UUID-suffixed temp name; pass 2 renames temps to
        // the canonical (project - seq - timestamp) filename.
        struct StagedRename {
            let tempImage: String
            let tempThumb: String?
        }
        var staged: [StagedRename] = []
        staged.reserveCapacity(sorted.count)

        for photo in sorted {
            let tempImage = "renumber_\(UUID().uuidString).jpg"
            let oldImageURL = photosDir.appending(path: photo.imageFilename)
            let stagingImageURL = photosDir.appending(path: tempImage)
            try? fileManager.moveItem(at: oldImageURL, to: stagingImageURL)

            var tempThumb: String? = nil
            if let oldThumb = photo.thumbnailFilename {
                let t = "renumber_\(UUID().uuidString).jpg"
                let oldThumbURL = thumbsDir.appending(path: oldThumb)
                let stagingThumbURL = thumbsDir.appending(path: t)
                try? fileManager.moveItem(at: oldThumbURL, to: stagingThumbURL)
                tempThumb = t
            }

            staged.append(StagedRename(tempImage: tempImage, tempThumb: tempThumb))
        }

        // Build the new photo list with updated sequence numbers +
        // canonical filenames. `sorted` and `staged` are index-aligned.
        var renumbered: [Photo] = []
        renumbered.reserveCapacity(staged.count)
        for (idx, entry) in staged.enumerated() {
            let newSeq = idx + 1
            var photo = sorted[idx]
            photo.sequenceNumber = newSeq

            let newImageName = Self.makePhotoFilename(
                sequenceNumber: newSeq,
                timestamp: photo.timestamp,
                projectName: p.name
            )
            let stagingImageURL = photosDir.appending(path: entry.tempImage)
            let newImageURL = photosDir.appending(path: newImageName)
            try? fileManager.moveItem(at: stagingImageURL, to: newImageURL)
            photo.imageFilename = newImageName

            if let tempThumb = entry.tempThumb {
                let newThumbName = "thumb_\(newImageName)"
                let stagingThumbURL = thumbsDir.appending(path: tempThumb)
                let newThumbURL = thumbsDir.appending(path: newThumbName)
                try? fileManager.moveItem(at: stagingThumbURL, to: newThumbURL)
                photo.thumbnailFilename = newThumbName
            }

            renumbered.append(photo)
        }

        p.photos = renumbered
        return save(p)
    }

    /// Permanently remove trashed photos: drop them from
    /// `project.trashedPhotos` and delete their image + thumbnail +
    /// markup files from disk. Cannot be undone — callers should
    /// confirm with the user first.
    @discardableResult
    func permanentlyDeleteFromTrash(_ project: Project,
                                      photoIDs: Set<UUID>) -> Project {
        var p = project
        guard !photoIDs.isEmpty else { return p }
        let photosDir = photosFolder(for: p)
        let thumbsDir = thumbnailsFolder(for: p)
        let markupsDir = markupsFolder(for: p)
        let removed = p.trashedPhotos.filter { photoIDs.contains($0.id) }
        guard !removed.isEmpty else { return p }
        p.trashedPhotos.removeAll { photoIDs.contains($0.id) }
        for photo in removed {
            try? fileManager.removeItem(at: photosDir.appending(path: photo.imageFilename))
            if let thumb = photo.thumbnailFilename {
                try? fileManager.removeItem(at: thumbsDir.appending(path: thumb))
            }
            if let markup = photo.markupOverlayFilename {
                try? fileManager.removeItem(at: markupsDir.appending(path: markup))
            }
            if let drawing = photo.markupDrawingFilename {
                try? fileManager.removeItem(at: markupsDir.appending(path: drawing))
            }
        }
        return save(p)
    }

    @discardableResult
    func emptyTrash(_ project: Project) -> Project {
        let ids = Set(project.trashedPhotos.map(\.id))
        return permanentlyDeleteFromTrash(project, photoIDs: ids)
    }

    /// Sweep every project for trashed photos older than `maxAge` and
    /// permanently delete them. Runs once at app launch from
    /// `loadInitial()` so the trash folder never grows without bound.
    /// Default age is 30 days, matching the user-facing copy in the UI.
    func purgeOldTrash(maxAge: TimeInterval = 30 * 86400) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        for project in activeProjects + deletedProjects {
            let ids = Set(project.trashedPhotos
                .filter { ($0.trashedAt ?? Date.distantFuture) < cutoff }
                .map(\.id))
            guard !ids.isEmpty else { continue }
            _ = permanentlyDeleteFromTrash(project, photoIDs: ids)
        }
    }

    // MARK: - AI notes (per-project)

    /// Set or clear the project's free-text AI notes (appended to the
    /// compiled prompt as "Additional notes for this project"). Pass
    /// `nil` or an all-whitespace string to clear.
    @discardableResult
    func setAIInstructions(_ project: Project, _ text: String?) -> Project {
        var p = project
        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            p.aiInstructions = t
        } else {
            p.aiInstructions = nil
        }
        return save(p)
    }

    // MARK: - Per-project extra vocabulary (Project.aiExtraVocabulary)

    /// Replace the entire `ProjectExtraVocabulary` for a project. Pass
    /// `nil` (or an empty list of primaries) to clear it. Used by the
    /// editor's bulk-load path; the granular add/rename/delete helpers
    /// below cover incremental edits.
    @discardableResult
    func setExtraVocabulary(_ project: Project,
                              _ extras: ProjectExtraVocabulary?) -> Project {
        var p = project
        if let extras, !extras.isEmpty {
            p.aiExtraVocabulary = extras
        } else {
            p.aiExtraVocabulary = nil
        }
        return save(p)
    }

    /// Append a new primary to the project's extras. Trims the name,
    /// ignores empty input, and returns the project unchanged in that
    /// case. The minted `PrimaryTagEntry` carries a fresh UUID so the
    /// editor's drill-down navigation can identify it by id.
    @discardableResult
    func addExtraPrimary(_ project: Project, name rawName: String) -> Project {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return project }
        var p = project
        var extras = p.aiExtraVocabulary ?? ProjectExtraVocabulary()
        extras.primaries.append(PrimaryTagEntry(name: name, secondaries: []))
        p.aiExtraVocabulary = extras
        return save(p)
    }

    @discardableResult
    func renameExtraPrimary(_ project: Project,
                              primaryID: UUID,
                              to rawName: String) -> Project {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return project }
        var p = project
        guard var extras = p.aiExtraVocabulary,
              let idx = extras.primaries.firstIndex(where: { $0.id == primaryID })
        else { return project }
        extras.primaries[idx].name = name
        p.aiExtraVocabulary = extras
        return save(p)
    }

    @discardableResult
    func deleteExtraPrimary(_ project: Project, primaryID: UUID) -> Project {
        var p = project
        guard var extras = p.aiExtraVocabulary else { return project }
        extras.primaries.removeAll { $0.id == primaryID }
        p.aiExtraVocabulary = extras.isEmpty ? nil : extras
        return save(p)
    }

    /// Reorder the project's extras primaries. Mirrors
    /// `ProjectStore.reorderTagPrimaries` semantics so the editor can
    /// expose `.onMove` from SwiftUI's edit mode.
    @discardableResult
    func reorderExtraPrimaries(_ project: Project,
                                 from source: IndexSet,
                                 to dest: Int) -> Project {
        var p = project
        guard var extras = p.aiExtraVocabulary else { return project }
        extras.primaries.move(fromOffsets: source, toOffset: dest)
        p.aiExtraVocabulary = extras
        return save(p)
    }

    @discardableResult
    func addExtraSecondary(_ project: Project,
                             primaryID: UUID,
                             name rawName: String) -> Project {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return project }
        var p = project
        guard var extras = p.aiExtraVocabulary,
              let idx = extras.primaries.firstIndex(where: { $0.id == primaryID })
        else { return project }
        extras.primaries[idx].secondaries.append(SecondaryTagEntry(name: name))
        p.aiExtraVocabulary = extras
        return save(p)
    }

    @discardableResult
    func renameExtraSecondary(_ project: Project,
                                primaryID: UUID,
                                secondaryID: UUID,
                                to rawName: String) -> Project {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return project }
        var p = project
        guard var extras = p.aiExtraVocabulary,
              let pIdx = extras.primaries.firstIndex(where: { $0.id == primaryID }),
              let sIdx = extras.primaries[pIdx].secondaries.firstIndex(where: { $0.id == secondaryID })
        else { return project }
        extras.primaries[pIdx].secondaries[sIdx].name = name
        p.aiExtraVocabulary = extras
        return save(p)
    }

    @discardableResult
    func deleteExtraSecondary(_ project: Project,
                                primaryID: UUID,
                                secondaryID: UUID) -> Project {
        var p = project
        guard var extras = p.aiExtraVocabulary,
              let pIdx = extras.primaries.firstIndex(where: { $0.id == primaryID })
        else { return project }
        extras.primaries[pIdx].secondaries.removeAll { $0.id == secondaryID }
        p.aiExtraVocabulary = extras
        return save(p)
    }

    @discardableResult
    func reorderExtraSecondaries(_ project: Project,
                                   primaryID: UUID,
                                   from source: IndexSet,
                                   to dest: Int) -> Project {
        var p = project
        guard var extras = p.aiExtraVocabulary,
              let pIdx = extras.primaries.firstIndex(where: { $0.id == primaryID })
        else { return project }
        extras.primaries[pIdx].secondaries.move(fromOffsets: source, toOffset: dest)
        p.aiExtraVocabulary = extras
        return save(p)
    }

    /// Heuristic: does this project's AI Notes text look like it's the
    /// stale legacy prompt that used to live in `Project.aiInstructions`
    /// before the rules-template refactor? Used by `AIInstructionsSheet`
    /// to surface a one-shot "These notes are bloated, want to clear
    /// them?" banner. Two signals — either is enough:
    ///   * length over 400 characters (the typical engineer-typed note
    ///     is well under this; the legacy default prompt was ~5,700)
    ///   * the text contains a phrase that only appeared in the legacy
    ///     `AIInstructions.defaultText` blob.
    ///
    /// Returns `nil` when notes look fine.
    func aiNotesBloatHint(for project: Project) -> AIInstructionsBloatHint? {
        let raw = project.aiInstructions ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let signatures = [
            "Controlled Primary and Secondary Tags",
            "Field definitions",
            "primary_tags: array of one or two Primary Tags",
            "secondary_tags_by_primary: object keyed by"
        ]
        let matchesSignature = signatures.contains { trimmed.contains($0) }
        guard trimmed.count > 400 || matchesSignature else { return nil }
        return AIInstructionsBloatHint(
            characterCount: trimmed.count,
            looksLikeLegacyDefault: matchesSignature
        )
    }
}

/// Returned by `ProjectStore.aiNotesBloatHint(for:)` when a project's
/// AI Notes look unusually large or like the legacy default prompt was
/// carried over by accident. Drives the warning banner in
/// `AIInstructionsSheet`.
struct AIInstructionsBloatHint: Equatable {
    let characterCount: Int
    let looksLikeLegacyDefault: Bool

    var bannerMessage: String {
        if looksLikeLegacyDefault {
            return "These notes look like the old default AI prompt (\(characterCount) chars). They're appended verbatim to every AI request and are likely slowing tagging down. Clear them?"
        }
        return "Notes are unusually long (\(characterCount) chars). They're appended verbatim to every AI request and may be slowing tagging down."
    }
}

extension ProjectStore {

    // MARK: - Buckets

    /// Append a new bucket with the given name and color, picking the next
    /// available `sortOrder`. Trims and rejects empty names. Returns the
    /// updated project.
    @discardableResult
    func addBucket(_ project: Project,
                    name rawName: String,
                    colorHex: String) -> Project {
        var p = project
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return p }
        let nextOrder = (p.buckets.map(\.sortOrder).max() ?? -1) + 1
        p.buckets.append(Bucket(name: name,
                                 colorHex: colorHex,
                                 sortOrder: nextOrder))
        return save(p)
    }

    /// Rename an existing bucket. No-op if the bucket isn't found or the
    /// new name is blank.
    @discardableResult
    func renameBucket(_ project: Project,
                       bucketID: UUID,
                       to rawName: String) -> Project {
        var p = project
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let idx = p.buckets.firstIndex(where: { $0.id == bucketID }) else {
            return p
        }
        p.buckets[idx].name = name
        return save(p)
    }

    /// Update a bucket's `colorHex`. No-op if the bucket isn't found.
    @discardableResult
    func recolorBucket(_ project: Project,
                        bucketID: UUID,
                        colorHex: String) -> Project {
        var p = project
        guard let idx = p.buckets.firstIndex(where: { $0.id == bucketID }) else {
            return p
        }
        p.buckets[idx].colorHex = colorHex
        return save(p)
    }

    /// Replace the project's buckets with the given order, rewriting each
    /// `sortOrder` to its position in the array. The caller is expected to
    /// pass the same set of buckets — extras are accepted, missing ones are
    /// dropped (which would also drop them from `Photo.bucketID` references
    /// via `deleteBucket`'s sweep, so prefer `deleteBucket` for removals).
    @discardableResult
    func reorderBuckets(_ project: Project, ordered: [Bucket]) -> Project {
        var p = project
        p.buckets = ordered.enumerated().map { i, bucket in
            var b = bucket
            b.sortOrder = i
            return b
        }
        return save(p)
    }

    /// Drop a bucket and clear `Photo.bucketID` on every photo that pointed
    /// at it (so they fall back to "Unbucketed").
    @discardableResult
    func deleteBucket(_ project: Project, bucketID: UUID) -> Project {
        var p = project
        p.buckets.removeAll { $0.id == bucketID }
        for i in p.photos.indices where p.photos[i].bucketID == bucketID {
            p.photos[i].bucketID = nil
        }
        return save(p)
    }

    /// Assign every photo in `photoIDs` to `bucketID`. Pass `nil` to clear
    /// the bucket (drop the photos back into "Unbucketed"). Bucket IDs that
    /// aren't actually defined on the project are silently rejected so a
    /// stale reference can't corrupt the manifest.
    @discardableResult
    func setBucket(_ project: Project,
                    photoIDs: Set<UUID>,
                    bucketID: UUID?) -> Project {
        var p = project
        guard !photoIDs.isEmpty else { return p }
        if let id = bucketID, !p.buckets.contains(where: { $0.id == id }) {
            return p
        }
        for i in p.photos.indices where photoIDs.contains(p.photos[i].id) {
            p.photos[i].bucketID = bucketID
        }
        return save(p)
    }

    /// Toggle the photo's favorite flag. Used by the star icon in the
    /// photo row.
    @discardableResult
    func setFavorite(_ project: Project,
                      photoID: UUID,
                      isFavorite: Bool) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        p.photos[idx].isFavorite = isFavorite
        return save(p)
    }

    /// Bump the user's preview rotation by 90° (CW). Cycles
    /// 0 → 90 → 180 → 270 → 0. Persists on the photo so the rotation
    /// survives session restart + iCloud sync.
    @discardableResult
    func rotatePhotoPreview(_ project: Project, photoID: UUID) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let next = (p.photos[idx].previewRotation + 90) % 360
        p.photos[idx].previewRotation = next
        return save(p)
    }

    /// Set or clear the user's caption override for a photo. Empty / blank
    /// strings revert to nil so the AI's `captionDraft` is used again.
    @discardableResult
    func setUserCaption(_ project: Project,
                         photoID: UUID,
                         _ text: String?) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        p.photos[idx].userCaption = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return save(p)
    }

    /// Set or clear the user's observation override for a photo. Same
    /// nil/empty semantics as `setUserCaption`.
    @discardableResult
    func setUserObservation(_ project: Project,
                             photoID: UUID,
                             _ text: String?) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        p.photos[idx].userObservation = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return save(p)
    }

    // MARK: - Tags

    /// Identity key for a Tag in the dedup pipelines: case-insensitive
    /// label, scoped to its parent. "Brick crack" under "Masonry" and
    /// "Brick crack" under any other primary count as different tags;
    /// two "Brick crack" entries under the same parent collapse.
    private static func tagKey(parent: String?, label: String) -> String {
        let p = parent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(p)|\(l)"
    }

    /// Add a tag to a photo. Trims whitespace, dedupes against the photo's
    /// existing tags by (parentTag, label) so the same secondary appearing
    /// under two different primaries stays distinct. Manually-typed tags get
    /// `confidence = 1.0` so they always pass any threshold the user sets.
    /// If the tag already exists, the higher of the two confidences wins.
    @discardableResult
    func addTag(_ project: Project,
                photoID: UUID,
                tag rawLabel: String,
                confidence: Double = 1.0,
                parentTag: String? = nil) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return p }
        let key = Self.tagKey(parent: parentTag, label: trimmed)
        if let existing = p.photos[idx].tags.firstIndex(where: {
            Self.tagKey(parent: $0.parentTag, label: $0.label) == key
        }) {
            if p.photos[idx].tags[existing].confidence < confidence {
                p.photos[idx].tags[existing].confidence = confidence
            }
            return save(p)
        }
        p.photos[idx].tags.append(
            Tag(label: trimmed, confidence: confidence, parentTag: parentTag)
        )
        return save(p)
    }

    /// Remove a tag from a photo. Case-insensitive match. When `parentTag`
    /// is supplied, only the matching (parent, label) pair is removed; when
    /// nil, every tag with that label across all primaries is removed —
    /// preserves the historical "remove by name" behaviour for callers
    /// that don't track hierarchy.
    @discardableResult
    func removeTag(_ project: Project,
                   photoID: UUID,
                   tag: String,
                   parentTag: String? = nil) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let lc = tag.lowercased()
        if let parent = parentTag {
            let key = Self.tagKey(parent: parent, label: tag)
            p.photos[idx].tags.removeAll {
                Self.tagKey(parent: $0.parentTag, label: $0.label) == key
            }
        } else {
            p.photos[idx].tags.removeAll { $0.label.lowercased() == lc }
        }
        return save(p)
    }

    /// Remove a primary tag *and every secondary that lives under it* in
    /// one step. Used by the filter view's "remove all under category"
    /// affordance and any future bulk editor.
    @discardableResult
    func removePrimaryTag(_ project: Project,
                          photoID: UUID,
                          primary: String) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let lc = primary.lowercased()
        p.photos[idx].tags.removeAll { tag in
            (tag.parentTag == nil && tag.label.lowercased() == lc) ||
            (tag.parentTag?.lowercased() == lc)
        }
        return save(p)
    }

    /// Replace the full tag list for a photo. Trims + dedupes by
    /// (parentTag, label).
    @discardableResult
    func setTags(_ project: Project,
                  photoID: UUID,
                  tags: [Tag],
                  autoSave: Bool = true) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        var seen: [String: Int] = [:]
        var out: [Tag] = []
        for t in tags {
            let trimmed = t.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = Self.tagKey(parent: t.parentTag, label: trimmed)
            if let i = seen[key] {
                if out[i].confidence < t.confidence {
                    out[i].confidence = t.confidence
                }
                continue
            }
            seen[key] = out.count
            out.append(Tag(label: trimmed, confidence: t.confidence, parentTag: t.parentTag))
        }
        p.photos[idx].tags = out
        if autoSave { return save(p) }
        commitInMemory(p)
        return p
    }

    /// Merge a list of incoming Tags into the photo's existing tags,
    /// keyed by (parentTag, label). Used by the AI auto-accept paths so
    /// confidence is preserved instead of being collapsed to 1.0.
    @discardableResult
    func mergeTags(_ project: Project,
                    photoID: UUID,
                    additions: [Tag],
                    autoSave: Bool = true) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        var lookup: [String: Int] = [:]
        for (i, t) in p.photos[idx].tags.enumerated() {
            lookup[Self.tagKey(parent: t.parentTag, label: t.label)] = i
        }
        for incoming in additions {
            let trimmed = incoming.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = Self.tagKey(parent: incoming.parentTag, label: trimmed)
            if let i = lookup[key] {
                if p.photos[idx].tags[i].confidence < incoming.confidence {
                    p.photos[idx].tags[i].confidence = incoming.confidence
                }
            } else {
                let newTag = Tag(label: trimmed,
                                 confidence: incoming.confidence,
                                 parentTag: incoming.parentTag)
                lookup[key] = p.photos[idx].tags.count
                p.photos[idx].tags.append(newTag)
            }
        }
        if autoSave { return save(p) }
        commitInMemory(p)
        return p
    }

    /// Replace the photo's pending AI suggestions, dropping any candidates
    /// already present in the confirmed tags. Dedup key includes parentTag
    /// so a primary suggestion and a same-named secondary suggestion don't
    /// collide.
    @discardableResult
    func setPendingSuggestions(_ project: Project,
                                photoID: UUID,
                                suggestions: [TagSuggestion]) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let confirmedKeys = Set(p.photos[idx].tags.map {
            Self.tagKey(parent: $0.parentTag, label: $0.label)
        })
        var bySrcLabel: [String: TagSuggestion] = [:]
        for s in suggestions {
            let tkey = Self.tagKey(parent: s.parentTag, label: s.label)
            if confirmedKeys.contains(tkey) { continue }
            let key = "\(s.source.rawValue):\(tkey)"
            if let existing = bySrcLabel[key], existing.confidence >= s.confidence { continue }
            bySrcLabel[key] = s
        }
        p.photos[idx].pendingSuggestions = bySrcLabel.values
            .sorted { $0.confidence > $1.confidence }
        return save(p)
    }

    /// Promote a single AI suggestion into a confirmed tag, preserving the
    /// suggestion's confidence and parentTag on the resulting Tag.
    @discardableResult
    func confirmSuggestion(_ project: Project,
                            photoID: UUID,
                            suggestion: TagSuggestion) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        let key = Self.tagKey(parent: suggestion.parentTag, label: suggestion.label)
        if let existing = p.photos[idx].tags.firstIndex(where: {
            Self.tagKey(parent: $0.parentTag, label: $0.label) == key
        }) {
            if p.photos[idx].tags[existing].confidence < suggestion.confidence {
                p.photos[idx].tags[existing].confidence = suggestion.confidence
            }
        } else {
            p.photos[idx].tags.append(Tag(label: suggestion.label,
                                          confidence: suggestion.confidence,
                                          parentTag: suggestion.parentTag))
        }
        // Drop every pending suggestion at the same (parent,label) coordinate,
        // regardless of source — once confirmed, no source needs to keep
        // pestering the user about that exact tag.
        p.photos[idx].pendingSuggestions.removeAll {
            Self.tagKey(parent: $0.parentTag, label: $0.label) == key
        }
        return save(p)
    }

    /// Persist the schema-2 analysis returned by Claude. Mirrors
    /// `summary_observation` into the legacy `aiObservation` field so any
    /// remaining UI / export code that hasn't migrated to `aiAnalysis`
    /// yet keeps showing something useful, and clears the legacy
    /// `aiSeverity` / `aiFollowUp` fields since the new schema doesn't
    /// produce them.
    @discardableResult
    func setPhotoAIAnalysis(_ project: Project,
                             photoID: UUID,
                             analysis: AIPhotoAnalysis,
                             autoSave: Bool = true) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        p.photos[idx].aiAnalysis = analysis
        let obs = analysis.summaryObservation.trimmingCharacters(in: .whitespacesAndNewlines)
        p.photos[idx].aiObservation = obs.isEmpty ? nil : obs
        p.photos[idx].aiSeverity = nil
        p.photos[idx].aiFollowUp = nil
        if autoSave { return save(p) }
        commitInMemory(p)
        return p
    }

    /// Wipe everything an AI run can have left behind on the given photos:
    /// tags whose confidence is < 1.0 (i.e. AI-attributed; manually-typed
    /// tags default to 1.0 and survive), pending suggestions awaiting
    /// confirmation, and the AI metadata fields (severity / observation /
    /// follow-up). One save per affected photo.
    ///
    /// Note: legacy tags that decoded out of the old `[String]` format are
    /// stored at confidence 1.0 because the original source was lost — they
    /// can't be distinguished from user-typed entries. Those survive too;
    /// the user has to remove them manually if they really want them gone.
    @discardableResult
    func clearAIInfo(_ project: Project, photoIDs: Set<UUID>) -> Project {
        // Centralised "is this tag AI-origin?" predicate so the
        // confidence heuristic and the synthetic-label exceptions
        // stay in lockstep. Currently:
        //   - Anything with `confidence < 1.0` is AI-origin
        //     (Claude suggestions and the synthetic measurement tag).
        //   - The synthetic "Measurement reading" label is also
        //     swept by literal name match, because older app
        //     versions used to persist it at confidence 1.0 and
        //     would leave it stranded after a clear. The label
        //     match cleans those out on the next clear without
        //     forcing a one-shot data migration.
        let syntheticLabels: Set<String> = [
            ClaudeTaggingService.measurementTagLabel.lowercased()
        ]
        func isAIOriginTag(_ tag: Tag) -> Bool {
            if tag.confidence < 1.0 { return true }
            return syntheticLabels.contains(tag.label.lowercased())
        }

        var p = project
        for id in photoIDs {
            guard let idx = p.photos.firstIndex(where: { $0.id == id }) else { continue }
            p.photos[idx].tags.removeAll { isAIOriginTag($0) }
            p.photos[idx].pendingSuggestions = []
            p.photos[idx].aiSeverity = nil
            p.photos[idx].aiObservation = nil
            p.photos[idx].aiFollowUp = nil
            p.photos[idx].aiAnalysis = nil
        }
        return save(p)
    }

    /// Clear ONLY the saved AI analysis blob (caption draft, summary
    /// observation, recommended use, confidence, reviewer flag, …) and
    /// the legacy aiSeverity/aiObservation/aiFollowUp scaffolding on
    /// each selected photo. Tags and pending suggestions are left
    /// intact — the granular `ClearAITagsSheet` flow uses this when the
    /// "Also clear AI analysis" toggle is on so the user can wipe the
    /// narrative fields without losing manually-typed tags.
    @discardableResult
    func clearAIAnalysis(_ project: Project, photoIDs: Set<UUID>) -> Project {
        var p = project
        for id in photoIDs {
            guard let idx = p.photos.firstIndex(where: { $0.id == id }) else { continue }
            p.photos[idx].aiAnalysis = nil
            p.photos[idx].aiSeverity = nil
            p.photos[idx].aiObservation = nil
            p.photos[idx].aiFollowUp = nil
        }
        return save(p)
    }

    /// One unit of "what tag to remove" for the granular clear path. When
    /// `parent` is nil, `label` is treated as a primary — matches the primary
    /// itself (parentTag == nil) AND any secondary whose parentTag matches
    /// `label`. When `parent` is non-nil, only matches the exact (parent, label)
    /// pair. Comparisons are case-insensitive.
    struct TagSelector: Hashable, Sendable {
        let parent: String?
        let label: String

        init(parent: String? = nil, label: String) {
            self.parent = parent
            self.label = label
        }
    }

    /// Remove every tag and pending suggestion on `photoIDs` that matches
    /// any of `selectors`. Leaves manually-typed tags whose label/parent
    /// don't match a selector alone, and never touches `aiAnalysis` or the
    /// legacy `aiSeverity` / `aiObservation` / `aiFollowUp` metadata —
    /// callers wanting the full nuke should use `clearAIInfo` instead.
    @discardableResult
    func removeTags(_ project: Project,
                    photoIDs: Set<UUID>,
                    selectors: Set<TagSelector>) -> Project {
        var p = project
        guard !photoIDs.isEmpty, !selectors.isEmpty else { return p }

        // Pre-bucket selectors so the per-tag check is O(1) lookups.
        var primaryLC: Set<String> = []
        var pairKeys: Set<String> = []
        for sel in selectors {
            if let parent = sel.parent {
                pairKeys.insert(Self.tagKey(parent: parent, label: sel.label))
            } else {
                primaryLC.insert(sel.label.lowercased())
            }
        }

        func matches(parent: String?, label: String) -> Bool {
            let lc = label.lowercased()
            if parent == nil, primaryLC.contains(lc) { return true }
            if let parent, primaryLC.contains(parent.lowercased()) { return true }
            return pairKeys.contains(Self.tagKey(parent: parent, label: label))
        }

        for id in photoIDs {
            guard let idx = p.photos.firstIndex(where: { $0.id == id }) else { continue }
            p.photos[idx].tags.removeAll {
                matches(parent: $0.parentTag, label: $0.label)
            }
            p.photos[idx].pendingSuggestions.removeAll {
                matches(parent: $0.parentTag, label: $0.label)
            }
        }
        return save(p)
    }

    /// Drop a single AI suggestion without confirming it.
    @discardableResult
    func dismissSuggestion(_ project: Project,
                            photoID: UUID,
                            suggestion: TagSuggestion) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        p.photos[idx].pendingSuggestions.removeAll { $0.id == suggestion.id }
        return save(p)
    }

    /// One primary group surfaced in the hierarchical filter view. The
    /// `primary` itself may also appear on photos as a tag, so we track
    /// whether at least one photo carries it standalone (`primaryUsed`) —
    /// that's what lights up the primary chip in the filter UI. The
    /// `secondaries` list is every secondary tag observed under that
    /// primary, with its frequency, sorted most-used first.
    struct TagGroup: Hashable, Sendable {
        let primary: String
        let primaryUsed: Bool
        let primaryCount: Int
        let secondaries: [SecondaryEntry]

        struct SecondaryEntry: Hashable, Sendable {
            let label: String
            let count: Int
        }
    }

    /// Tags currently in use across the given project. Sorted by frequency
    /// (most-used first). Tags below `minConfidence` (per-photo) are not
    /// counted, so the typeahead/filter list reflects the user's threshold.
    func tagsUsed(in project: Project, minConfidence: Double = 0) -> [String] {
        rankTags(in: project.photos, minConfidence: minConfidence)
    }

    /// Hierarchical view of tags used in `project`: one `TagGroup` per
    /// distinct primary (canonical primary tags from `ControlledVocabulary`
    /// come first in seed order, then any unknown primaries appear
    /// alphabetically at the end). Used by the tag-filter view to render
    /// primary headers with secondary chips beneath them. Tags below
    /// `minConfidence` are excluded.
    func tagsUsedHierarchically(in project: Project,
                                minConfidence: Double = 0) -> [TagGroup] {
        rankTagsHierarchically(in: project.photos, minConfidence: minConfidence)
    }

    /// Tags currently in use across every project the user has — used to
    /// surface previously-typed tags on a fresh project. Sorted by frequency.
    func tagsUsedGlobally(minConfidence: Double = 0) -> [String] {
        let all = activeProjects.flatMap { $0.photos } + deletedProjects.flatMap { $0.photos }
        return rankTags(in: all, minConfidence: minConfidence)
    }

    private func rankTags(in photos: [Photo], minConfidence: Double) -> [String] {
        // Count case-insensitively, but remember the most-common display
        // casing for each lowercase key.
        var counts: [String: Int] = [:]
        var displays: [String: [String: Int]] = [:]
        for photo in photos {
            for t in photo.tags where t.confidence >= minConfidence {
                let key = t.label.lowercased()
                counts[key, default: 0] += 1
                displays[key, default: [:]][t.label, default: 0] += 1
            }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { (key, _) in
                let perCasing = displays[key] ?? [:]
                return perCasing.max { $0.value < $1.value }?.key ?? key
            }
    }

    /// Group photo tags into primary→secondary rows. A primary "bucket" is
    /// created for any primary that's directly tagged on a photo (parentTag
    /// == nil) AND for any primary that's referenced as the parent of a
    /// secondary tag (parentTag == "Masonry"). Secondaries are listed under
    /// their parent. Primary-tag display casing follows the canonical
    /// `ControlledVocabulary.primaries` capitalisation when the
    /// case-insensitive match wins; otherwise it follows whatever casing
    /// photos used.
    private func rankTagsHierarchically(in photos: [Photo],
                                         minConfidence: Double) -> [TagGroup] {
        // Aggregator keyed on lowercased primary name.
        struct Bucket {
            var displayCounts: [String: Int] = [:]      // casing → count
            var primaryUsed: Bool = false               // photo had primary tag itself
            var primaryCount: Int = 0
            var secondaryCounts: [String: Int] = [:]    // lowercased label → count
            var secondaryDisplays: [String: [String: Int]] = [:] // lc → casing → count
        }
        var buckets: [String: Bucket] = [:]

        @inline(__always)
        func bucket(for primary: String) -> String {
            let lc = primary.lowercased()
            if buckets[lc] == nil {
                buckets[lc] = Bucket()
            }
            // Track all the casings we've seen for this primary so the
            // canonical one can win when we render. ControlledVocabulary
            // casing gets a leg up so seed-style names beat photo-typed
            // variants.
            buckets[lc]!.displayCounts[primary, default: 0] += 1
            return lc
        }

        for photo in photos {
            for t in photo.tags where t.confidence >= minConfidence {
                if let parent = t.parentTag, !parent.isEmpty {
                    let lc = bucket(for: parent)
                    let labelLC = t.label.lowercased()
                    buckets[lc]!.secondaryCounts[labelLC, default: 0] += 1
                    buckets[lc]!.secondaryDisplays[labelLC, default: [:]][t.label, default: 0] += 1
                } else {
                    let lc = bucket(for: t.label)
                    buckets[lc]!.primaryUsed = true
                    buckets[lc]!.primaryCount += 1
                }
            }
        }

        // Pick canonical display casing for each primary. If the lowercased
        // name matches a known primary from the guide, use the guide's
        // capitalisation; otherwise pick the most-frequent observed casing.
        let canonicalByLC: [String: String] = Dictionary(
            uniqueKeysWithValues: ControlledVocabulary.primaries.map { ($0.lowercased(), $0) }
        )

        let groups: [TagGroup] = buckets.map { (lc, b) in
            let display: String
            if let canon = canonicalByLC[lc] {
                display = canon
            } else {
                display = b.displayCounts.max { $0.value < $1.value }?.key ?? lc
            }
            let secondaries = b.secondaryCounts
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .map { (key, count) -> TagGroup.SecondaryEntry in
                    let casings = b.secondaryDisplays[key] ?? [:]
                    let labelDisplay = casings.max { $0.value < $1.value }?.key ?? key
                    return TagGroup.SecondaryEntry(label: labelDisplay, count: count)
                }
            return TagGroup(primary: display,
                            primaryUsed: b.primaryUsed,
                            primaryCount: b.primaryCount,
                            secondaries: secondaries)
        }

        // Sort: known primaries by guide order, unknown primaries alphabetical
        // at the end. Within a tied rank (Int.max for unknowns), tiebreak by
        // primary name so the order is stable.
        return groups.sorted { lhs, rhs in
            let lr = ControlledVocabulary.primaryRank(lhs.primary)
            let rr = ControlledVocabulary.primaryRank(rhs.primary)
            if lr != rr { return lr < rr }
            return lhs.primary.lowercased() < rhs.primary.lowercased()
        }
    }

    // MARK: - Batch Claude tagging

    /// Run Claude vision tagging across every photo in the project, then
    /// auto-confirm whatever Claude returns. Designed for the "tag all
    /// photos at once" project-detail button, where the user has already
    /// agreed to the cost.
    ///
    /// `skipAlreadyTagged` — when true (default), photos that already have
    /// at least one confirmed tag are left alone. Lets the user add manual
    /// tags first, then top up with AI for the rest.
    ///
    /// `onProgress` is called on the main actor before each photo and once
    /// more on completion. `current` is 1-based; `current == total` and a
    /// non-empty `summary` indicate the run finished.
    ///
    /// Throws `ClaudeTaggingService.Error.missingAPIKey` immediately if no
    /// key is on file. Per-photo errors (network blips, parse failures) are
    /// swallowed so a single bad photo doesn't kill the rest of the batch —
    /// the result tuple reports how many photos got at least one tag and
    /// how many failed.
    /// How a batch reconciles its newly-returned tags with what each photo
    /// already has on record. Selected once at the start of a batch and
    /// applied to every photo in that run.
    enum BatchTagMode: Sendable {
        /// Merge new tags with existing ones (case-insensitive dedup; the
        /// higher of two confidences wins for duplicates). Existing tags
        /// stay put.
        case add
        /// Discard the photo's existing tags before applying the new ones.
        /// Manually-typed tags get wiped — only use this when retagging
        /// from scratch.
        case overwrite
    }

    /// One per-photo failure surfaced from a batch run. Carries enough
    /// information for the summary sheet to render a row (sequence number,
    /// thumbnail via photoID) and tell the user *why* it failed.
    struct BatchTagFailure: Identifiable, Sendable {
        let id: UUID
        let photoID: UUID
        let sequenceNumber: Int
        let message: String

        init(photoID: UUID, sequenceNumber: Int, message: String) {
            self.id = photoID
            self.photoID = photoID
            self.sequenceNumber = sequenceNumber
            self.message = message
        }
    }

    /// Lightweight per-photo reference used in the batch summary's
    /// "needs review" lists (low confidence, reviewer flag, validation
    /// errors, parse fail). Carrying both the photo ID and the user-
    /// visible sequence number lets the summary sheet render rows
    /// without a second project lookup, and lets the user tap through
    /// to the editor.
    struct BatchPhotoRef: Sendable, Hashable, Identifiable {
        let id: UUID
        let photoID: UUID
        let sequenceNumber: Int
        /// Optional context line for the summary list (e.g. the reviewer
        /// flag text, or the first validation error).
        let detail: String?

        init(photoID: UUID, sequenceNumber: Int, detail: String? = nil) {
            self.id = photoID
            self.photoID = photoID
            self.sequenceNumber = sequenceNumber
            self.detail = detail
        }
    }

    /// Outcome of a batch tagging run. Carries the rich post-batch
    /// summary the user sees in `BatchTagSummarySheet` — counts per
    /// primary, counts per recommended use, and "needs review" lists for
    /// the photos that warrant a second look before the user moves on.
    struct BatchTagResult: Sendable {
        /// Number of photos that got at least one new tag from Claude.
        let tagged: Int
        /// Number of photos skipped because they already had tags
        /// (`skipAlreadyTagged == true`).
        let skipped: Int
        /// Per-photo network/HTTP failures with reason. `failed` is
        /// `failures.count`. Photos whose JSON couldn't be decoded show
        /// up in `parseFailed` instead.
        let failures: [BatchTagFailure]

        /// Photo count by Primary Tag, in canonical guide order. Drives
        /// the per-primary breakdown in the summary sheet.
        let countsByPrimary: [(primary: String, count: Int)]
        /// Photo count by `recommendedUse.bucketKey`. Order: known cases
        /// first (Body figure → Re-shoot recommended), then any unknowns.
        let countsByRecommendedUse: [(bucket: String, count: Int)]
        /// Photos where Claude self-rated Low confidence.
        let lowConfidence: [BatchPhotoRef]
        /// Photos where Claude wrote a non-empty `reviewer_flag`.
        let reviewerFlagged: [BatchPhotoRef]
        /// Photos whose JSON parsed but failed validation.
        let validationIssues: [BatchPhotoRef]
        /// Photos whose JSON couldn't be decoded at all. Their raw
        /// response is on `Photo.aiAnalysis.rawResponse`.
        let parseFailed: [BatchPhotoRef]

        var failed: Int { failures.count }

        /// True when nothing in the run needs the engineer's attention —
        /// no failures, no parse errors, no validation issues, no reviewer
        /// flags, no low-confidence picks.
        var isCompletelyClean: Bool {
            failures.isEmpty
                && parseFailed.isEmpty
                && validationIssues.isEmpty
                && reviewerFlagged.isEmpty
                && lowConfidence.isEmpty
        }
    }

    /// Run Claude vision tagging across the project's photos.
    ///
    /// `skipAlreadyTagged` — when true (default), photos that already have
    /// at least one confirmed tag are left alone. Lets the user add manual
    /// tags first, then top up with AI for the rest. Ignored when
    /// `onlyPhotoIDs` is set.
    ///
    /// `onlyPhotoIDs` — when set, only the listed photos are processed and
    /// `skipAlreadyTagged` is ignored. Used by the retry-failed flow so the
    /// user can re-run only the photos that errored out the first time.
    ///
    /// `mode` — `.add` merges new tags; `.overwrite` replaces existing tags.
    ///
    /// Throws `ClaudeTaggingService.Error.missingAPIKey` immediately if no
    /// key is on file. Per-photo errors (network blips, parse failures) are
    /// captured into `BatchTagResult.failures` so a single bad photo doesn't
    /// kill the rest of the batch.
    @MainActor
    @discardableResult
    func batchClaudeTagging(
        projectID: UUID,
        skipAlreadyTagged: Bool = true,
        mode: BatchTagMode = .add,
        onlyPhotoIDs: Set<UUID>? = nil,
        onProgress: @escaping @MainActor (_ current: Int, _ total: Int, _ photoSeq: Int?) -> Void
    ) async throws -> BatchTagResult {
        guard KeychainStore.loadAnthropicKey()?.isEmpty == false else {
            throw ClaudeTaggingService.Error.missingAPIKey
        }
        guard let project = self.project(withID: projectID) else {
            return BatchTagResult(
                tagged: 0, skipped: 0, failures: [],
                countsByPrimary: [], countsByRecommendedUse: [],
                lowConfidence: [], reviewerFlagged: [],
                validationIssues: [], parseFailed: []
            )
        }

        let candidates: [Photo]
        let skippedCount: Int
        if let onlyPhotoIDs {
            candidates = project.photos.filter { onlyPhotoIDs.contains($0.id) }
            skippedCount = 0
        } else {
            candidates = project.photos.filter { photo in
                skipAlreadyTagged ? photo.tags.isEmpty : true
            }
            skippedCount = project.photos.count - candidates.count
        }
        let total = candidates.count
        // Compose the system prompt + validation vocabulary once for
        // the entire batch. Same text for every photo so Anthropic's
        // ephemeral prompt cache kicks in on photo 2 onwards.
        let compiled: PromptCompiler.Result
        do {
            compiled = try PromptCompiler.compile(
                rulesTemplate: self.aiRulesTemplate,
                tagLibrary: self.tagLibrary,
                project: project
            )
        } catch let e as PromptCompiler.CompileError {
            // No vocabulary scope picked — bail before touching the API.
            // Returns the same "empty result" shape the no-photos guard
            // above uses so callers don't need a separate error branch.
            toastCenter?.post(e.errorDescription ?? "Pick at least one investigation context first.",
                                kind: .error)
            return BatchTagResult(
                tagged: 0, skipped: 0, failures: [],
                countsByPrimary: [], countsByRecommendedUse: [],
                lowConfidence: [], reviewerFlagged: [],
                validationIssues: [], parseFailed: []
            )
        }

        // Read concurrency from the user's setting (default 3). Tier-1
        // Anthropic accounts have a 30k input-tokens/min cap; with a long
        // forensic guide + 1024 px image (~5–6k input tokens uncached, ~1.5k
        // once the system message is cached), 3 in flight stays under the
        // limit on sustained batches. Users on higher tiers can dial it up
        // in Settings.
        // Default concurrency is 5: with multi-block prompt caching the
        // first photo of a batch carries the full prompt cost and every
        // subsequent photo hits the cached prefix at ~10× discount, so
        // 5 in-flight requests stay safely within Tier 1's 30k input
        // tokens/min rate cap on warm batches. Engineers can dial up to
        // 20 in Settings if they're on a higher tier. `raw == 0` means
        // "never set" — UserDefaults returns 0 for missing keys.
        let raw = UserDefaults.standard.integer(forKey: "sitephoto.aiConcurrency")
        let maxConcurrent = max(1, min(20, raw == 0 ? 5 : raw))

        // Pre-compute the per-photo work list on the main actor so the
        // task closures don't have to call back into `self` for URLs —
        // keeps the closures Sendable-clean.
        struct WorkItem {
            let photoID: UUID
            let sequenceNumber: Int
            let url: URL
            /// Image filename, passed to Claude as `photo_id` so the
            /// model can echo it back in its JSON.
            let filename: String
        }
        let work: [WorkItem] = candidates.map { p in
            WorkItem(photoID: p.id,
                      sequenceNumber: p.sequenceNumber,
                      url: self.imageURL(for: p, in: project),
                      filename: p.imageFilename)
        }

        var tagged = 0
        var failures: [BatchTagFailure] = []
        var completed = 0

        // Defer disk writes during the batch — per-photo `save()` calls
        // encode the entire project JSON twice per photo (once for tags,
        // once for analysis), which dominates wall-clock time on large
        // projects. Apply mutations in-memory and flush every
        // `checkpointInterval` photos so an interrupted run never loses
        // more than that many photos' worth of work. A final flush at
        // the end (and an error/cancel flush via `defer`) makes sure
        // everything lands on disk regardless of how the loop exits.
        let checkpointInterval = 25
        var unflushedSinceCheckpoint = 0
        func flushPendingChanges() {
            if let p = self.project(withID: projectID) {
                _ = self.save(p)
            }
            unflushedSinceCheckpoint = 0
        }

        // Rich-summary accumulators. Filled as each successful response
        // lands; assembled into `BatchTagResult` when the run finishes.
        var primaryCounts: [String: Int] = [:]
        var recommendedUseCounts: [String: Int] = [:]
        var lowConfidence: [BatchPhotoRef] = []
        var reviewerFlagged: [BatchPhotoRef] = []
        var validationIssues: [BatchPhotoRef] = []
        var parseFailedRefs: [BatchPhotoRef] = []

        // Ensure any work accumulated in-memory but not yet checkpointed
        // gets written, even on error, cancellation, or early throw.
        // Runs once when the outer function returns or throws.
        defer {
            if unflushedSinceCheckpoint > 0 {
                flushPendingChanges()
            }
        }

        // Resolve the AI-dispatch route once, up-front. `useBackend` is
        // only meaningful when an `APIClient` has been wired in
        // (`SitePhotoApp.init`); otherwise we silently fall back to the
        // device-key path. The capture-by-value below keeps the task
        // closure Sendable-clean.
        let useBackend = UserDefaults.standard.bool(forKey: "sitephoto.aiTagging.useBackend")
        let backendAPI: APIClient? = useBackend ? self.apiClient : nil

        try await withThrowingTaskGroup(of: PhotoTagResult.self) { group in
            var iterator = work.makeIterator()

            // Helper: launch the next photo's API call. Returns false once
            // the iterator is empty so the drain loop can stop scheduling.
            // Captures only value types (URL, UUID, Int, String) so the
            // Sendable contract on `addTask` holds.
            func launchNext() -> Bool {
                guard let item = iterator.next() else { return false }
                let url = item.url
                let pid = item.photoID
                let seq = item.sequenceNumber
                let fname = item.filename
                let promptBlocks = compiled.blocks
                let vocab = compiled.vocabulary
                let modelID = AITaggingModel.current.modelIdentifier
                let projID = projectID
                let api = backendAPI
                group.addTask {
                    do {
                        let r: ClaudeTaggingService.Result
                        if let api {
                            // Backend path: server fetches photo bytes
                            // from R2, no local download needed.
                            r = try await ClaudeTaggingService.tagViaBackend(
                                projectID: projID,
                                photoID: pid,
                                promptPhotoID: fname,
                                systemBlocks: promptBlocks,
                                vocabulary: vocab,
                                model: modelID,
                                apiClient: api
                            )
                        } else {
                            await Self.ensureDownloadedStatic(at: url)
                            r = try await ClaudeTaggingService.tag(
                                imageURL: url,
                                photoID: fname,
                                systemBlocks: promptBlocks,
                                vocabulary: vocab,
                                model: modelID
                            )
                        }
                        return PhotoTagResult(photoID: pid, sequenceNumber: seq,
                                              outcome: .success(r))
                    } catch ClaudeTaggingService.Error.missingAPIKey {
                        return PhotoTagResult(photoID: pid, sequenceNumber: seq,
                                              outcome: .authFailure)
                    } catch {
                        return PhotoTagResult(photoID: pid, sequenceNumber: seq,
                                              outcome: .otherFailure(error.localizedDescription))
                    }
                }
                return true
            }

            // Seed the pool with up to `maxConcurrent` in-flight tasks.
            for _ in 0..<maxConcurrent {
                if !launchNext() { break }
            }

            // Drain: as each task finishes, apply its result on the main
            // actor and queue the next one. Maintains a steady N tasks in
            // flight until `iterator` is exhausted.
            for try await result in group {
                try Task.checkCancellation()
                completed += 1

                switch result.outcome {
                case .authFailure:
                    group.cancelAll()
                    throw ClaudeTaggingService.Error.missingAPIKey
                case .success(let r):
                    if let proj = self.project(withID: projectID) {
                        var p = proj
                        if !r.suggestions.isEmpty {
                            let additions = r.suggestions.map {
                                Tag(label: $0.label,
                                    confidence: $0.confidence,
                                    parentTag: $0.parentTag)
                            }
                            switch mode {
                            case .add:
                                p = self.mergeTags(p, photoID: result.photoID,
                                                   additions: additions,
                                                   autoSave: false)
                            case .overwrite:
                                // Replace the photo's existing tag list
                                // entirely with what Claude returned.
                                p = self.setTags(p, photoID: result.photoID,
                                                 tags: additions,
                                                 autoSave: false)
                            }
                            tagged += 1
                        } else if mode == .overwrite {
                            // Overwrite mode + no new tags = wipe to empty
                            // tag list. Without this, an empty Claude
                            // response would silently leave old tags in
                            // place — the opposite of what overwrite
                            // promises.
                            p = self.setTags(p, photoID: result.photoID,
                                             tags: [],
                                             autoSave: false)
                        }
                        // Persist the full analysis (or the parse-failure
                        // record), even on photos with no tags returned —
                        // the rest of the schema (caption, recommended use,
                        // reviewer flag, raw response) is still useful.
                        _ = self.setPhotoAIAnalysis(
                            p, photoID: result.photoID,
                            analysis: r.analysis,
                            autoSave: false
                        )
                        unflushedSinceCheckpoint += 1
                    }
                    // Accumulate into the rich-summary buckets.
                    let a = r.analysis
                    let ref = BatchPhotoRef(photoID: result.photoID,
                                            sequenceNumber: result.sequenceNumber)
                    if a.parseFailed {
                        parseFailedRefs.append(BatchPhotoRef(
                            photoID: result.photoID,
                            sequenceNumber: result.sequenceNumber,
                            detail: a.validationErrors.first
                        ))
                    } else {
                        for primary in a.primaryTags {
                            primaryCounts[primary, default: 0] += 1
                        }
                        recommendedUseCounts[a.recommendedUse.bucketKey, default: 0] += 1
                        // Replaces the previous `case .low = a.confidence`
                        // bucket. The worded High/Medium/Low confidence
                        // enum is gone; surface a photo here when any
                        // emitted tag's per-tag confidence falls below
                        // 0.7. Matches the same threshold the per-photo
                        // `needsReview` chip uses.
                        if a.tagConfidences.values.contains(where: { $0 < 0.7 }) {
                            lowConfidence.append(BatchPhotoRef(
                                photoID: result.photoID,
                                sequenceNumber: result.sequenceNumber,
                                detail: nil
                            ))
                        }
                        if !a.reviewerFlag.isEmpty {
                            reviewerFlagged.append(BatchPhotoRef(
                                photoID: result.photoID,
                                sequenceNumber: result.sequenceNumber,
                                detail: a.reviewerFlag
                            ))
                        }
                        if !a.validationErrors.isEmpty {
                            validationIssues.append(BatchPhotoRef(
                                photoID: result.photoID,
                                sequenceNumber: result.sequenceNumber,
                                detail: a.validationErrors.first
                            ))
                        }
                    }
                    _ = ref
                case .otherFailure(let msg):
                    failures.append(BatchTagFailure(
                        photoID: result.photoID,
                        sequenceNumber: result.sequenceNumber,
                        message: msg
                    ))
                    #if DEBUG
                    print("Claude batch failed for #\(result.sequenceNumber): \(msg)")
                    #endif
                }

                onProgress(completed, total, result.sequenceNumber)

                // Periodic disk-flush so an interrupted run never loses
                // more than `checkpointInterval` photos of work. The
                // outer `defer` handles the final flush on normal exit
                // or thrown error.
                if unflushedSinceCheckpoint >= checkpointInterval {
                    flushPendingChanges()
                }

                _ = launchNext()
            }
        }

        onProgress(total, total, nil)

        // Order primary counts by canonical guide rank so the summary
        // breakdown reads top-to-bottom the way the inspector wrote the
        // guide. Unknown primaries (typos, custom guides) fall to the
        // bottom alphabetically.
        let primaryRows = primaryCounts.map { (primary: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                let lr = ControlledVocabulary.primaryRank(lhs.primary)
                let rr = ControlledVocabulary.primaryRank(rhs.primary)
                if lr != rr { return lr < rr }
                return lhs.primary.lowercased() < rhs.primary.lowercased()
            }

        // Order recommended-use buckets in the canonical sequence, then
        // any unknown buckets alphabetically.
        let useOrder: [String] = [
            RecommendedUse.bodyFigure.displayName,
            RecommendedUse.appendixOnly.displayName,
            RecommendedUse.contextLocator.displayName,
            RecommendedUse.reshootRecommended.displayName
        ]
        let useRank: [String: Int] = Dictionary(uniqueKeysWithValues:
            useOrder.enumerated().map { ($0.element, $0.offset) })
        let useRows = recommendedUseCounts.map { (bucket: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                let lr = useRank[lhs.bucket] ?? Int.max
                let rr = useRank[rhs.bucket] ?? Int.max
                if lr != rr { return lr < rr }
                return lhs.bucket.lowercased() < rhs.bucket.lowercased()
            }

        return BatchTagResult(
            tagged: tagged,
            skipped: skippedCount,
            failures: failures,
            countsByPrimary: primaryRows,
            countsByRecommendedUse: useRows,
            lowConfidence: lowConfidence.sorted { $0.sequenceNumber < $1.sequenceNumber },
            reviewerFlagged: reviewerFlagged.sorted { $0.sequenceNumber < $1.sequenceNumber },
            validationIssues: validationIssues.sorted { $0.sequenceNumber < $1.sequenceNumber },
            parseFailed: parseFailedRefs.sorted { $0.sequenceNumber < $1.sequenceNumber }
        )
    }

    /// Per-photo result emitted by the batch task group. Aggregating the
    /// outcome inside one envelope keeps the drain loop's switch tidy.
    private struct PhotoTagResult: Sendable {
        let photoID: UUID
        let sequenceNumber: Int
        let outcome: Outcome

        enum Outcome: Sendable {
            case success(ClaudeTaggingService.Result)
            case authFailure
            case otherFailure(String)
        }
    }

    /// Strip the location from an existing photo (turns it back into "NO LOC").
    /// Also clears `floorPlanID` so the photo no longer counts toward
    /// any plan's photo total in the list filter.
    @discardableResult
    func clearPhotoLocation(_ project: Project, photoID: UUID) -> Project {
        var p = project
        guard let idx = p.photos.firstIndex(where: { $0.id == photoID }) else { return p }
        p.photos[idx].floorPlanID = nil
        p.photos[idx].planPixelX = nil
        p.photos[idx].planPixelY = nil
        p.photos[idx].localXFeet = nil
        p.photos[idx].localYFeet = nil
        p.photos[idx].headingDegrees = nil
        p.photos[idx].positionSource = .none
        p.photos[idx].groupID = nil
        p.photos[idx].isPrimary = false
        return save(p)
    }

    // MARK: - iCloud-aware loading

    /// Read the bytes at `url`, ensuring an iCloud Drive placeholder is downloaded
    /// first if necessary. Returns nil if the file isn't there or download
    /// times out.
    func loadFileBytes(at url: URL, timeoutSeconds: Double = 30) async -> Data? {
        await ensureDownloaded(url, timeoutSeconds: timeoutSeconds)
        return try? Data(contentsOf: url)
    }

    /// If `url` is an iCloud-backed item that hasn't been downloaded to this
    /// device, request a download and wait until it lands.
    func ensureDownloaded(_ url: URL, timeoutSeconds: Double = 30) async {
        await Self.ensureDownloadedStatic(at: url, timeoutSeconds: timeoutSeconds)
    }

    /// Sendable-friendly variant — usable from inside `TaskGroup.addTask`
    /// closures without capturing `self`. Same behaviour as the instance
    /// method.
    static func ensureDownloadedStatic(at url: URL,
                                        timeoutSeconds: Double = 30) async {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return }
        if values.ubiquitousItemDownloadingStatus == .current { return }

        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let stepMillis: UInt64 = 250
        let total = max(1, Int(timeoutSeconds * 1000) / Int(stepMillis))
        for _ in 0..<total {
            try? await Task.sleep(nanoseconds: stepMillis * 1_000_000)
            if let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               v.ubiquitousItemDownloadingStatus == .current {
                return
            }
        }
    }

    private static func makeThumbnail(from imageData: Data, maxPixelSize: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }

        // Redraw into an opaque context so the resulting JPEG has no alpha
        // channel - avoids ImageIO's "saving opaque image with AlphaPremulLast"
        // warning and halves the in-memory footprint when the thumbnail is
        // decoded for display.
        let width = cg.width
        let height = cg.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let opaque = ctx.makeImage() else { return nil }

        let mut = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mut, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let writeOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(dest, opaque, writeOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mut as Data
    }

    // MARK: - Photo filename scheme

    /// "Project Name - 3 - 260508 14-30-22.jpg"
    /// Colons replaced with hyphens (invalid in file names on iOS/macOS).
    static func makePhotoFilename(sequenceNumber: Int, timestamp: Date, projectName: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyMMdd HH-mm-ss"
        fmt.timeZone = TimeZone.current
        let dateStr = fmt.string(from: timestamp)
        let safe = projectName
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let body = String(safe.prefix(30)).isEmpty ? "project" : String(safe.prefix(30))
        return "\(body) - \(sequenceNumber) - \(dateStr).jpg"
    }

}
