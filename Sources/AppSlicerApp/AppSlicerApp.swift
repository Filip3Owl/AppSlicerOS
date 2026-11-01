import AppKit
import SwiftUI

@main
struct AppSlicerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        Window("AppSlicerOS", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 1_080, height: 760)
        .commands {
            CommandGroup(before: .sidebar) {
                ForEach(AppSection.allCases) { section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(section.shortcut, modifiers: .command)
                }
                Divider()
            }
        }

        MenuBarExtra("AppSlicerOS", systemImage: "memorychip") {
            MenuBarView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed while the app runs from `swift run`, outside an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The menu bar item stays available after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
