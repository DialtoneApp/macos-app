import AppKit
import SwiftUI

extension Notification.Name {
    static let dialtoneAppOpenURL = Notification.Name("dialtoneAppOpenURL")
}

@MainActor
enum DialtoneAppOpenURLInbox {
    private static var pendingURLs: [URL] = []

    static func enqueue(_ url: URL) {
        pendingURLs.append(url)
        NotificationCenter.default.post(name: .dialtoneAppOpenURL, object: url)
    }

    static func drain() -> [URL] {
        defer { pendingURLs = [] }
        return pendingURLs
    }

    static func markHandled(_ url: URL) {
        pendingURLs.removeAll { $0 == url }
    }
}

@MainActor
enum DialtoneAppWindowManager {
    static func focusMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let mainWindows = NSApplication.shared.windows.filter { window in
            window.title == "DialtoneApp Desktop" && window.isVisible
        }

        for duplicateWindow in mainWindows.dropFirst() {
            duplicateWindow.close()
        }

        if let mainWindow = mainWindows.first {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class DialtoneAppOpenURLDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DialtoneAppOpenURLInbox.enqueue(url)
        }
        DialtoneAppWindowManager.focusMainWindow()
    }
}

@main
struct DialtoneAppApp: App {
    @NSApplicationDelegateAdaptor(DialtoneAppOpenURLDelegate.self) private var openURLDelegate
    @StateObject private var model = BotShoppingModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("DialtoneApp Desktop", id: "main") {
            ContentView()
                .environmentObject(model)
                .containerBackground(.regularMaterial, for: .window)
        }
        .windowResizability(.contentMinSize)

        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open DialtoneApp Desktop") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("0", modifiers: [.command])

                Button("Log Out") {
                    model.logOut()
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .onAppear {
                    model.markCandidatesSeen()
                }
        } label: {
            MenuBarLabel(unseenCount: model.unseenCandidateCount)
        }
        .menuBarExtraStyle(.window)
    }
}
