//
//  MediaPluginConnection.swift
//  AtollPluginManager
//
//  Connects out to one media plugin's Unix domain socket (mirrors
//  PluginConnection's shape for live activities), registers it as an Atoll
//  media source using the manifest's own id/name/config, relays
//  nowPlaying messages into publishNowPlayingState, and forwards playback
//  commands Atoll sends back down to the plugin.
//

import Foundation
import Network

actor MediaPluginConnection {
    private let plugin: DiscoveredPlugin
    private let relay: any MediaRelay
    private let onLog: @Sendable (String) -> Void

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var isRunning = false
    private var reconnectDelay: TimeInterval = 1
    /// Local Unix socket to an already-running (or about-to-run) process on
    /// the same machine -- capped low so a plugin started shortly after the
    /// broker (a common real ordering: launch Atoll, then the broker, then
    /// the plugin) is picked up within a few seconds rather than however far
    /// backoff had already climbed.
    private let maxReconnectDelay: TimeInterval = 5
    /// Whether `registerMediaSource` has succeeded for the current Atoll
    /// connection lifetime; reset whenever the plugin socket reconnects, same
    /// "don't assume state survived a gap" reasoning as PluginConnection's
    /// `presented` flag on the cliamp side.
    private var isRegistered = false
    /// Reported to `PluginConnectionManager` via `setOnLiveStateChange` so
    /// the UI's connected indicator reflects whether the socket is actually
    /// up and registered right now, not just "discovered and enabled."
    private var onLiveStateChange: (@MainActor (Bool) -> Void)?
    private var isLive = false

    private var sourceID: String { plugin.manifest.id }

    init(
        plugin: DiscoveredPlugin,
        relay: any MediaRelay,
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.plugin = plugin
        self.relay = relay
        self.onLog = onLog
    }

    /// `PluginConnectionManager` wires this up before calling `start()`, so
    /// no transition is ever missed.
    func setOnLiveStateChange(_ handler: @escaping @MainActor (Bool) -> Void) {
        onLiveStateChange = handler
    }

    private func notifyLiveState(_ live: Bool) {
        guard isLive != live else { return }
        isLive = live
        guard let onLiveStateChange else { return }
        Task { @MainActor in onLiveStateChange(live) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await self.connectLoop() }
    }

    func stop() async {
        isRunning = false
        connection?.cancel()
        connection = nil
        if isRegistered {
            try? await relay.unregisterMediaSource(sourceID: sourceID)
            isRegistered = false
            notifyLiveState(false)
        }
    }


    private func connectLoop() async {
        while isRunning {
            let didConnect = await connectOnce()
            if didConnect {
                reconnectDelay = 1
                await registerSource()
                await receiveLoop()
            }
            connection = nil
            if isRegistered {
                isRegistered = false
                notifyLiveState(false)
            }
            guard isRunning else { return }
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        }
    }

    private func registerSource() async {
        do {
            try await relay.registerMediaSource(
                sourceID: sourceID,
                name: plugin.manifest.name,
                supportsSeek: plugin.manifest.supportsSeek,
                supportsSkip: plugin.manifest.supportsSkip
            )
            isRegistered = true
            notifyLiveState(true)
        } catch {
            onLog("[\(sourceID)] failed to register media source: \(error.localizedDescription)")
        }
    }

    /// A Unix domain socket connect attempt against a path that doesn't
    /// exist yet -- the broker starting before the plugin, or the brief gap
    /// while a restarting plugin recreates its socket -- lands in
    /// `.waiting(POSIXErrorCode.ENOENT)` and, unlike a refused TCP
    /// connection, never progresses to `.ready` *or* `.failed` on its own:
    /// Network.framework treats a missing local path as a condition that
    /// might resolve later, not a terminal failure (confirmed directly:
    /// still `.waiting` after 5s with nothing else listening). Left alone
    /// this hangs `connectOnce()` -- and therefore `connectLoop`'s entire
    /// retry loop -- forever, which is exactly what "the broker never
    /// picked up the plugin" cold-start reports turned out to be: no amount
    /// of waiting recovers a loop that's stuck on its first attempt.
    private static let initialConnectTimeout: TimeInterval = 2

    private func connectOnce() async -> Bool {
        let endpoint = NWEndpoint.unix(path: plugin.socketURL.path)
        let newConnection = NWConnection(to: endpoint, using: .tcp)
        connection = newConnection

        let guardBox = ResumeGuard()
        return await withCheckedContinuation { continuation in
            newConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !guardBox.resumed else { return }
                    guardBox.resumed = true
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    guard !guardBox.resumed else {
                        // The connection was already up and just died under
                        // us (e.g. the plugin process restarted). A pending
                        // `NWConnection.receive()` issued before this state
                        // change can otherwise never complete -- Network.framework
                        // doesn't reliably re-deliver a failure to a receive
                        // call already in flight when the connection fails
                        // out from under it -- which would leave receiveLoop
                        // (and therefore connectLoop's reconnect) stuck
                        // forever, only recoverable by the user manually
                        // disabling/re-enabling the plugin. Cancelling here
                        // forces any pending receive to complete so the loop
                        // notices and reconnects on its own.
                        newConnection.cancel()
                        return
                    }
                    guardBox.resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            newConnection.start(queue: .main)

            // Runs on the same serial `.main` queue as stateUpdateHandler
            // above, so there's no race between this and a `.ready`/`.failed`
            // delivery landing at the same time -- whichever was scheduled
            // first on that queue runs first.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.initialConnectTimeout) {
                guard !guardBox.resumed else { return }
                newConnection.cancel()
            }
        }
    }

    private func receiveLoop() async {
        guard let connection else { return }
        while true {
            let result = await receiveOnce(connection)
            switch result {
            case .data(let data):
                await handleIncoming(data)
            case .closed, .failed:
                return
            }
        }
    }

    private enum ReceiveResult {
        case data(Data)
        case closed
        case failed
    }

    private func receiveOnce(_ connection: NWConnection) async -> ReceiveResult {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: .data(data))
                } else if isComplete {
                    continuation.resume(returning: .closed)
                } else if error != nil {
                    continuation.resume(returning: .failed)
                } else {
                    continuation.resume(returning: .closed)
                }
            }
        }
    }

    private func handleIncoming(_ chunk: Data) async {
        receiveBuffer.append(chunk)
        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            let lineData = receiveBuffer[..<newlineIndex]
            receiveBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else { continue }
            await handleLine(Data(lineData))
        }
    }

    private func handleLine(_ lineData: Data) async {
        guard let message = try? JSONDecoder().decode(MediaNowPlayingMessage.self, from: lineData) else {
            onLog("[\(sourceID)] malformed nowPlaying message: \(String(data: lineData, encoding: .utf8) ?? "<binary>")")
            return
        }
        guard !message.title.isEmpty else {
            onLog("[\(sourceID)] \(MediaPluginMessageError.missingTitle.localizedDescription)")
            return
        }

        do {
            try await relay.publishNowPlayingState(
                sourceID: sourceID,
                title: message.title,
                artist: message.artist ?? "",
                album: message.album ?? "",
                artworkBase64: message.artworkBase64,
                isPlaying: message.isPlaying,
                elapsedTime: message.elapsedTime,
                duration: message.duration,
                isShuffled: message.isShuffled,
                repeatMode: message.repeatMode
            )
        } catch {
            onLog("[\(sourceID)] failed to publish Now Playing state: \(error.localizedDescription)")
        }
    }

    /// Called by whatever dispatches `AtollRPCClient.onMediaCommand` by
    /// sourceID (see `PluginConnectionManager`).
    func handleCommand(_ command: AtollMediaCommand) async {
        guard let connection else { return }
        guard let data = try? JSONEncoder().encode(MediaCommandMessage(command: command)) else { return }
        var framed = data
        framed.append(0x0A)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: framed, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    /// Called by `PluginConnectionManager` when the broker's WebSocket to
    /// Atoll transitions back to `.authorized` (Atoll relaunched, woke from
    /// sleep, or the socket briefly dropped and reconnected). The plugin's
    /// own Unix socket connection can easily have stayed up the entire time
    /// -- `connectLoop` only calls `registerSource()` when *this* connection
    /// (re)establishes, so a fresh Atoll process has no record of this
    /// source even though `isRegistered` still (correctly, for the old
    /// belief) says true. Re-register unconditionally so the new Atoll
    /// instance learns about an already-connected source without requiring
    /// the user to disable/re-enable the plugin.
    func resyncRegistration() async {
        guard connection != nil else { return }
        await registerSource()
    }
}
