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

    func testDisabledPluginIsNotCountedAsConnected() async {
        writeManifest(id: "cliamp", socketFileName: "cliamp.sock")

        let discovery = PluginDiscovery(pluginsDirectory: tempDirectory)
        let relay = FakeRelay()
        let manager = PluginConnectionManager(discovery: discovery, relay: relay, brokerBundleIdentifier: "broker")

        manager.start()
        discovery.start()
        // Let the Combine pipeline (discovery.$plugins -> manager.reconcile) settle.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(manager.isEnabled("cliamp"))
        XCTAssertTrue(manager.connectedPluginIDs.contains("cliamp"))

        manager.setEnabled(false, for: "cliamp")
        XCTAssertFalse(manager.isEnabled("cliamp"))
        XCTAssertFalse(manager.connectedPluginIDs.contains("cliamp"))

        manager.setEnabled(true, for: "cliamp")
        XCTAssertTrue(manager.isEnabled("cliamp"))
        XCTAssertTrue(manager.connectedPluginIDs.contains("cliamp"))

        discovery.stop()
    }

    func testDisabledStatePersistsAcrossPreferencesReads() {
        PluginPreferences.setEnabled(false, for: "cliamp")
        XCTAssertTrue(PluginPreferences.disabledPluginIDs().contains("cliamp"))

        PluginPreferences.setEnabled(true, for: "cliamp")
        XCTAssertFalse(PluginPreferences.disabledPluginIDs().contains("cliamp"))
    }
}
