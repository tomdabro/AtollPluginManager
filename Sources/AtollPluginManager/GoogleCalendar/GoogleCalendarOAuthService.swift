//
//  GoogleCalendarOAuthService.swift
//  AtollPluginManager
//
//  OAuth 2.0 PKCE against Google's identity platform, using a loopback HTTP
//  redirect (RFC 8252) rather than a custom URL scheme -- see
//  GoogleCalendarLoopbackServer for why. Owns nothing user-facing.
//

import AppKit
import CryptoKit
import Foundation
import Security

/// Narrow view of the OAuth service for consumers that only need a bearer
/// token, so the API client stays unaware of PKCE.
protocol GoogleCalendarTokenProviding: Sendable {
    func validAccessToken(forceRefresh: Bool) async -> String?
}

actor GoogleCalendarOAuthService: GoogleCalendarTokenProviding {
    private static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let scope = "https://www.googleapis.com/auth/calendar.readonly"

    /// Treat a token as expired this many seconds early, so a request sent
    /// just under the wire cannot arrive at Google after the real expiry.
    private static let expiryLeeway: TimeInterval = 60
    /// How long to wait for the user to complete sign-in in the browser
    /// before giving up on the loopback listener.
    private static let callbackTimeout: TimeInterval = 180

    /// Fires whenever the stored token pair changes, including refreshes
    /// that originate from a background API call rather than from a
    /// connect()/disconnect() call.
    var onTokenStateChange: (@Sendable () -> Void)?

    private let tokenStore: GoogleCalendarTokenStoring
    private let httpClient: GoogleCalendarHTTPClient

    /// Google rotates the refresh token only occasionally, but concurrent
    /// refreshes should still share a single in-flight request.
    private var refreshTask: Task<String?, Never>?
    private var tokenExpiration: TimeInterval = 0

    init(tokenStore: GoogleCalendarTokenStoring, httpClient: GoogleCalendarHTTPClient) {
        self.tokenStore = tokenStore
        self.httpClient = httpClient
        self.tokenExpiration = GoogleCalendarPreferences.tokenExpiration()
    }

    // MARK: - Authorization

    func authorize(clientID: String, clientSecret: String) async throws {
        guard let verifier = Self.randomURLSafeString(length: 64),
              let state = Self.randomURLSafeString(length: 24)
        else {
            throw GoogleCalendarError.secureRandomUnavailable
        }
        let challenge = Self.codeChallenge(for: verifier)

        let server = GoogleCalendarLoopbackServer()
        let port: UInt16
        do {
            port = try await server.start()
        } catch {
            throw GoogleCalendarError.loopbackServerFailed(String(describing: error))
        }
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            // offline + consent guarantees a refresh_token on every connect,
            // not just the very first consent for this Google account.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]

        guard let url = components.url else {
            server.stop()
            throw GoogleCalendarError.loopbackServerFailed("Could not build the Google authorization URL.")
        }

        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            server.stop()
            throw GoogleCalendarError.loopbackServerFailed("Could not open the system browser.")
        }

        let items: [URLQueryItem]
        do {
            items = try await server.waitForCallback(timeout: Self.callbackTimeout)
        } catch GoogleCalendarLoopbackServer.ServerError.timedOut {
            server.stop()
            throw GoogleCalendarError.canceled
        } catch {
            server.stop()
            throw GoogleCalendarError.loopbackServerFailed(String(describing: error))
        }
        server.stop()

        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw GoogleCalendarError.stateMismatch
        }
        if let errorParam = items.first(where: { $0.name == "error" })?.value {
            throw GoogleCalendarError.tokenExchangeFailed(errorParam)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw GoogleCalendarError.missingAuthorizationCode
        }

        try await exchangeToken(
            body: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI,
                "client_id": clientID,
                "client_secret": clientSecret,
                "code_verifier": verifier
            ],
            clientSecret: clientSecret,
            grant: .authorizationCode
        )
    }

    func clearTokens() {
        tokenStore.delete(.accessToken)
        tokenStore.delete(.refreshToken)
        tokenExpiration = 0
        GoogleCalendarPreferences.setTokenExpiration(0)
    }

    // MARK: - Tokens

    func validAccessToken(forceRefresh: Bool = false) async -> String? {
        if !forceRefresh,
           let cachedToken = tokenStore.read(.accessToken),
           !cachedToken.isEmpty,
           tokenExpiration > Date().timeIntervalSince1970 + Self.expiryLeeway {
            return cachedToken
        }

        if let refreshTask {
            return await refreshTask.value
        }

        guard let refreshToken = tokenStore.read(.refreshToken), !refreshToken.isEmpty else { return nil }
        let clientID = GoogleCalendarPreferences.clientID()
        let clientSecret = tokenStore.read(.clientSecret) ?? ""
        guard !clientID.isEmpty, !clientSecret.isEmpty else { return nil }

        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            do {
                try await self.exchangeToken(
                    body: [
                        "grant_type": "refresh_token",
                        "refresh_token": refreshToken,
                        "client_id": clientID,
                        "client_secret": clientSecret
                    ],
                    clientSecret: clientSecret,
                    grant: .refresh
                )
                return await self.currentAccessToken()
            } catch {
                return nil
            }
        }
        refreshTask = task
        let token = await task.value
        refreshTask = nil
        return token
    }

    private func currentAccessToken() -> String? {
        tokenStore.read(.accessToken)
    }

    private enum Grant {
        case authorizationCode
        case refresh
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct TokenErrorResponse: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private func exchangeToken(body: [String: String], clientSecret: String, grant: Grant) async throws {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, httpResponse) = try await httpClient.data(for: request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw tokenError(from: data, grant: grant)
        }

        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        tokenStore.write(token.accessToken, account: .accessToken)
        if let refreshToken = token.refreshToken, !refreshToken.isEmpty {
            tokenStore.write(refreshToken, account: .refreshToken)
        }
        // Written on every successful exchange so a refresh after relaunch
        // always has the secret available, without duplicating it in UserDefaults.
        tokenStore.write(clientSecret, account: .clientSecret)
        tokenExpiration = Date().timeIntervalSince1970 + token.expiresIn
        GoogleCalendarPreferences.setTokenExpiration(tokenExpiration)
        onTokenStateChange?()
    }

    /// A refresh token dying server-side (revoked, or a test-mode app's
    /// 7-day expiry) surfaces here as `invalid_grant`. Without clearing the
    /// pair the connection would keep reporting itself connected while every
    /// poll silently returns nothing.
    private func tokenError(from data: Data, grant: Grant) -> GoogleCalendarError {
        guard let decoded = try? JSONDecoder().decode(TokenErrorResponse.self, from: data) else {
            return .tokenExchangeFailed(URLError(.userAuthenticationRequired).localizedDescription)
        }
        if grant == .refresh, decoded.error == "invalid_grant" {
            clearTokens()
            onTokenStateChange?()
            return .refreshTokenRevoked
        }
        return .tokenExchangeFailed(decoded.errorDescription ?? decoded.error)
    }

    // MARK: - PKCE helpers

    private static func randomURLSafeString(length: Int) -> String? {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, length, &bytes) == errSecSuccess else {
            return nil
        }
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
