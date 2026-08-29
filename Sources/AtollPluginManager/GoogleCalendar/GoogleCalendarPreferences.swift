//
//  GoogleCalendarPreferences.swift
//  AtollPluginManager
//
//  Non-secret Google Calendar settings (client ID, token expiry). The OAuth
//  token pair and client secret live in the Keychain -- see
//  GoogleCalendarTokenStore. Matches PluginPreferences.swift's plain
//  UserDefaults convention.
//

import Foundation

enum GoogleCalendarPreferences {
    private static let clientIDKey = "googleCalendarClientID"
    private static let tokenExpirationKey = "googleCalendarTokenExpiration"
    private static let enabledKey = "googleCalendarEnabled"

    static func clientID() -> String {
        UserDefaults.standard.string(forKey: clientIDKey) ?? ""
    }

    static func setClientID(_ value: String) {
        UserDefaults.standard.set(value, forKey: clientIDKey)
    }

    static func tokenExpiration() -> TimeInterval {
        UserDefaults.standard.double(forKey: tokenExpirationKey)
    }

    static func setTokenExpiration(_ value: TimeInterval) {
        UserDefaults.standard.set(value, forKey: tokenExpirationKey)
    }

    /// Pausing (toggling off) stops polling and unregisters the calendar
    /// source from Atoll without clearing the OAuth token pair, so turning
    /// it back on resumes immediately -- no reconnect needed. Defaults to
    /// true (never explicitly set) so an existing connected user isn't
    /// silently paused by this key's introduction.
    static func isEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
    }
}
