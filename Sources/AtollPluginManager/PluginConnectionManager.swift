//
//  PluginConnectionManager.swift
//  AtollPluginManager
//
//  Bridges PluginDiscovery (what plugins exist) to PluginConnection /
//  MediaPluginConnection (talking to each one, branching on
//  manifest.category): starts a connection for every newly-discovered,
//  enabled manifest, stops it when the manifest disappears, changes, or the
//  user disables it in Settings.
//

import Foundation
import Combine

@MainActor
final class PluginConnectionManager: ObservableObject {
    /// Plugins with an active (or connecting) connection — i.e. discovered
    /// and enabled, regardless of whether the socket is actually up yet.
    @Published private(set) var connectedPluginIDs: Set<String> = []
    @Published private(set) var disabledPluginIDs: Set<String> = PluginPreferences.disabledPluginIDs()

    private let discovery: PluginDiscovery
    private let relay: any ActivityRelay & MediaRelay
    private let brokerBundleIdentifier: String
    private var activityConnections: [String: PluginConnection] = [:]
    private var mediaConnections: [String: MediaPluginConnection] = [:]
    private var cancellable: AnyCancellable?
    private var latestPlugins: [String: DiscoveredPlugin] = [:]

    init(discovery: PluginDiscovery, relay: any ActivityRelay & MediaRelay, brokerBundleIdentifier: String) {
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

        Task {
            await relay.setOnMediaCommand { [weak self] sourceID, command in
                self?.dispatchMediaCommand(command, to: sourceID)
            }
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

    /// Starts a connection for each discovered, enabled manifest not already
    /// connected, and stops any whose manifest disappeared, changed, or was
    /// just disabled — reconnecting on the new definition rather than the
    /// stale one.
    private func reconcile() {
        let enabledIDs = Set(latestPlugins.keys).subtracting(disabledPluginIDs)
        let knownIDs = Set(activityConnections.keys).union(mediaConnections.keys)

        for removedID in knownIDs.subtracting(enabledIDs) {
            stopConnection(for: removedID)
        }

        for id in enabledIDs {
            guard let plugin = latestPlugins[id] else { continue }
            guard activityConnections[id] == nil, mediaConnections[id] == nil else { continue }
            startConnection(for: plugin)
        }

        connectedPluginIDs = enabledIDs
    }

    private func startConnection(for plugin: DiscoveredPlugin) {
        let onLog: @Sendable (String) -> Void = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }

        switch plugin.manifest.category {
        case .liveActivity:
            let connection = PluginConnection(
                plugin: plugin,
                brokerBundleIdentifier: brokerBundleIdentifier,
                relay: relay,
                onLog: onLog
            )
            activityConnections[plugin.manifest.id] = connection
            Task { await connection.start() }

        case .media:
            let connection = MediaPluginConnection(plugin: plugin, relay: relay, onLog: onLog)
            mediaConnections[plugin.manifest.id] = connection
            Task { await connection.start() }
        }
    }

    private func stopConnection(for id: String) {
        if let connection = activityConnections.removeValue(forKey: id) {
            Task { await connection.stop() }
        }
        if let connection = mediaConnections.removeValue(forKey: id) {
            Task { await connection.stop() }
        }
    }

    private func dispatchMediaCommand(_ command: AtollMediaCommand, to sourceID: String) {
        guard let connection = mediaConnections[sourceID] else { return }
        Task { await connection.handleCommand(command) }
    }
}
