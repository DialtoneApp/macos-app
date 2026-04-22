//
//  DialtoneAppApp.swift
//  DialtoneApp
//
//  Created by aa on 4/22/26.
//

import SwiftUI

@main
struct DialtoneAppApp: App {
    @StateObject private var model = BotShoppingModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("DialtoneApp Desktop", id: "main") {
            ContentView()
                .environmentObject(model)
                .containerBackground(.regularMaterial, for: .window)
        }
        .windowResizability(.contentMinSize)

        WindowGroup("Logs", id: "logs") {
            LogWindow()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open DialtoneApp Desktop") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("0", modifiers: [.command])

                Button("View Log") {
                    openWindow(id: "logs")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
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
