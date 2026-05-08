import SwiftUI

@main
struct SitePhotoApp: App {
    @State private var store = ProjectStore()
    @State private var location = LocationService()
    @State private var splashFinished = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                if splashFinished {
                    ContentView()
                        .environment(store)
                        .environment(location)
                        .transition(.opacity)
                } else {
                    SplashView {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            splashFinished = true
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}
