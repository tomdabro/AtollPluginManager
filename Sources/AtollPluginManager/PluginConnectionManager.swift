//
//  PluginConnectionManager.swift
//  AtollPluginManager
//
//  Bridges PluginDiscovery (what plugins exist) to PluginConnection (talking
//  to each one): starts a connection for every newly-discovered, enabled
//  manifest, stops it when the manifest disappears, changes, or the user
//  disables it in Settings.
//

import Foundation
import Combine

@MainActor
final class PluginConnectionManager: ObservableObject {
    /// Plugins with an active (or connecting) `PluginConnection` — i.e.
    /// discovered and enabled, regardless of whether the socket is actually
    /// up yet.
    @Published private(set) var connectedPluginIDs: Set<String> = []
    @Published private(set) var disabledPluginIDs: Set<String> = PluginPreferences.disabledPluginIDs()

    private let discovery: PluginDiscovery
    private let relay: any ActivityRelay
    private let brokerBundleIdentifier: String
    private var connections: [String: PluginConnection] = [:]
    private var cancellable: AnyCancellable?
    private var latestPlugins: [String: DiscoveredPlugin] = [:]

    init(discovery: PluginDiscovery, relay: any ActivityRelay, brokerBundleIdentifier: String) {
        self.discovery = discovery
        self.relay = relay
        self.brokerBundleIdentifier = brokerBundleIdentifier
    }

    func start() {
        cancellable = discovery.$plugins
            .receive(on: DispatchQueue.main)
            .sink { [weak self] plugins in
                self?.latestPlugins = plugins
                self?.reconcile()
            }
    }

    func isEnabled(_ pluginID: String) -> Bool {
        !disabledPluginIDs.contains(pluginID)
    }

    func setEnabled(_ enabled: Bool, for pluginID: String) {
        PluginPreferences.setEnabled(enabled, for: pluginID)
        disabledPluginIDs = PluginPreferences.disabledPluginIDs()
        reconcile()
    }

    /// Starts a `PluginConnection` for each discovered, enabled manifest not
    /// already connected, and stops any whose manifest disappeared, changed,
    /// or was just disabled — reconnecting on the new definition rather than
    /// the stale one.
    private func reconcile() {
        let enabledIDs = Set(latestPlugins.keys).subtracting(disabledPluginIDs)
        let knownIDs = Set(connections.keys)

        for removedID in knownIDs.subtracting(enabledIDs) {
            stopConnection(for: removedID)
        }

        for id in enabledIDs {
            guard let plugin = latestPlugins[id] else { continue }
            if connections[id] == nil {
                startConnection(for: plugin)
            }
        }

        connectedPluginIDs = enabledIDs
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
