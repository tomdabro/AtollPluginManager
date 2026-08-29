//
//  PluginConnectionIntegrationTests.swift
//  AtollPluginManagerTests
//
//  End-to-end over a real Unix domain socket: a fake "plugin" listens (as
//  cliamp's own daemon would), PluginConnection connects out to it exactly
//  like it would to a real plugin, and a fake ActivityRelay records what
//  would have been sent to Atoll.
//

import XCTest
import Network
import AtollExtensionKit
@testable import AtollPluginManager

/// Records every call instead of talking to a real Atoll.
actor FakeActivityRelay: ActivityRelay {
    private(set) var presented: [AtollLiveActivityDescriptor] = []
    private(set) var updated: [AtollLiveActivityDescriptor] = []
    private(set) var dismissedIDs: [String] = []

    func presentLiveActivity(_ descriptor: AtollLiveActivityDescriptor) async throws {
        presented.append(descriptor)
    }

    func updateLiveActivity(_ descriptor: AtollLiveActivityDescriptor) async throws {
        updated.append(descriptor)
    }

    func dismissLiveActivity(activityID: String) async throws {
        dismissedIDs.append(activityID)
    }
}

/// A minimal Unix-socket server standing in for a real plugin daemon.
final class FakePluginServer {
    private let listener: NWListener
    private var connection: NWConnection?
    let socketPath: String

    init(socketPath: String) throws {
        self.socketPath = socketPath
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: socketPath)
        listener = try NWListener(using: params)
    }

    /// Resolves once a client (the `PluginConnection` under test) connects.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.newConnectionHandler = { [weak self] newConnection in
                self?.connection = newConnection
                newConnection.start(queue: .main)
                if !resumed {
                    resumed = true
                    continuation.resume()
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state, !resumed {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
            listener.start(queue: .main)
        }
    }

    func write(_ line: String) async {
        guard let connection else { return }
        var data = line.data(using: .utf8)!
        data.append(0x0A)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

final class PluginConnectionIntegrationTests: XCTestCase {
    /// `sockaddr_un.sun_path` is capped at 104 bytes on Darwin —
    /// `FileManager.default.temporaryDirectory` (`/var/folders/.../T/...`)
    /// plus a UUID-based name routinely exceeds that, so tests use a short
    /// `/tmp/` path with an 8-character random suffix instead.
    private func makeSocketPath() -> String {
        let suffix = UUID().uuidString.prefix(8)
        return "/tmp/apm-test-\(suffix).sock"
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    func testPresentUpdateDismissRelayToAtollDescriptors() async throws {
        let socketPath = makeSocketPath()
        let server = try FakePluginServer(socketPath: socketPath)
        let relay = FakeActivityRelay()

        let plugin = DiscoveredPlugin(
            manifest: PluginManifest(id: "cliamp", name: "cliamp", category: .liveActivity, transport: .unixSocket, socketPath: socketPath),
            folderURL: URL(fileURLWithPath: "/tmp")
        )
        let connection = PluginConnection(plugin: plugin, brokerBundleIdentifier: "com.atollpluginmanager.broker", relay: relay)

        async let serverReady: Void = server.start()
        await connection.start()
        try await serverReady

        await server.write(#"{"type":"presentActivity","id":"now-playing","title":"Song Title","subtitle":"Artist","icon":"music.note","priority":"normal"}"#)

        let presented = await waitUntil { await relay.presented.count == 1 }
        XCTAssertTrue(presented, "expected the relay to receive a presentLiveActivity call")

        let descriptor = await relay.presented.first
        XCTAssertEqual(descriptor?.id, "cliamp:now-playing")
        XCTAssertEqual(descriptor?.bundleIdentifier, "com.atollpluginmanager.broker")
        XCTAssertEqual(descriptor?.title, "Song Title")
        XCTAssertEqual(descriptor?.subtitle, "Artist")

        await server.write(#"{"type":"updateActivity","id":"now-playing","title":"New Song"}"#)
        let updated = await waitUntil { await relay.updated.count == 1 }
        XCTAssertTrue(updated)
        let updatedDescriptor = await relay.updated.first
        XCTAssertEqual(updatedDescriptor?.title, "New Song")

        await server.write(#"{"type":"dismissActivity","id":"now-playing"}"#)
        let dismissed = await waitUntil { await relay.dismissedIDs.contains("cliamp:now-playing") }
        XCTAssertTrue(dismissed)

        await connection.stop()
        server.stop()
    }

    func testDisconnectDismissesStillActiveActivities() async throws {
        let socketPath = makeSocketPath()
        let server = try FakePluginServer(socketPath: socketPath)
        let relay = FakeActivityRelay()

        let plugin = DiscoveredPlugin(
            manifest: PluginManifest(id: "cliamp", name: "cliamp", category: .liveActivity, transport: .unixSocket, socketPath: socketPath),
            folderURL: URL(fileURLWithPath: "/tmp")
        )
        let connection = PluginConnection(plugin: plugin, brokerBundleIdentifier: "com.atollpluginmanager.broker", relay: relay)

        async let serverReady: Void = server.start()
        await connection.start()
        try await serverReady

        await server.write(#"{"type":"presentActivity","id":"leftover","title":"Still going"}"#)
        let presented = await waitUntil { await relay.presented.count == 1 }
        XCTAssertTrue(presented)

        // Simulate the plugin process dying without sending dismissActivity.
        server.stop()

        let dismissed = await waitUntil(timeout: 5) { await relay.dismissedIDs.contains("cliamp:leftover") }
        XCTAssertTrue(dismissed, "a dropped connection should dismiss whatever it had presented")

        await connection.stop()
    }

    func testMalformedMessageIsIgnoredWithoutCrashingTheConnection() async throws {
        let socketPath = makeSocketPath()
        let server = try FakePluginServer(socketPath: socketPath)
        let relay = FakeActivityRelay()

        let plugin = DiscoveredPlugin(
            manifest: PluginManifest(id: "cliamp", name: "cliamp", category: .liveActivity, transport: .unixSocket, socketPath: socketPath),
            folderURL: URL(fileURLWithPath: "/tmp")
        )
        let connection = PluginConnection(plugin: plugin, brokerBundleIdentifier: "com.atollpluginmanager.broker", relay: relay)

        async let serverReady: Void = server.start()
        await connection.start()
        try await serverReady

        await server.write("{ this is not valid json }")
        await server.write(#"{"type":"presentActivity","id":"still-works","title":"Recovered"}"#)

        let presented = await waitUntil { await relay.presented.count == 1 }
        XCTAssertTrue(presented, "a malformed line should be skipped, not break subsequent messages")

        await connection.stop()
        server.stop()
    }
}
