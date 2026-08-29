//
//  GoogleCalendarViewState.swift
//  AtollPluginManager
//
//  MainActor-observable bridge onto the (actor-isolated) GoogleCalendarConnection,
//  for SwiftUI to bind against. Mirrors ConnectionStatusModel's bridging idiom.
//

import SwiftUI

@MainActor
final class GoogleCalendarViewState: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var error: GoogleCalendarError?

    let connection: GoogleCalendarConnection

    init(connection: GoogleCalendarConnection) {
        self.connection = connection
    }
    func start() async {
        await connection.setOnStateChange { [weak self] in
            Task { await self?.refresh() }
        }
        await connection.start()
        clientSecretField = await connection.getClientSecret()
        await refresh()
    }

    func connect() {
        Task { await connection.connect() }
    }

    func disconnect() {
        Task { await connection.disconnect() }
    }

    /// The Client Secret field's binding -- backed by the connection's own
    /// Keychain-persisted value, read/written synchronously via a cached
    /// copy since SwiftUI text fields need a plain String binding, not an
    /// async round-trip on every keystroke.
    @Published var clientSecretField: String = "" {
        didSet {
            guard clientSecretField != oldValue else { return }
            let value = clientSecretField
            Task { await connection.setClientSecret(value) }
        }
    }

    private func refresh() async {
        isAuthenticated = await connection.isAuthenticated
        isAuthorizing = await connection.isAuthorizing
        error = await connection.error
    }
}
