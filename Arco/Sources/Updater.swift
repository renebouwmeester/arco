// Updates through Sparkle: the feed is the appcast.xml of the latest GitHub Release, an update is the next signed and
// notarized installer package (it brings the driver along). Sparkle only starts with a public EdDSA key in Info.plist —
// a build without one (a fork, a test) simply has no updates.
import AppKit
import Sparkle

@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = key.isEmpty ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var available: Bool { controller != nil }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)   // a menu bar app: bring Sparkle's window to the front
        controller?.checkForUpdates(nil)
    }
}
