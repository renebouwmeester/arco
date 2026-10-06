// "Open at login": Arco as a login item of the user, through SMAppService — off until the user switches it on. When
// macOS wants the user's approval first (status requiresApproval), the switch opens System Settings › Login Items.
import ServiceManagement
import SwiftUI

struct LoginItemToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { on }, set: { set($0) }))
            .toggleStyle(.checkbox)
            .onAppear { on = SMAppService.mainApp.status == .enabled }
    }

    private func set(_ wanted: Bool) {
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.note("login item: \(error.localizedDescription)")
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        on = SMAppService.mainApp.status == .enabled
    }
}
