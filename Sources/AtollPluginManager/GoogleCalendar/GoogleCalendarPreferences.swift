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
}
