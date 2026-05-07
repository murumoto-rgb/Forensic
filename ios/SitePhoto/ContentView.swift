import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.matrix")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)

            Text("SitePhoto")
                .font(.largeTitle.bold())

            Text("Native iOS — first build")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("v0.1.0")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.top, 32)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
