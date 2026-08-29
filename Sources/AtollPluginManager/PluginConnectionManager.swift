//
//  PluginConnectionManager.swift
//  AtollPluginManager
//
//  Bridges PluginDiscovery (what plugins exist) to PluginConnection (talking
//  to each one): starts a connection for every newly-discovered manifest,
//  stops it when the manifest disappears or changes.
//

import Foundation
import Combine

@MainActor
final class PluginConnectionManager: ObservableObject {
    @Published private(set) var connectedPluginIDs: Set<String> = []

    private let discovery: PluginDiscovery
    private let relay: any ActivityRelay
    private let brokerBundleIdentifier: String
    private var connections: [String: PluginConnection] = [:]
    private var cancellable: AnyCancellable?

    init(discovery: PluginDiscovery, relay: any ActivityRelay, brokerBundleIdentifier: String) {
        self.discovery = discovery
        self.relay = relay
        self.brokerBundleIdentifier = brokerBundleIdentifier
    }

    func start() {
        cancellable = discovery.$plugins
            .receive(on: DispatchQueue.main)
            .sink { [weak self] plugins in
                self?.reconcile(with: plugins)
            }
    }

    /// Starts a `PluginConnection` for each manifest not already connected,
    /// and stops any whose manifest disappeared or changed (e.g. socket path
    /// edited) — reconnecting on the new definition rather than the stale one.
    private func reconcile(with plugins: [String: DiscoveredPlugin]) {
        let currentIDs = Set(plugins.keys)
        let knownIDs = Set(connections.keys)

        for removedID in knownIDs.subtracting(currentIDs) {
            stopConnection(for: removedID)
        }

        for id in currentIDs {
            guard let plugin = plugins[id] else { continue }
            if connections[id] == nil {
                startConnection(for: plugin)
            }
        }

        connectedPluginIDs = currentIDs
    }

    private func startConnection(for plugin: DiscoveredPlugin) {
        let connection = PluginConnection(
            plugin: plugin,
            brokerBundleIdentifier: brokerBundleIdentifier,
            relay: relay,
            onLog: { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
        )
        connections[plugin.manifest.id] = connection
        Task { await connection.start() }
    }

    private func stopConnection(for id: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        Task { await connection.stop() }
    }
}
