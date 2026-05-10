import SwiftUI

/// App-wide settings. Right now: just the Anthropic API key used for AI
/// tagging. Designed to grow — sections can be added without restructuring.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store

    @State private var apiKey: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var saved: Bool = false
    @State private var showingBranding: Bool = false

    /// Picker-bound accent hex. Drives the global tint via the matching
    /// `@AppStorage` binding in `SitePhotoApp`, so a change here ripples
    /// out to every screen instantly.
    @AppStorage(AppearanceSettings.accentColorKey)
    private var accentHex: String = AppearanceSettings.defaultAccentHex
    @AppStorage(AppearanceSettings.alternateIconKey)
    private var alternateIconName: String = ""

    /// Concurrency cap for the AI batch-tagging task group. Tier 1 Anthropic
    /// accounts have a 30k input-tokens/min cap, which 3 in flight stays
    /// under on sustained batches; higher tiers can go higher.
    @AppStorage("sitephoto.aiConcurrency") private var aiConcurrency: Int = 3

    /// Minimum confidence required for a tag to render on the photo row,
    /// in the filter bar, in the tag-filter screen, and in the PDF. Tags
    /// below this score stay attached to the photo (so the user can lower
    /// the threshold to see them again later) but are hidden from view.
    @AppStorage("sitephoto.tagConfidenceThreshold")
    private var tagConfidenceThreshold: Double = 0.5

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $apiKey, prompt: Text("Anthropic API key"))
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack {
                        Button("Save") { save() }
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        if hasStoredKey {
                            Button(role: .destructive) {
                                clear()
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .controlSize(.small)
                        }
                    }
                    if saved {
                        Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    } else if hasStoredKey {
                        Label("Key on file", systemImage: "key.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("AI Tagging — Anthropic API Key")
                } footer: {
                    Text("Required for the \"Suggest with AI\" button on photos. The key is stored in the device Keychain and never leaves the device except in calls to api.anthropic.com. Charges are billed to your Anthropic account at roughly half a cent per photo.")
                }

                Section {
                    Stepper(value: $aiConcurrency, in: 1...20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Parallel AI requests")
                            Text("\(aiConcurrency) at a time")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("AI Batch Tagging Speed")
                } footer: {
                    Text("Number of photos processed in parallel during \"Auto-tag all photos.\" Higher values are faster but more likely to hit Anthropic's rate limit. Default 3 (safe for Tier 1 accounts, which cap at 30,000 input tokens / minute). Bump higher if you have a Tier 2+ account; the app retries with backoff on rate-limit responses.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Minimum confidence")
                            Spacer()
                            Text("\(Int(tagConfidenceThreshold * 100))%")
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $tagConfidenceThreshold, in: 0...1, step: 0.05)
                    }
                } header: {
                    Text("Tag Confidence Filter")
                } footer: {
                    Text("Tags below this confidence are hidden from photo rows, the filter bar, the tag-filter screen, and the PDF — but they stay on the photo, so lowering the slider brings them back. Manually-typed tags are always 100%. AI-suggested tags carry whatever score Claude returned. Default 50%.")
                }

                Section {
                    Button {
                        showingBranding = true
                    } label: {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Report Branding")
                                    Text(store.reportBranding.hasContent
                                         ? "Customised"
                                         : "Using bundled Baykal logo + project name")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "doc.richtext.fill")
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Reports")
                } footer: {
                    Text("Customise the cover title / subtitle, footer line, and logo that appear on every exported PDF.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Accent Color")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        accentPicker
                    }
                    if !AppearanceSettings.alternateIcons.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("App Icon")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            iconPicker
                        }
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Accent color tints buttons, chips, selected markers, and other interactive elements. Restart not required.\(AppearanceSettings.alternateIcons.isEmpty ? "" : " Alternate app icons appear on the home screen once chosen.")")
                }

                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: store.usingICloud ? "icloud.fill" : "iphone")
                            .foregroundStyle(store.usingICloud ? .blue : .orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.usingICloud
                                 ? "Synced via iCloud Drive"
                                 : "Local storage only")
                                .font(.subheadline.bold())
                            if store.usingICloud {
                                Text("Projects sync to iCloud Drive → SitePhoto. Open the Files app to browse them, or AirDrop the folder to share.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let reason = store.iCloudUnavailableReason {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Storage")
                }

                Section {
                    Link("Get an API key →",
                         destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    Link("Anthropic pricing →",
                         destination: URL(string: "https://www.anthropic.com/pricing")!)
                    Link("Anthropic rate limits →",
                         destination: URL(string: "https://docs.anthropic.com/en/api/rate-limits")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingBranding) {
                ReportBrandingSheet().environment(store)
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        if let stored = KeychainStore.loadAnthropicKey(), !stored.isEmpty {
            // Don't pre-fill the SecureField with the stored key (privacy /
            // shoulder-surfing). Just indicate that one is on file.
            apiKey = ""
            hasStoredKey = true
        } else {
            apiKey = ""
            hasStoredKey = false
        }
        saved = false
    }

    /// Curated colour palette rendered as a wrapping row of round swatches.
    /// Tapping a swatch updates the @AppStorage-backed `accentHex`, which
    /// re-renders the tint at the app root in `SitePhotoApp.body`.
    @ViewBuilder
    private var accentPicker: some View {
        FlowLayout(spacing: 10) {
            ForEach(AppearanceSettings.accentPalette, id: \.hex) { entry in
                let isSelected = accentHex.lowercased() == entry.hex.lowercased()
                let color = Color(bucketHex: entry.hex) ?? .accentColor
                Button {
                    accentHex = entry.hex
                    Haptics.tap()
                } label: {
                    ZStack {
                        Circle()
                            .fill(color)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle().stroke(
                                    isSelected ? Color.primary : Color.primary.opacity(0.15),
                                    lineWidth: isSelected ? 2.5 : 0.5
                                )
                            )
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.name)
            }
        }
    }

    /// Alternate-icon swatches. Only shown when `AppearanceSettings.alternateIcons`
    /// is non-empty — i.e. when icon PNGs have actually been registered in
    /// the bundle. Picking one calls `setAlternateIconName` via
    /// `AppearanceSettings.setAlternateIcon(_:)`.
    @ViewBuilder
    private var iconPicker: some View {
        HStack(spacing: 12) {
            iconChoice(name: nil, displayName: "Default")
            ForEach(AppearanceSettings.alternateIcons, id: \.name) { entry in
                iconChoice(name: entry.name, displayName: entry.displayName)
            }
        }
    }

    @ViewBuilder
    private func iconChoice(name: String?, displayName: String) -> some View {
        let storedName: String? = alternateIconName.isEmpty ? nil : alternateIconName
        let isSelected = storedName == name
        Button {
            Task {
                await AppearanceSettings.setAlternateIcon(name)
                alternateIconName = name ?? ""
                Haptics.tap()
            }
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 56, height: 56)
                    .overlay(
                        // Show the bundled image (or "Default" placeholder
                        // glyph) so the user sees what they're picking.
                        Group {
                            if let name = name {
                                Image(name)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .padding(6)
                            } else {
                                Image("BaykalLogo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .padding(6)
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.accentColor : Color.clear,
                                     lineWidth: 2.5)
                    )
                Text(displayName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.saveAnthropicKey(trimmed)
        apiKey = ""
        hasStoredKey = true
        saved = true
    }

    private func clear() {
        KeychainStore.clearAnthropicKey()
        apiKey = ""
        hasStoredKey = false
        saved = false
    }
}

#Preview {
    SettingsSheet()
        .environment(ProjectStore())
}
