// "Uninstall Arco…": the app and its audio driver go (with an administrator password), Core Audio restarts without the
// driver, and Arco's own files go too — its Roon pairing, settings, log and permissions. Roon keeps listing the extension
// until it is removed there; the question says so.
import AppKit
import ServiceManagement

@MainActor
enum Uninstaller {
    static func run(bridge: Bridge) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Uninstall Arco?"
        alert.informativeText = "This removes Arco and its audio driver, and restarts the Mac's audio for a moment — "
            + "Arco stays listed in Roon's Settings › Extensions until you remove it there"
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Only an app bundle called Arco.app is removed, never whatever path this happens to run from.
        let app = Bundle.main.bundleURL
        guard app.lastPathComponent == "Arco.app", app.pathComponents.count > 2 else {
            Log.note("uninstall: not from an Arco.app (\(app.path))")
            return
        }
        bridge.turnOff()   // the Mac's own output back first
        try? SMAppService.mainApp.unregister()
        let shell = [
            "rm -rf '/Library/Audio/Plug-Ins/HAL/Arco.driver'",
            "pkgutil --forget nl.renebouwmeester.arco.pkg > /dev/null 2>&1",
            "killall coreaudiod",
            "rm -rf \(quoted(app.path))",
            "true",
        ].joined(separator: "; ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        Log.note("uninstall: removing the driver and the app")
        // The password question waits for the user: a long time limit.
        guard AppleScript.run("do shell script \"\(escaped)\" with administrator privileges", seconds: 600) != nil else {
            Log.note("uninstall: cancelled or failed")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in ["Library/Application Support/Arco", "Library/Logs/Arco"] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(path, isDirectory: true))
        }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            for service in ["Microphone", "AppleEvents"] {
                let reset = Process()
                reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                reset.arguments = ["reset", service, id]
                try? reset.run(); reset.waitUntilExit()
            }
        }
        NSApp.terminate(nil)
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
