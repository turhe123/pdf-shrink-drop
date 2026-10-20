import SwiftUI
import AppKit

/// Entry point: a single main window, a Settings window and the File / Help menu commands.
@main
struct PdfShrinkDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = JobStore.shared

    var body: some Scene {
        Window("PdfShrinkDrop", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDFs…") { store.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Support / Donate ❤️") { Links.openDonate() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

/// Receives files dropped on the Dock icon or opened via Finder / `open -a`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        JobStore.shared.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// External links used by the app.
enum Links {
    static func openDonate() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}
