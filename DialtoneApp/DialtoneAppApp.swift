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
        WindowGroup("DialtoneApp", id: "main") {
            ContentView()
                .environmentObject(model)
                .containerBackground(.regularMaterial, for: .window)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open DialtoneApp") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }

        MenuBarExtra("DialtoneApp", systemImage: "sparkles") {
            MenuBarView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
