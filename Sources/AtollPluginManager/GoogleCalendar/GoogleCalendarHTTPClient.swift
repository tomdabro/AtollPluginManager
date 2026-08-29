//
//  GoogleCalendarHTTPClient.swift
//  AtollPluginManager
//
//  Seam for injecting a stubbed transport in tests. Production code always
//  resolves to URLSession.shared.
//

import Foundation

protocol GoogleCalendarHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionGoogleCalendarHTTPClient: GoogleCalendarHTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}
