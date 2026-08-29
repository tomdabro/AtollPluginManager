//
//  GoogleCalendarViewState.swift
//  AtollPluginManager
//
//  MainActor-observable bridge onto the (actor-isolated) GoogleCalendarConnection,
//  for SwiftUI to bind against. Mirrors ConnectionStatusModel's bridging idiom.
//

import Combine
import SwiftUI

@MainActor
final class GoogleCalendarViewState: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var error: GoogleCalendarError?
    @Published private(set) var isEnabled = true

    let connection: GoogleCalendarConnection
    private let connectionStatus: ConnectionStatusModel
    private var atollStateCancellable: AnyCancellable?

    init(connection: GoogleCalendarConnection, connectionStatus: ConnectionStatusModel) {
        self.connection = connection
        self.connectionStatus = connectionStatus
    }

    func start() async {
        await connection.setOnStateChange { [weak self] in
            Task { await self?.refresh() }
        }
        await connection.start()
        clientSecretField = await connection.getClientSecret()
        await refresh()

        // Same reasoning as PluginConnectionManager's resync: a still-
        // authenticated connection never gets a reason to re-register just
        // because Atoll itself restarted -- resync on every fresh
        // authorization (first connect, Atoll relaunch, sleep/wake, or any
        // dropped-connection reconnect).
        atollStateCancellable = connectionStatus.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard state == .authorized else { return }
                Task { await self?.connection.resyncRegistration() }
            }
    }

    func connect() {
        Task { await connection.connect() }
    }

    func disconnect() {
        Task { await connection.disconnect() }
    }

    func setEnabled(_ enabled: Bool) {
        Task { await connection.setEnabled(enabled) }
    }

    @Published private(set) var isRefreshing = false

    func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await connection.refreshNow()
            isRefreshing = false
        }
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
        isEnabled = await connection.isEnabled
    }
}
