//
//  ContentView.swift
//  AtollPluginManager
//
//  Phase 1 placeholder: connection status only. Plugin list / settings land
//  in later phases (Phase 5).
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var connection: ConnectionStatusModel

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
}

#Preview {
    ContentView()
        .environmentObject(ConnectionStatusModel(client: AtollRPCClient(bundleIdentifier: "preview")))
}
