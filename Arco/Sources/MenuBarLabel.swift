// The menu bar item (0.3.1, René: "de samplerate in de menubar naast het icoon"): Arco's icon, and while Arco sends to
// Roon the rate Roon receives next to it — "44.1", "96", "192" — so the clock per track shows without opening the menu.
// Next to the icon, not instead of it: the icon is Arco's, and with nothing sent there is no rate. A checkbox in the menu
// turns it off.
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var bridge: Bridge
    @AppStorage(Self.key) private var showRate = true
    static let key = "ShowRateInMenuBar"

    var body: some View {
        HStack(spacing: 2) {
            Image("MenuIcon")   // a template: macOS tints it for a light or dark menu bar
            if showRate, bridge.isSending, let rate = bridge.rate, rate > 0 {
                Text(Self.short(rate)).monospacedDigit()
            }
        }
    }

    /// 44100 → "44.1", 96000 → "96".
    static func short(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz.rounded() == khz ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
    }
}

struct RateInMenuBarToggle: View {
    @AppStorage(MenuBarLabel.key) private var showRate = true

    var body: some View {
        Toggle("Show sample rate in menu bar", isOn: $showRate)
            .toggleStyle(.checkbox)
    }
}
