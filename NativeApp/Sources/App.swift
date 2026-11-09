import AppKit
import SwiftUI

@main
struct OpenTangerineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settingsTabs = SettingsTabModel()

    var body: some Scene {
        Settings {
            SettingsView(model: settingsTabs)
                .environmentObject(AppSettings.shared)
        }
    }
}
