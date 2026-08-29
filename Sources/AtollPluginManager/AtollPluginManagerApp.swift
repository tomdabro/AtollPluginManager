//
//  AtollPluginManagerApp.swift
//  AtollPluginManager
//
//  Entry point. Regular app with a main window (Dock icon, standard window) —
//  not a menu-bar-only agent.
//

import SwiftUI

@main
struct AtollPluginManagerApp: App {
    /// This app's own identity when authorizing with Atoll. Atoll's
    /// "App Permissions" list shows exactly this one entry — plugins behind
    /// the broker are invisible to it.
    static let bundleIdentifier = "com.atollpluginmanager.broker"

    @StateObject private var connectionModel = ConnectionStatusModel(
        client: AtollRPCClient(bundleIdentifier: AtollPluginManagerApp.bundleIdentifier)
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionModel)
                .task {
                    await connectionModel.start()
                }
        }
        .windowResizability(.contentSize)
    }
}
