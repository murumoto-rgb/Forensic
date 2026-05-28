import SwiftUI
import PhotosUI
import UIKit

/// App-wide report branding editor: optional cover title / subtitle,
/// footer line that appears on every PDF page, and a logo image that
/// replaces the bundled `BaykalLogo` in the top-right of each page.
/// Saves on every change (debounced via focus-loss), so there's no
/// explicit "Save" button — just edit and dismiss.
struct ReportBrandingSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var coverTitle: String = ""
    @State private var coverSubtitle: String = ""
    @State private var footerText: String = ""
    @State private var logoItem: PhotosPickerItem?
    @State private var logoPreview: UIImage?
    @State private var loaded: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .center, spacing: 12) {
                        Group {
                            if let logo = logoPreview {
                                Image(uiImage: logo)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "building.2.crop.circle")
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 6) {
                            PhotosPicker(selection: $logoItem,
                                          matching: .images,
                                          photoLibrary: .shared()) {
                                Label("Choose Logo…", systemImage: "photo")
                            }
                            if logoPreview != nil {
                                Button(role: .destructive) {
                                    logoItem = nil
                                    logoPreview = nil
                                    _ = store.setBrandingLogo(nil)
                                } label: {
                                    Label("Remove Logo", systemImage: "trash")
                                        .font(.caption)
                                }
                            }
                        }
                        Spacer()
                    }
                } header: {
                    Text("Logo")
                } footer: {
                    Text("Replaces the bundled Baykal logo on every page of exported PDFs. PNG or JPG, any size — it's scaled down automatically. Leave blank to fall back to the bundled logo.")
                }

                Section {
                    TextField("Cover title (e.g. firm name)",
                              text: $coverTitle, axis: .vertical)
                        .lineLimit(1...2)
                        .onSubmit { saveText() }
                    TextField("Cover subtitle (e.g. address, license #)",
                              text: $coverSubtitle, axis: .vertical)
                        .lineLimit(1...3)
                        .onSubmit { saveText() }
                } header: {
                    Text("Cover Page")
                } footer: {
                    Text("Shown above the project name on the PDF cover. Leave blank to use the project name alone.")
                }

                Section {
                    TextField("Footer line (e.g. firm phone, web)",
                              text: $footerText, axis: .vertical)
                        .lineLimit(1...2)
                        .onSubmit { saveText() }
                } header: {
                    Text("Page Footer")
                } footer: {
                    Text("Appears as a thin line at the bottom of every PDF page. Leave blank to omit.")
                }

                if store.reportBranding.hasContent {
                    Section {
                        Button(role: .destructive) {
                            coverTitle = ""
                            coverSubtitle = ""
                            footerText = ""
                            _ = store.setBrandingLogo(nil)
                            logoPreview = nil
                            logoItem = nil
                            _ = store.updateBranding(.empty)
                        } label: {
                            Label("Clear All Branding", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Report Branding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        saveText()
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                coverTitle = store.reportBranding.coverTitle ?? ""
                coverSubtitle = store.reportBranding.coverSubtitle ?? ""
                footerText = store.reportBranding.footerText ?? ""
                if let url = store.brandingLogoURL,
                   let data = try? Data(contentsOf: url),
                   let img = UIImage(data: data) {
                    logoPreview = img
                }
                loaded = true
            }
            .onChange(of: logoItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadLogo(from: newItem) }
            }
        }
    }

    private func saveText() {
        var branding = store.reportBranding
        branding.coverTitle = coverTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        branding.coverSubtitle = coverSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        branding.footerText = footerText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        _ = store.updateBranding(branding)
    }

    private func loadLogo(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        _ = store.setBrandingLogo(image)
        logoPreview = image
    }
}

private extension String {
    /// Returns `nil` when the string is empty after trimming, otherwise self.
    /// Lets the branding model keep blank fields as nil rather than `""`,
    /// which simplifies `hasContent` and rendering checks.
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
