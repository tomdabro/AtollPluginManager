//
//  GoogleCalendarLoopbackServer.swift
//  AtollPluginManager
//
//  One-shot localhost-only HTTP listener that captures a single OAuth
//  redirect (`GET /callback?code=...&state=...`) and returns its query
//  items, then shuts itself down.
//
//  Google's "Desktop app" OAuth client type requires a loopback redirect per
//  RFC 8252 -- and Google's own sign-in pages reject requests originating
//  from an embedded WebView with `Error 403: disallowed_useragent`, which
//  rules out ASWebAuthenticationSession (WebKit-backed). The browser step
//  must be the user's real system browser (opened via NSWorkspace), so this
//  app has to run the loopback server itself to catch the redirect.
//

import Foundation
import Network

final class GoogleCalendarLoopbackServer {
    enum ServerError: Error {
        case bindFailed(String)
        case timedOut
        case invalidRequest
    }

    private let queue = DispatchQueue(label: "com.atollpluginmanager.GoogleCalendarLoopback")
    private var listener: NWListener?

    /// A connection that has arrived and finished its TCP handshake but
    /// hasn't been claimed by `waitForCallback` yet -- rare (would require
    /// the browser to redirect before the caller even reaches the next
    /// line after `start()`), but handled structurally rather than assumed
    /// away, since `newConnectionHandler` must be registered before
    /// `start()` is called (see below), which is earlier than callers
    /// naturally start waiting.
    private var pendingConnection: NWConnection?
    private var callbackFinish: ((Result<[URLQueryItem], Error>) -> Void)?

    /// Binds an ephemeral port on 127.0.0.1 and returns it once ready.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw ServerError.bindFailed(error.localizedDescription)
        }
        self.listener = listener

        // Network.framework requires a connection handler to be set before
        // `start()` is called -- starting without one fails immediately with
        // EINVAL ("Started without setting either new connection handler or
        // new connection group handler", confirmed via `log show`). The
        // actual redirect can't be claimed until `waitForCallback` supplies
        // its completion, so an early arrival is parked in
        // `pendingConnection` and handed off once that completion exists.
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.handleNewConnection(connection) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    let port = listener.port?.rawValue ?? 0
                    if port == 0 {
                        continuation.resume(throwing: ServerError.bindFailed("No port was assigned."))
                        self?.stop()
                    } else {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: ServerError.bindFailed(error.localizedDescription))
                    self?.stop()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the single redirect request and returns its query items.
    /// Times out so an abandoned or never-opened browser tab cannot hang the
    /// caller forever; a timeout is treated as a user cancellation.
    func waitForCallback(timeout: TimeInterval) async throws -> [URLQueryItem] {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            func finish(_ result: Result<[URLQueryItem], Error>) {
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let items): continuation.resume(returning: items)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            queue.async { [weak self] in
                self?.callbackFinish = finish
                self?.tryDeliverPendingConnection()
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(ServerError.timedOut))
            }
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        guard pendingConnection == nil else {
            // Already have one in flight; a browser prefetch/favicon probe
            // or similar stray connection is simply dropped.
            connection.cancel()
            return
        }
        pendingConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.queue.async { self?.tryDeliverPendingConnection() }
            }
        }
        connection.start(queue: queue)
    }

    /// Fires once both halves exist: a connection that finished its
    /// handshake, and a `waitForCallback` completion to deliver the result
    /// to. Either can arrive first; this is the single funnel for both orderings.
    private func tryDeliverPendingConnection() {
        guard let connection = pendingConnection, let finish = callbackFinish else { return }
        pendingConnection = nil
        callbackFinish = nil
        receiveRequest(on: connection, finish: finish)
    }

    private func receiveRequest(
        on connection: NWConnection,
        finish: @escaping (Result<[URLQueryItem], Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                finish(.failure(error))
                connection.cancel()
                return
            }
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.components(separatedBy: "\r\n").first,
                  let pathStart = requestLine.range(of: " "),
                  let pathEnd = requestLine.range(of: " HTTP/", range: pathStart.upperBound..<requestLine.endIndex)
            else {
                self.respond(on: connection, success: false)
                finish(.failure(ServerError.invalidRequest))
                return
            }
            let path = String(requestLine[pathStart.upperBound..<pathEnd.lowerBound])
            let items = URLComponents(string: "http://127.0.0.1" + path)?.queryItems ?? []
            self.respond(on: connection, success: items.contains { $0.name == "code" })
            finish(.success(items))
        }
    }

    private func respond(on connection: NWConnection, success: Bool) {
        let title = success ? "Connected" : "Something went wrong"
        let message = success
            ? "Google Calendar is connected. You can close this tab and return to AtollPluginManager."
            : "AtollPluginManager did not receive an authorization code. You can close this tab and try again."
        let body = """
        <html><body style="font-family: -apple-system, sans-serif; text-align: center; padding-top: 4rem; color: #222;">
        <h2>\(title)</h2><p>\(message)</p>
        </body></html>
        """
        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(headers.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func stop() {
        listener?.cancel()
        listener = nil
        pendingConnection?.cancel()
        pendingConnection = nil
        callbackFinish = nil
    }
}
