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

    /// After an update Sparkle relaunches Arco without a word (René, 8 Oct: "the window just disappears"): when this
    /// version is newer than the one that ran last, say so once — with the way to the release notes. Not after a first
    /// install.
    static func announceIfUpdated() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let key = "LastRunVersion"
        let last = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(current, forKey: key)
        // No version remembered yet (0.1.4 and before didn't keep one): an update all the same when Arco was paired with
        // Roon before — a first install has no pairing yet.
        let paired = FileManager.default.fileExists(atPath: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arco/roon.json").path)
        guard !current.isEmpty, last.map({ $0.compare(current, options: .numeric) == .orderedAscending }) ?? paired else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Arco updated to \(current)"
            if let last { alert.informativeText = "From \(last)" }
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "What's New")
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "https://github.com/renebouwmeester/arco/releases/tag/v\(current)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)   // a menu bar app: bring Sparkle's window to the front
        controller?.checkForUpdates(nil)
    }
}
