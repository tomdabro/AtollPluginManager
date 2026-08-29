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

    @StateObject private var connectionModel: ConnectionStatusModel
    @StateObject private var discovery: PluginDiscovery
    @StateObject private var connectionManager: PluginConnectionManager

    init() {
        let client = AtollRPCClient(bundleIdentifier: AtollPluginManagerApp.bundleIdentifier)
        _connectionModel = StateObject(wrappedValue: ConnectionStatusModel(client: client))
        let discovery = PluginDiscovery()
        _discovery = StateObject(wrappedValue: discovery)
        _connectionManager = StateObject(wrappedValue: PluginConnectionManager(
            discovery: discovery,
            relay: client,
            brokerBundleIdentifier: AtollPluginManagerApp.bundleIdentifier
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionModel)
                .environmentObject(discovery)
                .environmentObject(connectionManager)
                .task {
                    await connectionModel.start()
                    discovery.start()
                    connectionManager.start()
                }
        }
        .windowResizability(.contentSize)
    }
}
