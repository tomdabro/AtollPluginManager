//
//  AtollPluginManagerApp.swift
//  AtollPluginManager
//
//  Entry point. Runs as an `.accessory` app — no Dock icon, no Cmd+Tab
//  entry — since it's meant to sit in the background relaying plugins, not
//  be a visible app the user switches to. Its window starts hidden and is
//  brought back by Atoll's "App Permissions" row for this broker sending an
//  `atoll.showBrokerWindow` RPC notification (see `WindowVisibilityController`
//  and `AppDelegate` below), not by a Dock icon.
//

import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // SwiftUI has already created (and shown) the WindowGroup's window
        // by this point; hide it immediately rather than closing it, so the
        // same window instance -- with all its already-configured SwiftUI
        // state -- is what reappears on the next `showMainWindow()`.
        WindowVisibilityController.shared.hideMainWindow()
    }

    /// This is a background broker, not a document window app: closing its
    /// one window (red button) must not quit the process.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct AtollPluginManagerApp: App {
    /// This app's own identity when authorizing with Atoll. Atoll's
    /// "App Permissions" list shows exactly this one entry — plugins behind
    /// the broker are invisible to it.
    static let bundleIdentifier = "com.atollpluginmanager.broker"

    /// Identifies the sole `WindowGroup` scene so `WindowVisibilityController`
    /// can recreate the window via `openWindow(id:)` if it was fully closed
    /// (red button) rather than merely hidden.
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var connectionModel: ConnectionStatusModel
    @StateObject private var discovery: PluginDiscovery
    @StateObject private var connectionManager: PluginConnectionManager
    @StateObject private var googleCalendar: GoogleCalendarViewState

    init() {
        let client = AtollRPCClient(bundleIdentifier: AtollPluginManagerApp.bundleIdentifier)
        let statusModel = ConnectionStatusModel(client: client)
        _connectionModel = StateObject(wrappedValue: statusModel)
        let discovery = PluginDiscovery()
        _discovery = StateObject(wrappedValue: discovery)
        _connectionManager = StateObject(wrappedValue: PluginConnectionManager(
            discovery: discovery,
            relay: client,
            connectionStatus: statusModel,
            brokerBundleIdentifier: AtollPluginManagerApp.bundleIdentifier
        ))
        _googleCalendar = StateObject(wrappedValue: GoogleCalendarViewState(
            connection: GoogleCalendarConnection(relay: client, onLog: { message in
                FileHandle.standardError.write(Data("[GoogleCalendar] \(message)\n".utf8))
            }),
            connectionStatus: statusModel
        ))
        Task { await client.setOnShowWindow { WindowVisibilityController.shared.showMainWindow() } }
        LoginItemManager.shared.registerOnFirstLaunchIfNeeded()
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
                .environmentObject(connectionModel)
                .environmentObject(discovery)
                .environmentObject(connectionManager)
                .environmentObject(googleCalendar)
                .task {
                    await connectionModel.start()
                    discovery.start()
                    connectionManager.start()
                    await googleCalendar.start()
                }
        }
        .windowResizability(.contentSize)
    }
}
