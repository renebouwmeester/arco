// Updates through Sparkle: the feed is the appcast.xml of the latest GitHub Release, an update is the next signed and
// notarized installer package (it brings the driver along). Sparkle only starts with a public EdDSA key in Info.plist —
// a build without one (a fork, a test) simply has no updates.
import AppKit
import Sparkle

@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = key.isEmpty ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    // During an update Arco is an ordinary app, with a Dock icon (Sparkle's advice for menu bar apps): after the Touch ID or
    // password question macOS gives the focus back to the app that was in front, and a menu bar app's update window was
    // then hard to find again (René, 8 Oct). Back to the menu bar when the update session ends.
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            watchForAuthorization()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            authorizationWatch?.invalidate(); authorizationWatch = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// The Touch ID / password question is another process; when it goes, macOS activates the app that was in front
    /// before. Seen it come and go, with Arco not in front: Arco comes back once, with its update window.
    private var authorizationWatch: Timer?
    private func watchForAuthorization() {
        authorizationWatch?.invalidate()
        var sawQuestion = false
        let started = Date()
        authorizationWatch = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let front = NSWorkspace.shared.frontmostApplication
                let id = front?.bundleIdentifier ?? ""
                let asking = id == "com.apple.SecurityAgent" || id.hasPrefix("com.apple.LocalAuthentication")
                    || id == "com.apple.coreautha" || (front?.localizedName ?? "").contains("SecurityAgent")
                if asking { sawQuestion = true; return }
                if sawQuestion, front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    NSApp.activate(ignoringOtherApps: true)
                    timer.invalidate(); self?.authorizationWatch = nil
                } else if Date().timeIntervalSince(started) > 600 {
                    timer.invalidate(); self?.authorizationWatch = nil
                }
            }
        }
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
