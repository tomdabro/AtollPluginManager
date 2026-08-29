//
//  PluginConnection.swift
//  AtollPluginManager
//
//  Connects out to one plugin's Unix domain socket (the plugin is the
//  listener, matching cliamp's existing IPC server design), reads
//  newline-delimited JSON messages, translates them into Atoll descriptors,
//  and relays them through an ActivityRelay. Reconnects with backoff since a
//  passively-discovered plugin may not be running yet.
//

import Foundation
import Network

/// One plugin's live connection: manifest, socket, and the set of activity
/// ids it currently has presented (so a disconnect can clean them up).
actor PluginConnection {
    private let plugin: DiscoveredPlugin
    private let brokerBundleIdentifier: String
    private let relay: any ActivityRelay
    private let onLog: @Sendable (String) -> Void

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var isRunning = false
    private var reconnectDelay: TimeInterval = 1
    /// Local Unix socket to an already-running (or about-to-run) process on
    /// the same machine -- capped low so a plugin started shortly after the
    /// broker is picked up within a few seconds rather than however far
    /// backoff had already climbed.
    private let maxReconnectDelay: TimeInterval = 5
    /// Local (plugin-supplied) activity ids currently presented, so a
    /// disconnect/failure can dismiss exactly what this plugin owns.
    private var activeLocalIDs: Set<String> = []
    /// Reported to `PluginConnectionManager` via `setOnLiveStateChange` so
    /// the UI's connected indicator reflects whether the socket is actually
    /// up right now, not just "discovered and enabled."
    private var onLiveStateChange: (@MainActor (Bool) -> Void)?
    private var isLive = false

    init(
        plugin: DiscoveredPlugin,
        brokerBundleIdentifier: String,
        relay: any ActivityRelay,
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.plugin = plugin
        self.brokerBundleIdentifier = brokerBundleIdentifier
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

    private func qualifiedID(for localID: String) -> String {
        "\(plugin.manifest.id):\(localID)"
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
        notifyLiveState(false)
        await dismissAllActiveActivities()
    }

    private func connectLoop() async {
        while isRunning {
            let didConnect = await connectOnce()
            if didConnect {
                reconnectDelay = 1
                notifyLiveState(true)
                await receiveLoop()
            }
            connection = nil
            notifyLiveState(false)
            await dismissAllActiveActivities()
            guard isRunning else { return }
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        }
    }

    /// A Unix domain socket connect attempt against a path that doesn't
    /// exist yet lands in `.waiting(POSIXErrorCode.ENOENT)` and never
    /// progresses to `.ready` *or* `.failed` on its own -- confirmed
    /// directly, matching `MediaPluginConnection`'s identical finding.
    /// Without a bound this hangs `connectOnce()`, and therefore
    /// `connectLoop`'s entire retry loop, forever.
    private static let initialConnectTimeout: TimeInterval = 2

    /// Resolves once the connection reaches `.ready` or fails/times out.
    private func connectOnce() async -> Bool {
        let endpoint = NWEndpoint.unix(path: plugin.socketURL.path)
        let newConnection = NWConnection(to: endpoint, using: .tcp)
        connection = newConnection

        // `stateUpdateHandler` always fires serially on the `.main` queue
        // passed to `start(queue:)` below, but the compiler can't see that —
        // a small `@unchecked Sendable` box keeps the "resume once" guard
        // without a captured-var warning.
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
                        // Already up and died under us (the plugin process
                        // restarted). A pending `receive()` issued before
                        // this failure can otherwise never complete, leaving
                        // receiveLoop -- and connectLoop's reconnect --
                        // stuck forever. Cancelling unblocks it so the loop
                        // notices and reconnects on its own, matching the
                        // identical fix in MediaPluginConnection.
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

            // Same serial `.main` queue as stateUpdateHandler above, so no
            // race with a `.ready`/`.failed` delivered around the same time.
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

    /// Buffers partial reads and splits on newlines — a plugin can write a
    /// message across several socket writes.
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
        let message: PluginMessage
        do {
            message = try JSONDecoder().decode(PluginMessage.self, from: lineData)
        } catch {
            onLog("[\(plugin.manifest.id)] malformed message: \(error.localizedDescription)")
            return
        }

        do {
            switch message.type {
            case .presentActivity:
                let descriptor = try message.makeDescriptor(
                    qualifiedID: qualifiedID(for: message.id),
                    brokerBundleIdentifier: brokerBundleIdentifier
                )
                try await relay.presentLiveActivity(descriptor)
                activeLocalIDs.insert(message.id)
                await send(.ack(id: message.id))

            case .updateActivity:
                let descriptor = try message.makeDescriptor(
                    qualifiedID: qualifiedID(for: message.id),
                    brokerBundleIdentifier: brokerBundleIdentifier
                )
                try await relay.updateLiveActivity(descriptor)
                await send(.ack(id: message.id))

            case .dismissActivity:
                try await relay.dismissLiveActivity(activityID: qualifiedID(for: message.id))
                activeLocalIDs.remove(message.id)
                await send(.ack(id: message.id))
            }
        } catch {
            onLog("[\(plugin.manifest.id)] failed to relay \(message.type.rawValue) for \(message.id): \(error.localizedDescription)")
            await send(.error(id: message.id, message: error.localizedDescription))
        }
    }

    private func send(_ response: PluginResponse) async {
        guard let connection, let data = try? JSONEncoder().encode(response) else { return }
        var framed = data
        framed.append(0x0A)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: framed, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func dismissAllActiveActivities() async {
        guard !activeLocalIDs.isEmpty else { return }
        let idsToClear = activeLocalIDs
        activeLocalIDs.removeAll()
        for localID in idsToClear {
            try? await relay.dismissLiveActivity(activityID: qualifiedID(for: localID))
        }
    }
}

/// Single-writer "resume once" flag for `NWConnection.stateUpdateHandler`,
/// which only ever fires on the queue passed to `start(queue:)`.
final class ResumeGuard: @unchecked Sendable {
    var resumed = false
}
