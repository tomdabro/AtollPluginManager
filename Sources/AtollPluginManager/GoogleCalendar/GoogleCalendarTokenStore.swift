//
//  GoogleCalendarTokenStore.swift
//  AtollPluginManager
//
//  Keychain-backed storage for the OAuth token pair and client secret.
//

import Foundation
import Security

enum GoogleCalendarTokenAccount: String {
    case accessToken = "google-calendar-access-token"
    case refreshToken = "google-calendar-refresh-token"
    /// Google's "Desktop app" OAuth clients still issue a client secret and
    /// require it in every token exchange, even though PKCE makes it
    /// non-confidential for an installed app. Kept in the Keychain alongside
    /// the tokens rather than in UserDefaults since it's still credential material.
    case clientSecret = "google-calendar-client-secret"
}

protocol GoogleCalendarTokenStoring: Sendable {
    func read(_ account: GoogleCalendarTokenAccount) -> String?
    /// Returns the Keychain status; `errSecSuccess` means the value is stored.
    @discardableResult func write(_ value: String, account: GoogleCalendarTokenAccount) -> OSStatus
    @discardableResult func delete(_ account: GoogleCalendarTokenAccount) -> OSStatus
}

/// Keychain-backed storage for the OAuth token pair and client secret. The
/// client ID and token expiration are not secrets and stay in UserDefaults
/// (see `GoogleCalendarPreferences`).
struct KeychainGoogleCalendarTokenStore: GoogleCalendarTokenStoring {
    private static let service = "com.atollpluginmanager.GoogleCalendar"

    private func baseQuery(for account: GoogleCalendarTokenAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account.rawValue
        ]
    }

    func read(_ account: GoogleCalendarTokenAccount) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func write(_ value: String, account: GoogleCalendarTokenAccount) -> OSStatus {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(for: account) as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else {
            return status
        }
        var attributes = baseQuery(for: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    @discardableResult
    func delete(_ account: GoogleCalendarTokenAccount) -> OSStatus {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        // Nothing stored is a successful end state for a delete.
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}
