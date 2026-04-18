import SwiftUI

/// Root content view. Phase 1 stub — the matrix view, single-image
/// view, and autonomous-mode overlay will be wired in as their
/// respective features land.
struct ContentView: View {

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)

            Text("Allsky ML Curator")
                .font(.title)

            Text("Phase 1 — foundation in progress.\nIngest, ephemeris and classifier pipeline coming next.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .frame(width: 1200, height: 800)
}
