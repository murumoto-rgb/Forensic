import SwiftUI

/// Top-level export chooser. The actual heavy lifting happens in the two
/// pushed runner views (`PDFExportRunner`, `FolderExportRunner`) so each
/// can manage its own progress + share affordances without contaminating
/// the chooser's state.
struct ExportView: View {
    let projectID: UUID
    var embedded = false
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var project: Project? { store.project(withID: projectID) }
    private var photos: [Photo] { project?.photos ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section("Export options") {
                    NavigationLink {
                        PDFExportOptionsView(projectID: projectID)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("PDF report")
                                Text("Pick layout density, bucket grouping, and section order, then build the report.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.richtext")
                        }
                    }
                    .disabled(photos.isEmpty)

                    NavigationLink {
                        FolderExportRunner(projectID: projectID)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Folder by Bucket")
                                Text("One subfolder per bucket, photos copied in full resolution with EXIF preserved, plus a captions.txt per folder.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "folder")
                        }
                    }
                    .disabled(photos.isEmpty)

                    NavigationLink {
                        AIAnalysisCSVExportRunner(projectID: projectID)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AI Analysis CSV")
                                Text("One row per primary tag with the AI's context, observation, caption, measurement, and reviewer flag. Opens directly in Excel / Google Sheets.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "tablecells")
                        }
                    }
                    .disabled(photos.isEmpty)
                }
                if photos.isEmpty {
                    Section {
                        Text("Add photos to this project before exporting.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !embedded { Button("Done") { dismiss() } }
                }
            }
        }
    }
}

/// Builds the PDF report using the options the engineer picked in the
/// preceding `PDFExportOptionsView`. Kept as its own view so the export
/// chooser stays small.
struct PDFExportRunner: View {
    let projectID: UUID
    let options: PDFExportOptions
    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter

    @State private var status = "Preparing…"
    @State private var exportURL: URL?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            if let url = exportURL {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("PDF ready")
                    .font(.headline)
                ShareLink(
                    item: url,
                    subject: Text(projectName),
                    message: Text("SitePhoto project export")
                ) {
                    Label("Share / Save PDF", systemImage: "square.and.arrow.up")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            } else if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text("Export failed")
                    .font(.headline)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                ProgressView()
                    .controlSize(.large)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
        }
        .navigationTitle("PDF Report")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runExport() }
    }

    private var projectName: String {
        store.project(withID: projectID)?.name ?? "Export"
    }

    private func runExport() async {
        guard let proj = store.project(withID: projectID) else {
            failed = true; status = "Project not found."; return
        }
        guard !proj.photos.isEmpty else {
            failed = true; status = "No photos to export."; return
        }
        let service = PDFExportService(project: proj, store: store, options: options)
        do {
            let url = try await service.buildPDF { msg in
                Task { @MainActor in if !failed && exportURL == nil { status = msg } }
            }
            exportURL = url
            Haptics.success()
            toastCenter.post("PDF ready", kind: .success)
        } catch {
            failed = true
            status = error.localizedDescription
            Haptics.error()
            toastCenter.post("PDF export incomplete or failed", kind: .error)
        }
    }
}

/// Builds the per-bucket folder tree and surfaces a ShareLink + a hint
/// pointing the user at the Files-app location (so they can rename, move,
/// or upload elsewhere via Files later).
private struct FolderExportRunner: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter

    @State private var status = "Preparing…"
    @State private var folderURL: URL?
    @State private var failed = false
    @State private var running = false
    @State private var burnInTimestampAndGPS = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if let url = folderURL {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Folder ready")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saved to:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(displayPath(for: url))
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.leading)
                        .padding(8)
                        .background(Color.secondary.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 6))
                    Text("Find it in the Files app under \(filesAppLocationHint()).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                ShareLink(
                    item: url,
                    subject: Text(projectName),
                    message: Text("SitePhoto folder export")
                ) {
                    Label("Share / Move Folder", systemImage: "square.and.arrow.up")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            } else if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text("Export failed")
                    .font(.headline)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if running {
                ProgressView()
                    .controlSize(.large)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                // Pre-export options screen — pick burn-in then tap Start.
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $burnInTimestampAndGPS) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Burn timestamp + GPS into JPGs")
                            Text("Adds a visible date / coordinates label in the bottom-right corner of each exported photo. Useful for litigation-grade evidence; loses EXIF metadata on stamped copies.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        Task { await runExport() }
                    } label: {
                        Label("Start Export", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 20)
            }
            Spacer()
        }
        .navigationTitle("Folder by Bucket")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var projectName: String {
        store.project(withID: projectID)?.name ?? "Export"
    }

    private func runExport() async {
        guard let proj = store.project(withID: projectID) else {
            failed = true; status = "Project not found."; return
        }
        guard !proj.photos.isEmpty else {
            failed = true; status = "No photos to export."; return
        }
        running = true
        status = "Preparing…"
        let service = FolderExportService(
            project: proj,
            store: store,
            burnInTimestampAndGPS: burnInTimestampAndGPS
        )
        do {
            let url = try await service.export { msg in
                Task { @MainActor in if !failed && folderURL == nil { status = msg } }
            }
            running = false
            folderURL = url
            Haptics.success()
            toastCenter.post("Folder export complete", kind: .success)
        } catch {
            running = false
            failed = true
            status = error.localizedDescription
            Haptics.error()
            toastCenter.post("Folder export failed", kind: .error)
        }
    }

    /// Trim the saved-to path so the user sees something readable rather
    /// than the full sandbox URL. We show the trailing two path components
    /// — the `Exports/` folder plus the dated export name.
    private func displayPath(for url: URL) -> String {
        let comps = url.pathComponents
        let tail = comps.suffix(3).joined(separator: "/")
        return "…/\(tail)"
    }

    /// Whether the export landed in iCloud or the local container affects
    /// where the user looks for it in Files. We sniff that by checking
    /// whether the storage root is under the iCloud ubiquity container.
    private func filesAppLocationHint() -> String {
        let path = store.rootURL.path
        if path.contains("Mobile Documents") || path.contains("CloudDocs") {
            return "iCloud Drive → SitePhoto → Exports"
        }
        return "On My iPhone → SitePhoto → Exports"
    }
}

/// Runs `AIAnalysisCSVExportService` and surfaces a ShareLink to the
/// resulting `.csv` file. CSV generation is synchronous — no image work,
/// no network — so we skip the progress UI used by the PDF / folder
/// runners and just show the result.
private struct AIAnalysisCSVExportRunner: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter

    @State private var exportURL: URL?
    @State private var failed: Bool = false
    @State private var status: String = ""
    @State private var ran: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if let url = exportURL {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("CSV ready")
                    .font(.headline)
                Text(summaryLine(for: url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                ShareLink(
                    item: url,
                    subject: Text(projectName),
                    message: Text("SitePhoto AI analysis CSV")
                ) {
                    Label("Share / Save CSV", systemImage: "square.and.arrow.up")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                Text("Also saved to \(filesAppLocationHint()) — open with Numbers, Excel, or any spreadsheet app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                Text("Export failed")
                    .font(.headline)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                ProgressView().controlSize(.large)
            }
            Spacer()
        }
        .navigationTitle("AI Analysis CSV")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !ran else { return }
            ran = true
            runExport()
        }
    }

    private var projectName: String {
        store.project(withID: projectID)?.name ?? "Export"
    }

    private func runExport() {
        guard let proj = store.project(withID: projectID) else {
            failed = true; status = "Project not found."; return
        }
        let analysedCount = proj.photos.filter {
            ($0.aiAnalysis?.parseFailed == false) && $0.aiAnalysis != nil
        }.count
        guard analysedCount > 0 else {
            failed = true
            status = "No AI-analysed photos in this project yet. Run AI tagging on at least one photo before exporting."
            return
        }
        let service = AIAnalysisCSVExportService(
            project: proj, tagLibrary: store.tagLibrary, store: store
        )
        guard let url = service.export() else {
            failed = true
            status = "Could not write the CSV. Check that the project storage folder is accessible."
            Haptics.error()
            toastCenter.post("CSV export failed", kind: .error)
            return
        }
        exportURL = url
        Haptics.success()
        toastCenter.post("CSV export complete", kind: .success)
    }

    private func summaryLine(for url: URL) -> String {
        let proj = store.project(withID: projectID)
        let count = proj?.photos.filter {
            ($0.aiAnalysis?.parseFailed == false) && $0.aiAnalysis != nil
        }.count ?? 0
        return "\(count) photo\(count == 1 ? "" : "s") exported to \(url.lastPathComponent)."
    }

    private func filesAppLocationHint() -> String {
        let path = store.rootURL.path
        if path.contains("Mobile Documents") || path.contains("CloudDocs") {
            return "iCloud Drive → SitePhoto → Exports"
        }
        return "On My iPhone → SitePhoto → Exports"
    }
}
