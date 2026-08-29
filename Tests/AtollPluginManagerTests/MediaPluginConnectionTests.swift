//
//  MediaPluginConnectionTests.swift
//  AtollPluginManagerTests
//
//  End-to-end over a real Unix domain socket, same shape as
//  PluginConnectionIntegrationTests but for the media wire protocol:
//  registration on connect, nowPlaying relay, and commands flowing back down
//  to the plugin.
//

import XCTest
@testable import AtollPluginManager

final class MediaPluginConnectionTests: XCTestCase {
    private func testSocketPath() -> String {
        "/tmp/apm-media-test-\(UUID().uuidString.prefix(8)).sock"
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    func testConnectRegistersAndRelaysNowPlaying() async throws {
        let socketPath = testSocketPath()
        let server = try FakePluginServer(socketPath: socketPath)
        let relay = FakeRelay()

        let plugin = DiscoveredPlugin(
            manifest: PluginManifest(id: "cliamp", name: "cliamp", category: .media, transport: .unixSocket, socketPath: socketPath, supportsSeek: true, supportsSkip: false),
            folderURL: URL(fileURLWithPath: "/tmp")
        )
        let connection = MediaPluginConnection(plugin: plugin, relay: relay)

        async let serverReady: Void = server.start()
        await connection.start()
        try await serverReady

        let registered = await waitUntil { await relay.registeredSources.contains("cliamp") }
        XCTAssertTrue(registered, "expected registerMediaSource to be called on connect")

        await server.write(#"{"title":"Song Title","artist":"Artist","album":"Album","isPlaying":true,"elapsedTime":12.3,"duration":180.0,"isShuffled":true,"repeatMode":"all"}"#)

        let published = await waitUntil { await relay.publishedStates.contains { $0.title == "Song Title" } }
        XCTAssertTrue(published)

        let state = await relay.publishedStates.first { $0.title == "Song Title" }
        XCTAssertEqual(state?.sourceID, "cliamp")
        XCTAssertEqual(state?.isPlaying, true)
        XCTAssertEqual(state?.isShuffled, true)
        XCTAssertEqual(state?.repeatMode, "all")

        await connection.stop()
        server.stop()
    }

    func testDisconnectUnregistersSource() async throws {
        let socketPath = testSocketPath()
        let server = try FakePluginServer(socketPath: socketPath)
        let relay = FakeRelay()

        let plugin = DiscoveredPlugin(
            manifest: PluginManifest(id: "cliamp", name: "cliamp", category: .media, transport: .unixSocket, socketPath: socketPath),
            folderURL: URL(fileURLWithPath: "/tmp")
        )
        let connection = MediaPluginConnection(plugin: plugin, relay: relay)

        async let serverReady: Void = server.start()
        await connection.start()
        try await serverReady
        _ = await waitUntil { await relay.registeredSources.contains("cliamp") }

        await connection.stop()
        let unregistered = await waitUntil { await relay.unregisteredSources.contains("cliamp") }
        XCTAssertTrue(unregistered)
    }

    func testHandleCommandWritesMediaCommandLineToPlugin() async throws {
        let socketPath = testSocketPath()
        let server = try FakePluginServer(socketPath: socketPath)
        let relay = FakeRelay()

        let plugin = DiscoveredPlugin(
            manifest: PluginManifest(id: "cliamp", name: "cliamp", category: .media, transport: .unixSocket, socketPath: socketPath),
            folderURL: URL(fileURLWithPath: "/tmp")
        )
        let connection = MediaPluginConnection(plugin: plugin, relay: relay)

        async let serverReady: Void = server.start()
        await connection.start()
        try await serverReady
        _ = await waitUntil { await relay.registeredSources.contains("cliamp") }

        await connection.handleCommand(.seek(to: 42.5))

        let line = try await server.readLine(timeout: 2)
        let message = try JSONDecoder().decode(MediaCommandMessage.self, from: line)
        XCTAssertEqual(message.command, "seek")
        XCTAssertEqual(message.seekTo, 42.5)

        await connection.stop()
        server.stop()
    }

    func testHandleCommandWritesToggleShuffleAndToggleRepeat() async throws {
        let socketPath = testSocketPath()
        let server = try FakePluginServer(socketPath: socketPath)
        let relay = FakeRelay()

        let plugin = DiscoveredPlugin(
            manifest: PluginManifest(id: "cliamp", name: "cliamp", category: .media, transport: .unixSocket, socketPath: socketPath),
            folderURL: URL(fileURLWithPath: "/tmp")
        )
        let connection = MediaPluginConnection(plugin: plugin, relay: relay)

        async let serverReady: Void = server.start()
        await connection.start()
        try await serverReady
        _ = await waitUntil { await relay.registeredSources.contains("cliamp") }

        await connection.handleCommand(.toggleShuffle)
        let shuffleLine = try await server.readLine(timeout: 2)
        let shuffleMessage = try JSONDecoder().decode(MediaCommandMessage.self, from: shuffleLine)
        XCTAssertEqual(shuffleMessage.command, "toggleShuffle")

        await connection.handleCommand(.toggleRepeat)
        let repeatLine = try await server.readLine(timeout: 2)
        let repeatMessage = try JSONDecoder().decode(MediaCommandMessage.self, from: repeatLine)
        XCTAssertEqual(repeatMessage.command, "toggleRepeat")

        await connection.stop()
        server.stop()
    }

    func testMalformedNowPlayingMessageIsIgnored() async throws {
        let socketPath = testSocketPath()
        let server = try FakePluginServer(socketPath: socketPath)
        let relay = FakeRelay()

        let plugin = DiscoveredPlugin(
            manifest: PluginManifest(id: "cliamp", name: "cliamp", category: .media, transport: .unixSocket, socketPath: socketPath),
            folderURL: URL(fileURLWithPath: "/tmp")
        )
        let connection = MediaPluginConnection(plugin: plugin, relay: relay)

        async let serverReady: Void = server.start()
        await connection.start()
        try await serverReady
        _ = await waitUntil { await relay.registeredSources.contains("cliamp") }

        await server.write("{ not valid json }")
        await server.write(#"{"title":"","isPlaying":false,"elapsedTime":0}"#) // empty title, must be skipped
        await server.write(#"{"title":"Recovered","isPlaying":true,"elapsedTime":0}"#)

        let published = await waitUntil { await relay.publishedStates.contains { $0.title == "Recovered" } }
        XCTAssertTrue(published, "malformed/empty-title messages must not break subsequent valid ones")
        let titles = await relay.publishedStates.map(\.title)
        XCTAssertFalse(titles.contains(""))

        await connection.stop()
        server.stop()
    }
}
