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
    /// Whether `registerMediaSource` has succeeded for the current Atoll
    /// connection lifetime; reset whenever the plugin socket reconnects, same
    /// "don't assume state survived a gap" reasoning as PluginConnection's
    /// `presented` flag on the cliamp side.
    private var isRegistered = false

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
            isRegistered = false
            guard isRunning else { return }
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            reconnectDelay = min(reconnectDelay * 2, 30)
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
        } catch {
            onLog("[\(sourceID)] failed to register media source: \(error.localizedDescription)")
        }
    }

    private func connectOnce() async -> Bool {
        let endpoint = NWEndpoint.unix(path: plugin.socketURL.path)
        let newConnection = NWConnection(to: endpoint, using: .tcp)
        connection = newConnection

        let guardBox = ResumeGuard()
        return await withCheckedContinuation { continuation in
            newConnection.stateUpdateHandler = { state in
                guard !guardBox.resumed else { return }
                switch state {
                case .ready:
                    guardBox.resumed = true
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    guardBox.resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            newConnection.start(queue: .main)
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
}
