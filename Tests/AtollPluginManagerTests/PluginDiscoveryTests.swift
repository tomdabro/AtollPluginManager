//
//  PluginDiscoveryTests.swift
//  AtollPluginManagerTests
//

import XCTest
@testable import AtollPluginManager

@MainActor
final class PluginDiscoveryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        // Short /tmp path, not FileManager's temporaryDirectory
        // (/var/folders/.../T/...) — resolved plugin socket paths must fit
        // sockaddr_un.sun_path (104 bytes), and these tests build a socket
        // path several components deep under this directory. Tests compare
        // against `folderURL`/`socketURL` as discovered, not this variable
        // directly, since `contentsOfDirectory` resolves `/tmp` to
        // `/private/tmp` on macOS and this one doesn't.
        tempDirectory = URL(fileURLWithPath: "/tmp/apm-discovery-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func writeManifest(_ json: String, in folderName: String) {
        let folder = tempDirectory.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? json.data(using: .utf8)?.write(to: folder.appendingPathComponent("plugin.json"))
    }

    func testFindsValidManifest() {
        writeManifest(#"{"id":"cliamp","name":"cliamp","category":"liveActivity","transport":"unixSocket","socketPath":"cliamp.sock"}"#, in: "cliamp")

        let discovery = PluginDiscovery(pluginsDirectory: tempDirectory)
        discovery.rescan()

        XCTAssertEqual(discovery.plugins.count, 1)
        XCTAssertEqual(discovery.plugins["cliamp"]?.manifest.name, "cliamp")
        XCTAssertTrue(discovery.rejectedManifests.isEmpty)
    }

    func testIgnoresFolderWithoutManifest() {
        try? FileManager.default.createDirectory(at: tempDirectory.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let discovery = PluginDiscovery(pluginsDirectory: tempDirectory)
        discovery.rescan()

        XCTAssertTrue(discovery.plugins.isEmpty)
        XCTAssertTrue(discovery.rejectedManifests.isEmpty)
    }

    func testRejectsMalformedJSONWithReason() {
        writeManifest("not json", in: "broken")

        let discovery = PluginDiscovery(pluginsDirectory: tempDirectory)
        discovery.rescan()

        XCTAssertTrue(discovery.plugins.isEmpty)
        XCTAssertEqual(discovery.rejectedManifests.count, 1)
        XCTAssertNotNil(discovery.rejectedManifests["broken"])
    }

    func testRejectsDuplicateID() {
        writeManifest(#"{"id":"dup","name":"first","category":"liveActivity","transport":"unixSocket","socketPath":"a.sock"}"#, in: "plugin-a")
        writeManifest(#"{"id":"dup","name":"second","category":"liveActivity","transport":"unixSocket","socketPath":"b.sock"}"#, in: "plugin-b")

        let discovery = PluginDiscovery(pluginsDirectory: tempDirectory)
        discovery.rescan()

        XCTAssertEqual(discovery.plugins.count, 1)
        XCTAssertEqual(discovery.rejectedManifests.count, 1)
    }

    func testResolvedSocketURLIsUnderPluginFolder() {
        writeManifest(#"{"id":"cliamp","name":"cliamp","category":"liveActivity","transport":"unixSocket","socketPath":"cliamp.sock"}"#, in: "cliamp")

        let discovery = PluginDiscovery(pluginsDirectory: tempDirectory)
        discovery.rescan()

        // Derived from the discovered plugin's own folderURL rather than the
        // test's independent `tempDirectory`: `contentsOfDirectory` resolves
        // `/tmp` to `/private/tmp` on macOS, so comparing against a path
        // built from the pre-scan variable would fail on that alone.
        guard let discoveredPlugin = discovery.plugins["cliamp"] else {
            return XCTFail("expected \"cliamp\" to be discovered")
        }
        let expected = discoveredPlugin.folderURL.appendingPathComponent("cliamp.sock").path
        XCTAssertEqual(discoveredPlugin.socketURL.path, expected)
    }

    func testRejectsResolvedSocketPathExceedingUnixSocketLimit() {
        let hugeName = String(repeating: "x", count: 200)
        writeManifest(#"{"id":"huge","name":"huge","category":"liveActivity","transport":"unixSocket","socketPath":"\#(hugeName).sock"}"#, in: "huge")

        let discovery = PluginDiscovery(pluginsDirectory: tempDirectory)
        discovery.rescan()

        XCTAssertTrue(discovery.plugins.isEmpty)
        XCTAssertEqual(discovery.rejectedManifests.count, 1)
        XCTAssertTrue(discovery.rejectedManifests["huge"]?.contains("sockaddr_un") == true)
    }
}
