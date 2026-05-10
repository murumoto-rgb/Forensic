import SwiftUI

/// Floating banner that surfaces the current toast from `ToastCenter`.
/// Attached as a `.safeAreaInset(edge: .top)` overlay (or via `.overlay`
/// directly) on the root content view. Renders nothing when there's no
/// active toast.
struct ToastBanner: View {
    @Environment(ToastCenter.self) private var toastCenter

    var body: some View {
        VStack {
            if let toast = toastCenter.currentToast {
                bannerView(for: toast)
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.22), value: toastCenter.currentToast?.id)
        .allowsHitTesting(toastCenter.currentToast != nil)
    }

    @ViewBuilder
    private func bannerView(for toast: Toast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: toast.kind))
                .font(.title3)
                .foregroundStyle(.white)
            Text(toast.message)
                .font(.callout)
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button(actionTitle) {
                    action()
                    toastCenter.dismiss()
                }
                .font(.callout.bold())
                .foregroundStyle(.white)
            }
            Button {
                toastCenter.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            background(for: toast.kind),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
    }

    private func icon(for kind: Toast.Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    private func background(for kind: Toast.Kind) -> Color {
        switch kind {
        case .success: return Color.green.opacity(0.92)
        case .info:    return Color(red: 0.10, green: 0.40, blue: 0.70)
        case .warning: return Color.orange.opacity(0.95)
        case .error:   return Color(red: 0.78, green: 0.20, blue: 0.20)
        }
    }
}
