//
//  LoginItemManager.swift
//  AtollPluginManager
//
//  Registers this app to launch at login via `SMAppService.mainApp` (macOS
//  13+, no separate login-helper target needed since the app registers
//  itself). It runs `.accessory` and hidden (see `WindowVisibilityController`),
//  so launching at login is what actually gets the broker relaying plugins
//  without the user having to remember to start it by hand.
//

import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    /// Sentinel so the one-time default registration (see
    /// `registerOnFirstLaunchIfNeeded`) never re-fires and overrides a user
    /// who deliberately turned the toggle off afterwards.
    private static let hasConfiguredKey = "AtollPluginManager.hasConfiguredLoginItem"

    @Published private(set) var isEnabled: Bool

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Called once at launch. On this app's very first run it enables
    /// "Launch at Login" by default; every run after that is a no-op even if
    /// the user has since disabled it, since `SMAppService`'s own state (not
    /// this method) is the source of truth from then on.
    func registerOnFirstLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.hasConfiguredKey) else { return }
        defaults.set(true, forKey: Self.hasConfiguredKey)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[LoginItemManager] Failed to \(enabled ? "register" : "unregister"): \(error.localizedDescription)\n".utf8
            ))
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
