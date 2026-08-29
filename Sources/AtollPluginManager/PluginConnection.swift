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
    /// Local (plugin-supplied) activity ids currently presented, so a
    /// disconnect/failure can dismiss exactly what this plugin owns.
    private var activeLocalIDs: Set<String> = []

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
        await dismissAllActiveActivities()
    }

    private func connectLoop() async {
        while isRunning {
            let didConnect = await connectOnce()
            if didConnect {
                reconnectDelay = 1
                await receiveLoop()
            }
            connection = nil
            await dismissAllActiveActivities()
            guard isRunning else { return }
            try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
            reconnectDelay = min(reconnectDelay * 2, 30)
        }
    }

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
private final class ResumeGuard: @unchecked Sendable {
    var resumed = false
}
