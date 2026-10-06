// Arco — Apple Music and Spotify on your Roon zones, from the menu bar.
import SwiftUI

@main
struct ArcoApp: App {
    @StateObject private var model = ArcoModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image("MenuIcon")   // a template: macOS tints it for a light or dark menu bar
        }
        .menuBarExtraStyle(.window)
    }
}
