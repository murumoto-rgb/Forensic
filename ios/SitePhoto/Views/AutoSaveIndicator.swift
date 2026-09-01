import SwiftUI

/// Tiny chip that confirms recent save activity. Sits in the project
/// detail toolbar and stays invisible most of the time — it only briefly
/// flashes "Saved" after `ProjectStore.lastSavedAt` updates, so the
/// engineer gets a subtle reassurance that their last edit is durable.
///
/// We hook on `lastSavedAt` rather than `isSaving` because save() is
/// synchronous and the in-progress state would never linger long enough
/// to be readable. The completion timestamp gives us a stable change to
/// observe per save.
struct AutoSaveIndicator: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store

    @State private var showConfirm: Bool = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if store.saveFailures[projectID] != nil {
                Button {
                    store.retryPendingSave(projectID: projectID)
                } label: {
                    Label("Not saved · Retry", systemImage: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .accessibilityHint("Changes remain in memory. Keep the app open until they are saved.")
            } else if showConfirm {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved locally")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .animation(.easeInOut(duration: 0.18), value: showConfirm)
        .onChange(of: store.lastSavedAt) { _, newValue in
            guard newValue != nil else { return }
            showConfirm = true
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                showConfirm = false
            }
        }
    }
}
