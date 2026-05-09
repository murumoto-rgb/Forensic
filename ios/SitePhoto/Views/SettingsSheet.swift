import SwiftUI

/// App-wide settings. Right now: just the Anthropic API key used for AI
/// tagging. Designed to grow — sections can be added without restructuring.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var saved: Bool = false

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
                    Link("Get an API key →",
                         destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    Link("Anthropic pricing →",
                         destination: URL(string: "https://www.anthropic.com/pricing")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
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
}
