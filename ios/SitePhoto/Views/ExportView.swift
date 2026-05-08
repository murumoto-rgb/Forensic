import SwiftUI

struct ExportView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var status = "Preparing…"
    @State private var exportURL: URL?
    @State private var failed = false

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Export PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
        let service = PDFExportService(project: proj, store: store)
        let url = await service.buildPDF { msg in
            Task { @MainActor in status = msg }
        }
        if let url {
            exportURL = url
        } else {
            failed = true
            status = "Could not build the PDF. Check that photos are accessible."
        }
    }
}
