import SwiftUI

@main
struct SitePhotoApp: App {
    @State private var store = ProjectStore()
    @State private var location = LocationService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(location)
        }
    }
}
