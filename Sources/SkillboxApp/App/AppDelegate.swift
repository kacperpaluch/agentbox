import SwiftUI
import SkillboxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); Task { @MainActor in NSApp.windows.first?.makeKeyAndOrderFront(nil) } }
}
