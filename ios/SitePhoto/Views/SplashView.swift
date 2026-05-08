import SwiftUI

/// Brief launch animation that fades the Baykal Consulting logo in,
/// holds it on screen for a moment, then fades it out and signals the
/// parent (the App scene) to show the main UI.
struct SplashView: View {
    let onFinished: () -> Void

    @State private var logoOpacity: Double = 0
    @State private var logoScale: CGFloat = 0.92

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Image("BaykalLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280)
                .opacity(logoOpacity)
                .scaleEffect(logoScale)
                .accessibilityLabel("Baykal Consulting")
        }
        .task {
            // Fade in.
            withAnimation(.easeOut(duration: 0.45)) {
                logoOpacity = 1
                logoScale = 1
            }
            // Hold.
            try? await Task.sleep(for: .milliseconds(900))
            // Fade out.
            withAnimation(.easeIn(duration: 0.35)) {
                logoOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(380))
            onFinished()
        }
    }
}
