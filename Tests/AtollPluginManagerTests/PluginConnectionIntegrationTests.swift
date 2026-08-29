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

/// Records every call instead of talking to a real Atoll. Conforms to every
/// relay protocol so the same fake covers live-activity, media-source, and
/// calendar-source connection tests.
actor FakeRelay: ActivityRelay, MediaRelay, CalendarRelay {
    private(set) var presented: [AtollLiveActivityDescriptor] = []
    private(set) var updated: [AtollLiveActivityDescriptor] = []
    private(set) var dismissedIDs: [String] = []

    private(set) var registeredSources: [String] = []
    private(set) var unregisteredSources: [String] = []
    private(set) var publishedStates: [(sourceID: String, title: String, isPlaying: Bool, isShuffled: Bool?, repeatMode: String?)] = []
    private var onMediaCommand: (@MainActor (String, AtollMediaCommand) -> Void)?

    private(set) var registeredCalendarSources: [String] = []
    private(set) var unregisteredCalendarSources: [String] = []
    private(set) var publishedCalendarStates: [(sourceID: String, calendars: [CalendarSourceCalendarPayload], events: [CalendarSourceEventPayload])] = []

    func presentLiveActivity(_ descriptor: AtollLiveActivityDescriptor) async throws {
        presented.append(descriptor)
    }

    func updateLiveActivity(_ descriptor: AtollLiveActivityDescriptor) async throws {
        updated.append(descriptor)
    }

    func dismissLiveActivity(activityID: String) async throws {
        dismissedIDs.append(activityID)
    }

    func registerMediaSource(sourceID: String, name: String, supportsSeek: Bool, supportsSkip: Bool) async throws {
        registeredSources.append(sourceID)
    }

    func unregisterMediaSource(sourceID: String) async throws {
        unregisteredSources.append(sourceID)
    }

    func publishNowPlayingState(
        sourceID: String,
        title: String,
        artist: String,
        album: String,
        artworkBase64: String?,
        isPlaying: Bool,
        elapsedTime: TimeInterval,
        duration: TimeInterval?,
        isShuffled: Bool?,
        repeatMode: String?
    ) async throws {
        publishedStates.append((sourceID: sourceID, title: title, isPlaying: isPlaying, isShuffled: isShuffled, repeatMode: repeatMode))
    }

    func setOnMediaCommand(_ handler: @escaping @MainActor (String, AtollMediaCommand) -> Void) {
        onMediaCommand = handler
    }

    /// Test hook: simulates Atoll pushing a command notification.
    func simulateMediaCommand(_ command: AtollMediaCommand, to sourceID: String) async {
        await onMediaCommand?(sourceID, command)
    }

    func registerCalendarSource(sourceID: String, name: String, accountLabel: String?) async throws {
        registeredCalendarSources.append(sourceID)
    }

    func unregisterCalendarSource(sourceID: String) async throws {
        unregisteredCalendarSources.append(sourceID)
    }

    func publishCalendarState(
        sourceID: String,
        calendars: [CalendarSourceCalendarPayload],
        events: [CalendarSourceEventPayload]
    ) async throws {
        publishedCalendarStates.append((sourceID: sourceID, calendars: calendars, events: events))
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

    private var receiveBuffer = Data()

    /// Reads one newline-delimited line the broker wrote to this connection
    /// (e.g. a `mediaCommand`), buffering across multiple socket reads.
    func readLine(timeout: TimeInterval = 2) async throws -> Data {
        if let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer[..<newlineIndex]
            receiveBuffer.removeSubrange(...newlineIndex)
            return Data(line)
        }
        guard let connection else { throw AtollRPCError(code: RPCErrorCode.internalError, message: "no connection") }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                    continuation.resume(returning: data)
                }
            }
            if let chunk, !chunk.isEmpty {
                receiveBuffer.append(chunk)
                if let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
                    let line = receiveBuffer[..<newlineIndex]
                    receiveBuffer.removeSubrange(...newlineIndex)
                    return Data(line)
                }
            }
        }
        throw AtollRPCError(code: RPCErrorCode.internalError, message: "timed out waiting for a line")
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
        let relay = FakeRelay()

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
        let relay = FakeRelay()

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
        let relay = FakeRelay()

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
