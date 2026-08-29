//
//  ContentView.swift
//  AtollPluginManager
//
//  Connection status plus discovered/connected plugins. Settings-style
//  configuration (Phase 5) still to come; this is status-only for now.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var connection: ConnectionStatusModel
    @EnvironmentObject private var discovery: PluginDiscovery
    @EnvironmentObject private var connectionManager: PluginConnectionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Atoll Plugin Manager")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Text("Plugins register with this broker and it relays them to Atoll over a single authorized connection. Atoll only ever sees this app in its permissions list.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            pluginsSection
        }
        .padding(24)
        .frame(width: 420)
    }

    private var statusText: String {
        switch connection.state {
        case .disconnected: return "Disconnected — waiting for Atoll"
        case .connecting: return "Connecting…"
        case .connected: return "Connected — authorizing…"
        case .authorized: return "Connected to Atoll"
        case .failed(let message): return "Connection failed: \(message)"
        }
    }

    private var statusColor: Color {
        switch connection.state {
        case .authorized: return .green
        case .connecting, .connected: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    @ViewBuilder
    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plugins")
                .font(.headline)

            if discovery.plugins.isEmpty && discovery.rejectedManifests.isEmpty {
                Text("None found in \(PluginDiscovery.defaultPluginsDirectory.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(discovery.plugins.values.sorted(by: { $0.manifest.id < $1.manifest.id }), id: \.manifest.id) { plugin in
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionManager.connectedPluginIDs.contains(plugin.manifest.id) ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(plugin.manifest.name)
                        .font(.body)
                    Text(plugin.manifest.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { connectionManager.isEnabled(plugin.manifest.id) },
                        set: { connectionManager.setEnabled($0, for: plugin.manifest.id) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            ForEach(discovery.rejectedManifests.sorted(by: { $0.key < $1.key }), id: \.key) { folderName, reason in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("\(folderName): \(reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    let discovery = PluginDiscovery()
    let client = AtollRPCClient(bundleIdentifier: "preview")
    return ContentView()
        .environmentObject(ConnectionStatusModel(client: client))
        .environmentObject(discovery)
        .environmentObject(PluginConnectionManager(discovery: discovery, relay: client, brokerBundleIdentifier: "preview"))
}
