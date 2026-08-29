//
//  PluginManifestTests.swift
//  AtollPluginManagerTests
//

import XCTest
@testable import AtollPluginManager

final class PluginManifestTests: XCTestCase {
    func testDecodesValidManifest() throws {
        let json = """
        {"id":"cliamp","name":"cliamp","category":"liveActivity","transport":"unixSocket","socketPath":"cliamp.sock","protocolVersion":1}
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.id, "cliamp")
        XCTAssertEqual(manifest.category, .liveActivity)
        XCTAssertEqual(manifest.transport, .unixSocket)
        XCTAssertEqual(manifest.protocolVersion, 1)
        XCTAssertNil(manifest.validationError)
    }

    func testMissingProtocolVersionDefaultsToOne() throws {
        let json = """
        {"id":"cliamp","name":"cliamp","category":"liveActivity","transport":"unixSocket","socketPath":"cliamp.sock"}
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.protocolVersion, 1)
        XCTAssertNil(manifest.validationError)
    }

    func testValidationErrorForUnsupportedProtocolVersion() {
        let manifest = PluginManifest(id: "x", name: "x", category: .liveActivity, transport: .unixSocket, socketPath: "x.sock", protocolVersion: 99)
        XCTAssertNotNil(manifest.validationError)
        XCTAssertTrue(manifest.validationError?.contains("protocolVersion") == true)
    }

    func testRejectsUnknownCategory() {
        let json = """
        {"id":"x","name":"x","category":"lockScreenWidget","transport":"unixSocket","socketPath":"x.sock"}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: json))
    }

    func testRejectsUnknownTransport() {
        let json = """
        {"id":"x","name":"x","category":"liveActivity","transport":"tcp","socketPath":"x.sock"}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: json))
    }

    func testValidationErrorForEmptyID() throws {
        let manifest = PluginManifest(id: "", name: "x", category: .liveActivity, transport: .unixSocket, socketPath: "x.sock")
        XCTAssertNotNil(manifest.validationError)
    }

    func testResolvedSocketURLIsRelativeToFolderByDefault() {
        let manifest = PluginManifest(id: "x", name: "x", category: .liveActivity, transport: .unixSocket, socketPath: "x.sock")
        let folder = URL(fileURLWithPath: "/tmp/plugins/x")
        XCTAssertEqual(manifest.resolvedSocketURL(relativeTo: folder).path, "/tmp/plugins/x/x.sock")
    }

    func testResolvedSocketURLKeepsAbsolutePathAsIs() {
        let manifest = PluginManifest(id: "x", name: "x", category: .liveActivity, transport: .unixSocket, socketPath: "/var/run/x.sock")
        let folder = URL(fileURLWithPath: "/tmp/plugins/x")
        XCTAssertEqual(manifest.resolvedSocketURL(relativeTo: folder).path, "/var/run/x.sock")
    }
}
