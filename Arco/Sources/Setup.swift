// What Arco needs before it can play, as a checklist at the top of the menu: its audio driver, the microphone permission
// (to read its own output), control of Music (and Spotify, when it is switched on), and the Enable in Roon. It shows while something is missing,
// each item with the one button that helps — and goes away when all is done.
import AppKit
import AVFoundation
import CoreServices
import SwiftUI
import ArcoRoon

@MainActor
final class SetupCheck: ObservableObject {
    enum Access { case granted, notAsked, denied }
    struct AppAccess: Identifiable {
        let name: String, bundleID: String, access: Access
        var id: String { bundleID }
    }

    @Published private(set) var driver = false
    @Published private(set) var microphone = Access.notAsked
    /// Per app that runs now ("Music", "Spotify"); an app that doesn't run can't be asked, and isn't listed.
    @Published private(set) var automation: [AppAccess] = []

    private static var apps: [(String, String)] {
        [("Music", "com.apple.Music")] + (Bridge.spotifyEnabled ? [("Spotify", "com.spotify.client")] : [])
    }

    func refresh() {
        driver = Bridge.driverInstalled
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notAsked
        default: microphone = .denied
        }
        Task {
            var found: [AppAccess] = []
            for (name, id) in Self.apps {
                if let access = await Self.automationAccess(id, ask: false) {
                    found.append(AppAccess(name: name, bundleID: id, access: access))
                }
            }
            automation = found
        }
    }

    /// Everything on the Mac's side is in place (Roon's Enable is the connection's own state).
    var macReady: Bool { driver && microphone == .granted && automation.allSatisfy { $0.access == .granted } }

    func allowMicrophone() {
        Task {
            if microphone == .notAsked { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            else { Self.openPrivacy("Privacy_Microphone") }
            refresh()
        }
    }

    func allowAutomation(_ bundleID: String, access: Access) {
        Task {
            if access == .notAsked { _ = await Self.automationAccess(bundleID, ask: true) }
            else { Self.openPrivacy("Privacy_Automation") }
            refresh()
        }
    }

    private static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether Arco may send Apple Events to the app; nil when the app doesn't run. Asking shows macOS's own question
    /// and waits for the answer — never on the main thread.
    private static func automationAccess(_ bundleID: String, ask: Bool) async -> Access? {
        await Task.detached {
            var target = AEAddressDesc()
            let made = bundleID.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
            guard made == noErr else { return nil }
            defer { AEDisposeDesc(&target) }
            switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
            case noErr: return .granted
            case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
            case OSStatus(errAEEventNotPermitted): return .denied
            default: return nil   // procNotFound: not running
            }
        }.value
    }
}

struct SetupList: View {
    @ObservedObject var setup: SetupCheck
    let connection: RoonConnection.State

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Get started").font(.caption).foregroundStyle(.secondary)
            item(done: setup.driver, "Audio driver",
                 setup.driver ? "Installed" : "Missing — run the Arco installer again")
            item(done: setup.microphone == .granted, "Microphone access",
                 "Arco reads its own audio output, nothing else",
                 button: Self.title(setup.microphone)) { setup.allowMicrophone() }
            ForEach(setup.automation) { app in
                item(done: app.access == .granted, "Control \(app.name)",
                     "To follow what plays and pass on Roon's buttons",
                     button: Self.title(app.access)) { setup.allowAutomation(app.bundleID, access: app.access) }
            }
            item(done: isPaired, "Enabled in Roon", roonLine)
        }
    }

    private var isPaired: Bool { if case .paired = connection { return true }; return false }

    private var roonLine: String {
        switch connection {
        case .searching: return "Looking for a Roon Core on your network"
        case .connecting(let name): return "Connecting to \(name)"
        case .waitingForAuthorization: return "In Roon, open Settings › Extensions and press Enable next to Arco"
        case .paired(let core): return "Connected to \(core.name)"
        }
    }

    /// The button for a permission: asking when macOS hasn't asked yet, the settings when it was refused.
    private static func title(_ access: SetupCheck.Access) -> String? {
        switch access {
        case .granted: return nil
        case .notAsked: return "Allow"
        case .denied: return "Open Settings"
        }
    }

    private func item(done: Bool, _ title: String, _ detail: String, button: String? = nil,
                      action: @escaping () -> Void = {}) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(done ? .regular : .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let button {
                Button(button, action: action).controlSize(.small)
            }
        }
    }
}
