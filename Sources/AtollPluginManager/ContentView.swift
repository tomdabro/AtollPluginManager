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
    @EnvironmentObject private var googleCalendar: GoogleCalendarViewState
    @AppStorage("googleCalendarClientID") private var googleCalendarClientID: String = ""
    @State private var showingGoogleCalendarConfig = false

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

    /// Same green/red/grey semantics as a discovered plugin's row: green
    /// while actually live and pushing data, red on any error (revoked
    /// token, failed exchange, ...), grey when there's simply nothing
    /// connected yet. Yellow only while the OAuth round-trip is in flight,
    /// matching the broker's own top-level connecting state.
    private var googleCalendarStatusColor: Color {
        if googleCalendar.isAuthorizing { return .yellow }
        if googleCalendar.error != nil { return .red }
        if googleCalendar.isAuthenticated && !googleCalendar.isEnabled { return .gray }
        if googleCalendar.isAuthenticated { return .green }
        return .gray
    }

    @ViewBuilder
    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plugins")
                .font(.headline)

            googleCalendarRow

            if discovery.plugins.isEmpty && discovery.rejectedManifests.isEmpty {
                Text("No external plugins found in \(PluginDiscovery.defaultPluginsDirectory.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(discovery.plugins.values.sorted(by: { $0.manifest.id < $1.manifest.id }), id: \.manifest.id) { plugin in
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionManager.connectedPluginIDs.contains(plugin.manifest.id) ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Image(systemName: plugin.manifest.category == .media ? "hifispeaker.fill" : "text.badge.star")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(plugin.manifest.name)
                        .font(.body)
                    Text(plugin.manifest.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(plugin.manifest.category == .media ? "Media Source" : "Live Activity")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
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

    /// A built-in, broker-native plugin (no external process to discover —
    /// this app does the Google OAuth + polling itself), shown the same way
    /// a discovered plugin like cliamp is: status dot, icon, name, id,
    /// category badge, and an enable/disable toggle (pauses polling and
    /// unregisters from Atoll without clearing the OAuth token pair, so
    /// turning it back on resumes immediately). A trailing chevron button
    /// (there's no manifest folder to expand into, so no natural
    /// disclosure control to reuse) expands the Client ID/Secret config.
    @ViewBuilder
    private var googleCalendarRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(googleCalendarStatusColor)
                    .frame(width: 8, height: 8)
                Image(systemName: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Google Calendar")
                    .font(.body)
                Text("google-calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Calendar Source")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { googleCalendar.isEnabled },
                    set: { googleCalendar.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                Button {
                    showingGoogleCalendarConfig.toggle()
                } label: {
                    Image(systemName: showingGoogleCalendarConfig ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if showingGoogleCalendarConfig {
                googleCalendarConfig
                    .padding(.leading, 14)
            }
        }
    }

    @ViewBuilder
    private var googleCalendarConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connects directly to your Google account via OAuth and pushes calendar events to Atoll as a calendar source. Create a free OAuth client at console.cloud.google.com (APIs & Services → Credentials → Create Credentials → OAuth client ID → Desktop app), enable the Calendar API for that project, then paste its Client ID and Client Secret here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Client ID", text: $googleCalendarClientID)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())

            SecureField("Client Secret", text: $googleCalendar.clientSecretField)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())

            Text(googleCalendarStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = googleCalendar.error {
                Text(message(for: error))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(googleCalendar.isAuthorizing ? "Connecting…" : "Connect Google Calendar") {
                    googleCalendar.connect()
                }
                .disabled(
                    googleCalendarClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || googleCalendar.clientSecretField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || googleCalendar.isAuthorizing
                )

                Button("Disconnect") {
                    googleCalendar.disconnect()
                }
                .disabled(!googleCalendar.isAuthenticated)

                Link("Open Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    .font(.caption)
            }

            Text("While the OAuth consent screen is in \"Testing\" publish status, Google expires the connection after 7 days — reconnect here when that happens.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var googleCalendarStatusText: String {
        if googleCalendar.isAuthenticated && !googleCalendar.isEnabled {
            return "Paused — turn the switch back on to resume."
        }
        if googleCalendar.isAuthenticated {
            return "Connected — pushing events to Atoll."
        }
        if googleCalendar.isAuthorizing {
            return "Connecting…"
        }
        if googleCalendarClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || googleCalendar.clientSecretField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Not connected."
        }
        return "Credentials saved. Connect your Google account."
    }

    private func message(for error: GoogleCalendarError) -> String {
        switch error {
        case .missingClientID:
            return "Paste the Client ID of your Google Cloud OAuth client first."
        case .missingClientSecret:
            return "Paste the Client Secret of your Google Cloud OAuth client first."
        case .secureRandomUnavailable:
            return "Unable to generate secure random data for the login."
        case .canceled:
            return ""
        case .loopbackServerFailed(let description):
            return "Could not start the local sign-in listener: \(description)"
        case .missingAuthorizationCode:
            return "Google did not return an authorization code."
        case .stateMismatch:
            return "Google sign-in response didn't match the request. Try connecting again."
        case .tokenExchangeFailed(let description):
            return "Token exchange failed: \(description)"
        case .refreshTokenRevoked:
            return "Google revoked access. Connect your account again."
        }
    }
}

#Preview {
    let discovery = PluginDiscovery()
    let client = AtollRPCClient(bundleIdentifier: "preview")
    let statusModel = ConnectionStatusModel(client: client)
    ContentView()
        .environmentObject(statusModel)
        .environmentObject(discovery)
        .environmentObject(PluginConnectionManager(discovery: discovery, relay: client, connectionStatus: statusModel, brokerBundleIdentifier: "preview"))
        .environmentObject(GoogleCalendarViewState(connection: GoogleCalendarConnection(relay: client)))
}
