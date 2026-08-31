import SwiftUI

/// App-wide settings. Right now: just the Anthropic API key used for AI
/// tagging. Designed to grow — sections can be added without restructuring.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(AuthService.self) private var auth
    @Environment(ManifestSyncer.self) private var syncer
    @Environment(PhotoSyncer.self) private var photoSyncer
    @Environment(AppConfigSyncer.self) private var appConfigSyncer
    @Environment(BinaryBackfillService.self) private var backfillService

    @State private var apiKey: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var saved: Bool = false
    @State private var showingBranding: Bool = false
    @State private var showingRulesTemplate: Bool = false
    @State private var showingTagLibrary: Bool = false

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
    @AppStorage("sitephoto.aiConcurrency") private var aiConcurrency: Int = 5

    /// Bound to `AITaggingModel.userDefaultsKey` so the picker, the
    /// batch runner, and `PhotoTagEditorSheet` all read the same value.
    /// Stored as the enum's `rawValue` for compatibility with
    /// `@AppStorage` (which doesn't accept arbitrary enums directly).
    @AppStorage(AITaggingModel.userDefaultsKey)
    private var aiModelRaw: String = AITaggingModel.sonnet.rawValue

    /// When on, AI tagging calls route through the Forensic backend
    /// (`POST /v1/ai/tag-photo`) instead of being made from the device
    /// against api.anthropic.com directly. Requires a signed-in Supabase
    /// session — without one the dispatch falls back to a clear error.
    /// Shared key with the batch runner + `PhotoTagEditorSheet` so the
    /// toggle's read/write sides can't drift.
    @AppStorage(Self.useBackendKey)
    private var useBackendAI: Bool = false

    /// Shared UserDefaults key for the backend-AI toggle. Same string
    /// is read by `ProjectStore.batchAITag(...)` and
    /// `PhotoTagEditorSheet.runClaude()`.
    static let useBackendKey: String = "sitephoto.aiTagging.useBackend"

    /// Minimum confidence required for a tag to render on the photo row,
    /// in the filter bar, in the tag-filter screen, and in the PDF. Tags
    /// below this score stay attached to the photo (so the user can lower
    /// the threshold to see them again later) but are hidden from view.
    @AppStorage("sitephoto.tagConfidenceThreshold")
    private var tagConfidenceThreshold: Double = 0.5

    var body: some View {
        NavigationStack {
            Form {
                // Build #5.131.1: three category dividers (Personal /
                // Team / Diagnostics) so the user can see at a glance
                // which group each section belongs to. Each divider is
                // a Section with only a Label inside — produces a
                // visually distinct grouped row.

                Section {
                    Label("Personal", systemImage: "person.crop.circle")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Settings that affect only your device.")
                }

                // Account first — most relevant identity info.
                Section("Account") {
                    if let email = auth.userEmail {
                        LabeledContent("Signed in as") {
                            Text(email)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        Task {
                            // Clear per-project server-revision cache and
                            // per-object upload cache so a subsequent user
                            // signing in on the same device doesn't try to
                            // reuse the previous user's revision tokens or
                            // skip uploads to a different R2 bucket.
                            syncer.resetRevisions()
                            photoSyncer.resetUploadCache()
                            appConfigSyncer.resetRevisions()
                            backfillService.reset()
                            try? await auth.signOut()
                            dismiss()
                        }
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                // Build #5.131.1: Sync section moved down to Diagnostics
                // cluster. Appearance moved up here so the Personal-side
                // settings sit together (account, API key, AI speed,
                // confidence filter, appearance).
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
                    if useBackendAI {
                        // Team-server mode (Build #5.52.1) — the device
                        // key isn't used. Show a clear "not needed"
                        // state rather than an active field the user
                        // might think they have to fill in. The field
                        // + Save / Remove are hidden; the stored key
                        // (if any) is preserved so flipping the toggle
                        // back off restores the device-key path
                        // without re-entry.
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Using team server — no device key needed")
                                    .foregroundStyle(.primary)
                                Text(hasStoredKey
                                     ? "A device key is on file and will be used again if you turn off \"Use team server for AI\" below."
                                     : "AI tagging runs on the Forensic backend with a shared key managed by your admin.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
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
                    }
                } header: {
                    Text("AI Tagging — Anthropic API Key")
                } footer: {
                    Text(useBackendAI
                         ? "AI tagging is set to run on the team server (toggle below). Your personal Anthropic key isn't used in this mode — the server bills a shared account. Turn off \"Use team server for AI\" to make calls from this device with your own key instead."
                         : "Required for the \"Suggest with AI\" button on photos. The key is stored in the device Keychain and never leaves the device except in calls to api.anthropic.com. Charges are billed to your Anthropic account at roughly half a cent per photo.")
                }

                Section {
                    Picker("Tagging model", selection: $aiModelRaw) {
                        ForEach(AITaggingModel.allCases) { model in
                            Text(model.displayName).tag(model.rawValue)
                        }
                    }
                    Text(currentModelSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(isOn: $useBackendAI) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use team server for AI")
                            Text(useBackendAI
                                 ? "Calls route through the Forensic backend (no device key needed)."
                                 : "Calls are made from this device using your Anthropic key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $aiConcurrency, in: 1...20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Parallel AI requests")
                            Text("\(aiConcurrency) at a time")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("AI Tagging Speed")
                } footer: {
                    Text("Tagging model: Sonnet is the careful default; Haiku is roughly 2× faster and 3–4× cheaper but may produce shorter captions and miss subtle distress.\n\nTeam server: when on, the photo is tagged by the Forensic backend using a shared Anthropic key — your device key isn't used or required. Requires sign-in.\n\nParallel requests: photos processed in flight during \"Auto-tag all photos.\" Higher values are faster but more likely to hit Anthropic's rate limit. Default 5 (safe for Tier 1 accounts on warm-cache batches, which run at ~10% of the uncached input cost). The app retries with backoff on rate-limit responses.")
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

                // Build #5.131.1: Team category divider.
                Section {
                    Label("Team", systemImage: "person.3.fill")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Settings that affect every project across all team members.")
                }

                Section {
                    Button {
                        showingRulesTemplate = true
                    } label: {
                        navigationRow(
                            title: "AI Tagging Rules",
                            subtitle: rulesTemplateSubtitle,
                            systemImage: "doc.plaintext"
                        )
                    }
                    .buttonStyle(.plain)
                    Button {
                        showingTagLibrary = true
                    } label: {
                        navigationRow(
                            title: "Tag Library",
                            subtitle: tagLibrarySubtitle,
                            systemImage: "books.vertical"
                        )
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("AI Tagging")
                } footer: {
                    Text("The rules block (schema + tagging rules) is the same for every project. The tag library is the three-level catalog of investigation contexts → primary tags → secondary tags each project picks from to scope its AI prompt.")
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

                // Build #5.131.1: Diagnostics category divider.
                Section {
                    Label("Diagnostics", systemImage: "stethoscope")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Manual sync, storage status, and version info.")
                }

                // Build #5.131.1: Sync moved down here from the top so
                // the Diagnostics cluster (Sync · Storage · Links · About)
                // sits together.
                Section {
                    Button {
                        Task {
                            toastCenter.post("Sync started…", kind: .info)
                            await appConfigSyncer.pullAllFromServer()
                            await syncer.pullAllFromServer()
                            await syncer.pushAllToServer()
                            await photoSyncer.syncAll()
                            await backfillService.backfillAll()
                            toastCenter.post("Sync sweep done.", kind: .info)
                        }
                    } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        Task {
                            toastCenter.post("Backfill started…", kind: .info)
                            await backfillService.backfillAll()
                        }
                    } label: {
                        Label("Backfill missing files", systemImage: "arrow.down.circle")
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Sync now: pulls the team's tag library and AI rules template, pushes any pending manifest changes, and uploads any photo / plan binaries that haven't reached R2 yet.\n\nBackfill missing files: only downloads photos / plans whose manifest is present locally but whose binary is missing (simulator, fresh install, restored device). Backfill summary toast and persistent chip in the projects-list footer surface the result.")
                }

                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: storageIconName)
                            .foregroundStyle(storageIconTint)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(storageHeadline)
                                .font(.subheadline.bold())
                            Text(storageSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                // Build version — useful for confirming the on-device
                // app matches the most recently pushed code. Regenerated
                // on every `ios/scripts/regen-project.sh` run. Build #
                // is the sequential number tracked in `docs/builds.md`;
                // when blank, the current worktree is older than the
                // build-tracking system.
                Section {
                    if !BuildInfo.buildNumber.isEmpty {
                        LabeledContent("Build #") {
                            Text(BuildInfo.buildNumber)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    HStack {
                        Label("Commit", systemImage: "hammer")
                        Spacer()
                        Text("\(BuildInfo.gitBranch)@\(BuildInfo.gitSHA) · \(BuildInfo.buildTime)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("About")
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
            .sheet(isPresented: $showingRulesTemplate) {
                AIRulesTemplateSheet()
                    .environment(store)
                    .environment(toastCenter)
            }
            .sheet(isPresented: $showingTagLibrary) {
                TagLibraryManagerSheet()
                    .environment(store)
                    .environment(toastCenter)
            }
            .onAppear { reload() }
        }
    }

    /// Shared row chrome for the new AI Tagging entries — keeps both
    /// rows visually consistent with the existing "Report Branding"
    /// chevron row above.
    @ViewBuilder
    private func navigationRow(title: String,
                                 subtitle: String,
                                 systemImage: String) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Storage-row branching mirrors the projects-list footer's
    /// (`StorageStatusFooter`) so the same three states render the
    /// same way in both places (Build #5.49.1).
    private var isOnBackend: Bool { auth.session != nil }
    private var storageIconName: String {
        if store.usingICloud { return "icloud.fill" }
        if isOnBackend { return "externaldrive.fill.badge.icloud" }
        return "iphone"
    }
    private var storageIconTint: Color {
        if store.usingICloud { return .blue }
        if isOnBackend { return .blue }
        return .orange
    }
    private var storageHeadline: String {
        if store.usingICloud {
            return isOnBackend ? "Synced via iCloud + backend" : "Synced via iCloud Drive"
        }
        if isOnBackend {
            return "Synced via backend (no iCloud)"
        }
        return "Local storage only"
    }
    private var storageSubtitle: String {
        if store.usingICloud {
            if isOnBackend {
                return "Projects sync to iCloud Drive AND the Forensic backend (Supabase + R2). Open Files app to browse the local copy, or AirDrop the folder to share."
            }
            return "Projects sync to iCloud Drive → SitePhoto. Open the Files app to browse them, or AirDrop the folder to share."
        }
        if isOnBackend {
            return "iCloud Drive is unavailable on this device, but your work syncs to the Forensic backend. Photos + plans backfill from R2 on launch so a fresh install / restored device fills in."
        }
        return store.iCloudUnavailableReason ?? "Sign in (Account section above) to back up to the Forensic team server."
    }

    private var rulesTemplateSubtitle: String {
        let trimmed = store.aiRulesTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultTrimmed = AIRulesTemplate.defaultText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == defaultTrimmed
            ? "Using bundled default"
            : "Customised"
    }

    private var currentModelSubtitle: String {
        let model = AITaggingModel(rawValue: aiModelRaw) ?? .sonnet
        return model.subtitle
    }

    private var tagLibrarySubtitle: String {
        let ctxCount = store.tagLibrary.contexts.count
        let primaryCount = store.tagLibrary.contexts
            .reduce(0) { $0 + $1.primaries.count }
        return "\(ctxCount) context\(ctxCount == 1 ? "" : "s"), \(primaryCount) primary tag\(primaryCount == 1 ? "" : "s")"
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
                                BaykalLogo(maxHeight: 56, maxWidth: nil)
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
        do {
            try KeychainStore.saveAnthropicKey(trimmed)
        } catch {
            saved = false
            toastCenter.post(error.localizedDescription, kind: .error)
            return
        }
        apiKey = ""
        hasStoredKey = true
        saved = true
    }

    private func clear() {
        do {
            try KeychainStore.clearAnthropicKey()
        } catch {
            toastCenter.post(error.localizedDescription, kind: .error)
            return
        }
        apiKey = ""
        hasStoredKey = false
        saved = false
    }
}

#Preview {
    SettingsSheet()
        .environment(ProjectStore())
        .environment(ToastCenter())
}
