//
//  PluginConnectionManagerTests.swift
//  AtollPluginManagerTests
//

import XCTest
@testable import AtollPluginManager

@MainActor
final class PluginConnectionManagerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = URL(fileURLWithPath: "/tmp/apm-connmgr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        // Isolate from any real disabled-plugin state a prior run left behind.
        PluginPreferences.setDisabledPluginIDs([])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        PluginPreferences.setDisabledPluginIDs([])
        super.tearDown()
    }

    private func writeManifest(id: String, socketFileName: String) {
        let folder = tempDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"id":"\#(id)","name":"\#(id)","category":"liveActivity","transport":"unixSocket","socketPath":"\#(socketFileName)"}"#
        try? json.data(using: .utf8)?.write(to: folder.appendingPathComponent("plugin.json"))
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// `connectedPluginIDs` has to mean "the socket is actually up," not
    /// just "discovered and enabled" -- a manifest can (and, after a cold
    /// start of Atoll+broker+plugin in that order, routinely does) exist on
    /// disk well before the process behind it is reachable. This drives it
    /// with a real `FakePluginServer` so a still-connecting plugin is
    /// provably distinguished from a connected one, not just asserted by a
    /// short fixed sleep.
    func testConnectedPluginIDsReflectsLiveConnectionNotJustDiscovery() async throws {
        let socketPath = "/tmp/apm-connmgr-\(UUID().uuidString.prefix(8)).sock"
        writeManifest(id: "cliamp", socketFileName: socketPath)

        let discovery = PluginDiscovery(pluginsDirectory: tempDirectory)
        let relay = FakeRelay()
        let manager = PluginConnectionManager(
            discovery: discovery,
            relay: relay,
            connectionStatus: ConnectionStatusModel(client: AtollRPCClient(bundleIdentifier: "test")),
            brokerBundleIdentifier: "broker"
        )

        discovery.start()
        manager.start()
        // discovery.$plugins -> manager.reconcile() starts connecting, but
        // nothing is listening on socketPath yet -- must not show connected.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(manager.isEnabled("cliamp"))
        XCTAssertFalse(manager.connectedPluginIDs.contains("cliamp"), "discovered-but-unreachable must not read as connected")

        // The very first connectOnce() attempt (already in flight above) is
        // against a socket path that doesn't exist yet -- PluginConnection's
        // initialConnectTimeout (2s) has to elapse before connectLoop's
        // backoff (starts at 1s) even gets a chance to retry against the
        // now-live server started here. Generous timeouts below account for
        // that, not for flakiness.
        let server = try FakePluginServer(socketPath: socketPath)
        async let serverReady: Void = server.start()
        try await serverReady

        let connected = await waitUntil(timeout: 8) { manager.connectedPluginIDs.contains("cliamp") }
        XCTAssertTrue(connected, "expected connectedPluginIDs to reflect the now-live socket")

        manager.setEnabled(false, for: "cliamp")
        XCTAssertFalse(manager.isEnabled("cliamp"))
        XCTAssertFalse(manager.connectedPluginIDs.contains("cliamp"))

        manager.setEnabled(true, for: "cliamp")
        XCTAssertTrue(manager.isEnabled("cliamp"))
        let reconnected = await waitUntil(timeout: 8) { manager.connectedPluginIDs.contains("cliamp") }
        XCTAssertTrue(reconnected)

        discovery.stop()
        server.stop()
    }

    func testDisabledStatePersistsAcrossPreferencesReads() {
        PluginPreferences.setEnabled(false, for: "cliamp")
        XCTAssertTrue(PluginPreferences.disabledPluginIDs().contains("cliamp"))

        PluginPreferences.setEnabled(true, for: "cliamp")
        XCTAssertFalse(PluginPreferences.disabledPluginIDs().contains("cliamp"))
    }
}
