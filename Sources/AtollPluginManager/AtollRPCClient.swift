//
//  AtollRPCClient.swift
//  AtollPluginManager
//
//  WebSocket JSON-RPC 2.0 client for Atoll's ExtensionRPCServer
//  (ws://127.0.0.1:9020). Owns the single Atoll connection/authorization for
//  this broker; everything downstream (plugins) talks to the broker instead,
//  never to Atoll directly.
//

import Foundation
import AtollExtensionKit

/// Connection lifecycle, observable by the UI.
enum AtollRPCConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    /// Socket is open but authorization hasn't completed yet.
    case connected
    case authorized
    case failed(String)
}

/// What a `PluginConnection` needs to relay live activities — narrows
/// `AtollRPCClient` down to just the three activity calls so plugin relay
/// code can be tested against a fake without a real Atoll connection.
protocol ActivityRelay: Actor {
    func presentLiveActivity(_ descriptor: AtollLiveActivityDescriptor) async throws
    func updateLiveActivity(_ descriptor: AtollLiveActivityDescriptor) async throws
    func dismissLiveActivity(activityID: String) async throws
}

/// A playback command Atoll sends back for a registered media source, in
/// response to user interaction (notch controls, media keys).
enum AtollMediaCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case seek(to: TimeInterval)
    case toggleShuffle
    case toggleRepeat

    init?(rpcCommandName: String, seekTo: Double?) {
        switch rpcCommandName {
        case "play": self = .play
        case "pause": self = .pause
        case "togglePlayPause": self = .togglePlayPause
        case "nextTrack": self = .nextTrack
        case "previousTrack": self = .previousTrack
        case "seek":
            guard let seekTo else { return nil }
            self = .seek(to: seekTo)
        case "toggleShuffle": self = .toggleShuffle
        case "toggleRepeat": self = .toggleRepeat
        default: return nil
        }
    }
}

/// What a `MediaPluginConnection` needs to relay Now Playing state and
/// receive playback commands — narrows `AtollRPCClient` down to the three
/// media-source calls, same testability rationale as `ActivityRelay`.
protocol MediaRelay: Actor {
    func registerMediaSource(sourceID: String, name: String, supportsSeek: Bool, supportsSkip: Bool) async throws
    func unregisterMediaSource(sourceID: String) async throws
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
    ) async throws
    func setOnMediaCommand(_ handler: @escaping @MainActor (String, AtollMediaCommand) -> Void)
}

/// What a `GoogleCalendarConnection` needs to relay calendar/event snapshots
/// -- narrows `AtollRPCClient` down to the three calendar-source calls, same
/// testability rationale as `MediaRelay`.
protocol CalendarRelay: Actor {
    func registerCalendarSource(sourceID: String, name: String, accountLabel: String?) async throws
    func unregisterCalendarSource(sourceID: String) async throws
    func publishCalendarState(
        sourceID: String,
        calendars: [CalendarSourceCalendarPayload],
        events: [CalendarSourceEventPayload]
    ) async throws
}

/// Owns the WebSocket connection to Atoll: connect/reconnect with backoff,
/// request/check authorization once, and issue live-activity / lock-screen /
/// notch RPC calls on behalf of registered plugins.
actor AtollRPCClient: ActivityRelay, MediaRelay, CalendarRelay {
    private let bundleIdentifier: String
    private let host: String
    private let port: UInt16
    private let session: URLSession

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var runLoopTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<[String: RPCValue], Error>] = [:]
    private var reconnectDelay: TimeInterval = 1
    private var isRunning = false

    private(set) var state: AtollRPCConnectionState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            FileHandle.standardError.write(Data("[AtollRPCClient] \(bundleIdentifier): \(state)\n".utf8))
            let handler = onStateChange
            let newState = state
            Task { @MainActor in handler?(newState) }
        }
    }

    /// Set once via `setOnStateChange`; delivered on the main actor since it
    /// drives SwiftUI state.
    private var onStateChange: (@MainActor (AtollRPCConnectionState) -> Void)?

    func setOnStateChange(_ handler: @escaping @MainActor (AtollRPCConnectionState) -> Void) {
        onStateChange = handler
    }

    /// Set once; delivered on the main actor. `sourceID` lets a single
    /// handler (owned by whatever manages multiple `MediaPluginConnection`s)
    /// route to the right one.
    private var onMediaCommand: (@MainActor (String, AtollMediaCommand) -> Void)?

    func setOnMediaCommand(_ handler: @escaping @MainActor (String, AtollMediaCommand) -> Void) {
        onMediaCommand = handler
    }

    init(bundleIdentifier: String, host: String = "127.0.0.1", port: UInt16 = ExtensionRPCConstants.port) {
        self.bundleIdentifier = bundleIdentifier
        self.host = host
        self.port = port
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        runLoopTask = Task { await self.connectLoop() }
    }

    func stop() {
        isRunning = false
        runLoopTask?.cancel()
        receiveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPendingRequests(with: .notConnected)
        state = .disconnected
    }

    private func connectLoop() async {
        while isRunning, !Task.isCancelled {
            state = .connecting
            do {
                try await connectOnce()
                state = .connected

                // Read frames concurrently from here on — `ensureAuthorized()`
                // below sends a request and awaits its response, which can
                // only arrive through this loop. Awaiting the receive task
                // afterwards is what actually keeps the connection open.
                let receive = Task { await self.runReceiveLoop() }
                receiveTask = receive

                try await ensureAuthorized()
                state = .authorized
                reconnectDelay = 1
                await receive.value
            } catch {
                state = .failed(error.localizedDescription)
            }

            receiveTask?.cancel()
            receiveTask = nil
            task = nil
            failPendingRequests(with: .notConnected)
            guard isRunning, !Task.isCancelled else { return }

            state = .disconnected
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            reconnectDelay = min(reconnectDelay * 2, 30)
        }
    }

    private func connectOnce() async throws {
        guard var components = URLComponents(string: "ws://\(host):\(port)/") else {
            throw AtollRPCError(code: RPCErrorCode.internalError, message: "Invalid RPC URL")
        }
        components.scheme = "ws"
        guard let url = components.url else {
            throw AtollRPCError(code: RPCErrorCode.internalError, message: "Invalid RPC URL")
        }

        let newTask = session.webSocketTask(with: url)
        newTask.resume()
        task = newTask
    }

    /// Reads frames until the socket closes or errors; each frame either
    /// resolves a pending request (has "id") or is a server notification
    /// (no "id" — logged for now, no subscribers yet).
    private func runReceiveLoop() async {
        guard let task else { return }
        while true {
            do {
                let message = try await task.receive()
                guard let data = message.data else { continue }
                handleIncoming(data)
            } catch {
                return
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        let decoder = JSONDecoder()
        if let response = try? decoder.decode(RPCResponse.self, from: data), let id = response.id {
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
            if let error = response.error {
                continuation.resume(throwing: AtollRPCError.fromWire(error))
            } else {
                continuation.resume(returning: response.result ?? [:])
            }
            return
        }
        // No "id": a server-initiated notification.
        guard let notification = try? decoder.decode(RPCNotification.self, from: data) else { return }

        if notification.method == "atoll.mediaCommand" {
            handleMediaCommandNotification(notification.params ?? [:])
            return
        }

        // Other notifications (activity dismissed by the user, etc.) aren't
        // consumed anywhere yet — logged for visibility.
        FileHandle.standardError.write(Data("[AtollRPCClient] notification: \(notification.method)\n".utf8))
    }

    private func handleMediaCommandNotification(_ params: [String: RPCValue]) {
        guard let sourceID = params["sourceID"]?.stringValue,
              let commandName = params["command"]?.stringValue,
              let command = AtollMediaCommand(rpcCommandName: commandName, seekTo: params["seekTo"]?.doubleValue),
              let handler = onMediaCommand else { return }
        Task { @MainActor in handler(sourceID, command) }
    }

    // MARK: - Authorization

    /// Checks first so a healthy, previously-authorized broker doesn't fire
    /// an authorize call on every reconnect — `atoll.checkAuthorization` is
    /// the read-only half of the same round-trip.
    private func ensureAuthorized() async throws {
        if try await checkAuthorization() { return }

        let result = try await call(method: "atoll.requestAuthorization", params: [
            "bundleIdentifier": .string(bundleIdentifier)
        ])
        guard result["authorized"]?.boolValue == true else {
            throw AtollRPCError(code: RPCErrorCode.unauthorized, message: "Atoll denied authorization for \(bundleIdentifier)")
        }
    }

    func checkAuthorization() async throws -> Bool {
        let result = try await call(method: "atoll.checkAuthorization", params: [
            "bundleIdentifier": .string(bundleIdentifier)
        ])
        return result["authorized"]?.boolValue ?? false
    }

    // MARK: - Live Activities

    func presentLiveActivity(_ descriptor: AtollLiveActivityDescriptor) async throws {
        _ = try await call(method: "atoll.presentLiveActivity", params: [
            "descriptor": try RPCValue.encoding(descriptor)
        ])
    }

    func updateLiveActivity(_ descriptor: AtollLiveActivityDescriptor) async throws {
        _ = try await call(method: "atoll.updateLiveActivity", params: [
            "descriptor": try RPCValue.encoding(descriptor)
        ])
    }

    func dismissLiveActivity(activityID: String) async throws {
        _ = try await call(method: "atoll.dismissLiveActivity", params: [
            "activityID": .string(activityID),
            "bundleIdentifier": .string(bundleIdentifier)
        ])
    }

    // MARK: - Lock Screen Widgets

    func presentLockScreenWidget(_ descriptor: AtollLockScreenWidgetDescriptor) async throws {
        _ = try await call(method: "atoll.presentLockScreenWidget", params: [
            "descriptor": try RPCValue.encoding(descriptor)
        ])
    }

    func updateLockScreenWidget(_ descriptor: AtollLockScreenWidgetDescriptor) async throws {
        _ = try await call(method: "atoll.updateLockScreenWidget", params: [
            "descriptor": try RPCValue.encoding(descriptor)
        ])
    }

    func dismissLockScreenWidget(widgetID: String) async throws {
        _ = try await call(method: "atoll.dismissLockScreenWidget", params: [
            "widgetID": .string(widgetID),
            "bundleIdentifier": .string(bundleIdentifier)
        ])
    }

    // MARK: - Notch Experiences

    func presentNotchExperience(_ descriptor: AtollNotchExperienceDescriptor) async throws {
        _ = try await call(method: "atoll.presentNotchExperience", params: [
            "descriptor": try RPCValue.encoding(descriptor)
        ])
    }

    func updateNotchExperience(_ descriptor: AtollNotchExperienceDescriptor) async throws {
        _ = try await call(method: "atoll.updateNotchExperience", params: [
            "descriptor": try RPCValue.encoding(descriptor)
        ])
    }

    func dismissNotchExperience(experienceID: String) async throws {
        _ = try await call(method: "atoll.dismissNotchExperience", params: [
            "experienceID": .string(experienceID),
            "bundleIdentifier": .string(bundleIdentifier)
        ])
    }

    // MARK: - Media Sources

    func registerMediaSource(sourceID: String, name: String, supportsSeek: Bool, supportsSkip: Bool) async throws {
        _ = try await call(method: "atoll.registerMediaSource", params: [
            "sourceID": .string(sourceID),
            "name": .string(name),
            "supportsSeek": .bool(supportsSeek),
            "supportsSkip": .bool(supportsSkip)
        ])
    }

    func unregisterMediaSource(sourceID: String) async throws {
        _ = try await call(method: "atoll.unregisterMediaSource", params: [
            "sourceID": .string(sourceID)
        ])
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
        var params: [String: RPCValue] = [
            "sourceID": .string(sourceID),
            "title": .string(title),
            "artist": .string(artist),
            "album": .string(album),
            "isPlaying": .bool(isPlaying),
            "elapsedTime": .double(elapsedTime)
        ]
        if let artworkBase64 { params["artworkBase64"] = .string(artworkBase64) }
        if let duration { params["duration"] = .double(duration) }
        if let isShuffled { params["isShuffled"] = .bool(isShuffled) }
        if let repeatMode { params["repeatMode"] = .string(repeatMode) }
        _ = try await call(method: "atoll.publishNowPlayingState", params: params)
    }

    // MARK: - Calendar Sources

    func registerCalendarSource(sourceID: String, name: String, accountLabel: String?) async throws {
        var params: [String: RPCValue] = [
            "sourceID": .string(sourceID),
            "name": .string(name)
        ]
        if let accountLabel { params["accountLabel"] = .string(accountLabel) }
        _ = try await call(method: "atoll.registerCalendarSource", params: params)
    }

    func unregisterCalendarSource(sourceID: String) async throws {
        _ = try await call(method: "atoll.unregisterCalendarSource", params: [
            "sourceID": .string(sourceID)
        ])
    }

    func publishCalendarState(
        sourceID: String,
        calendars: [CalendarSourceCalendarPayload],
        events: [CalendarSourceEventPayload]
    ) async throws {
        _ = try await call(method: "atoll.publishCalendarState", params: [
            "sourceID": .string(sourceID),
            "calendars": try RPCValue.encoding(calendars),
            "events": try RPCValue.encoding(events)
        ])
    }

    // MARK: - RPC Call Plumbing

    private func call(method: String, params: [String: RPCValue]) async throws -> [String: RPCValue] {
        guard let task else { throw AtollRPCError.notConnected }

        let request = RPCRequest(method: method, params: params)
        let data = try JSONEncoder().encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[request.id] = continuation
            task.send(.data(data)) { [weak self] error in
                guard let error else { return }
                Task { await self?.failPendingRequest(id: request.id, error: error) }
            }
        }
    }

    private func failPendingRequest(id: String, error: Error) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failPendingRequests(with error: AtollRPCError) {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}

enum ExtensionRPCConstants {
    static let port: UInt16 = 9020
}

private extension URLSessionWebSocketTask.Message {
    var data: Data? {
        switch self {
        case .data(let d): return d
        case .string(let s): return s.data(using: .utf8)
        @unknown default: return nil
        }
    }
}
