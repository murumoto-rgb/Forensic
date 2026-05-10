import Foundation
import Observation

/// App-wide source of truth for transient banner notifications. Views call
/// `post(...)` from any action site (save, export, delete, …); the
/// `ToastBanner` overlay attached to the root content view observes
/// `currentToast` and renders the active banner with a fade in/out.
///
/// One toast at a time — posting a new one supersedes any in-flight banner
/// to keep the UI quiet. Toast lifetimes are short (≈2.5s for info, ≈4s
/// for warnings) so they don't linger on top of content the user is
/// trying to interact with.
@MainActor
@Observable
final class ToastCenter {
    var currentToast: Toast?

    private var dismissTask: Task<Void, Never>?

    func post(_ message: String,
              kind: Toast.Kind = .info,
              actionTitle: String? = nil,
              action: (@MainActor () -> Void)? = nil) {
        dismissTask?.cancel()
        let toast = Toast(message: message,
                           kind: kind,
                           actionTitle: actionTitle,
                           action: action)
        currentToast = toast
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.duration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.dismissIfMatches(id: toast.id)
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        currentToast = nil
    }

    private func dismissIfMatches(id: UUID) {
        guard currentToast?.id == id else { return }
        currentToast = nil
    }
}

/// One toast payload. Created by `ToastCenter.post(...)` and consumed by
/// the banner view. Actions are optional — a toast can be informational
/// only (no button) or actionable (e.g. an "Undo" button after a delete).
/// Carries a `@MainActor` action closure, so the type stays main-actor
/// scoped — never cross-actor sent.
struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let kind: Kind
    let actionTitle: String?
    let action: (@MainActor () -> Void)?

    enum Kind {
        case success
        case info
        case warning
        case error
    }

    var duration: TimeInterval {
        switch kind {
        case .success: return 2.0
        case .info:    return 2.5
        case .warning: return 4.0
        case .error:   return 4.5
        }
    }
}
