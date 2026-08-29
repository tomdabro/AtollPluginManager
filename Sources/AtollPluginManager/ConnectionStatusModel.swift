//
//  ConnectionStatusModel.swift
//  AtollPluginManager
//
//  MainActor-observable bridge onto the (actor-isolated) AtollRPCClient, for
//  SwiftUI to bind against.
//

import SwiftUI

@MainActor
final class ConnectionStatusModel: ObservableObject {
    @Published private(set) var state: AtollRPCConnectionState = .disconnected

    let client: AtollRPCClient

    init(client: AtollRPCClient) {
        self.client = client
    }

    func start() async {
        await client.setOnStateChange { [weak self] newState in
            self?.state = newState
        }
        await client.start()
    }
}
