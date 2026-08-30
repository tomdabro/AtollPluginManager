//
//  WindowVisibilityController.swift
//  AtollPluginManager
//
//  This app runs as an `.accessory` (no Dock icon, no Cmd+Tab entry) so it
//  doesn't clutter the Dock/app switcher while it sits in the background
//  relaying plugins. That means the usual way back to its window — clicking
//  a Dock icon — doesn't exist, so Atoll's "App Permissions" row for this
//  broker sends an `atoll.showBrokerWindow` RPC notification instead (see
//  `AtollRPCClient.setOnShowWindow`), which calls `showMainWindow()` here.
//

import AppKit
import SwiftUI

@MainActor
final class WindowVisibilityController {
    static let shared = WindowVisibilityController()

    private init() {}

    /// Captured from `ContentView`'s environment so the window can be
    /// recreated if it was fully closed (red button) rather than merely
    /// ordered out — `NSApp.windows` would otherwise be empty and there'd be
    /// no way back short of relaunching the process.
    var openWindow: OpenWindowAction?

    /// Hides the WindowGroup's window that SwiftUI opens automatically at
    /// launch. Ordered out rather than closed so the existing window (and
    /// its already-configured SwiftUI state) can simply be reshown later.
    func hideMainWindow() {
        NSApp.windows.first?.orderOut(nil)
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(id: AtollPluginManagerApp.mainWindowID)
        }
    }
}
