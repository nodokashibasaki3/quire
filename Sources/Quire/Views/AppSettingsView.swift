import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            CanvasSettingsView()
                .tabItem { Label("Canvas", systemImage: "graduationcap") }
        }
        .frame(width: 520, height: 360)
        .background(Color.paper)
        .preferredColorScheme(.light)
    }
}
