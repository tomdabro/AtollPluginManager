//
//  GoogleCalendarOAuthServiceTests.swift
//  AtollPluginManagerTests
//
//  Covers the token refresh path headlessly (no browser, no network):
//  authorize() itself needs a real loopback listener + system browser and
//  isn't exercised here, but validAccessToken(forceRefresh:)'s cache/refresh/
//  invalid_grant behavior is pure state machine logic over the injected
//  GoogleCalendarHTTPClient and GoogleCalendarTokenStoring seams.
//

import XCTest
@testable import AtollPluginManager

/// `GoogleCalendarTokenStoring` is `Sendable` but not `Actor`-isolated in its
/// protocol requirements, so the fake exposes synchronous, non-isolated
/// access backed by an internal lock rather than requiring every call site
/// to `await` an actor -- mirroring how the production Keychain store is
/// itself synchronous.
private final class SyncFakeGoogleCalendarTokenStore: GoogleCalendarTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GoogleCalendarTokenAccount: String] = [:]

    func read(_ account: GoogleCalendarTokenAccount) -> String? {
        lock.withLock { values[account] }
    }

    @discardableResult
    func write(_ value: String, account: GoogleCalendarTokenAccount) -> OSStatus {
        lock.withLock { values[account] = value }
        return errSecSuccess
    }

    @discardableResult
    func delete(_ account: GoogleCalendarTokenAccount) -> OSStatus {
        lock.withLock { values.removeValue(forKey: account) }
        return errSecSuccess
    }
}

private final class FakeGoogleCalendarHTTPClient: GoogleCalendarHTTPClient, @unchecked Sendable {
    var nextStatusCode = 200
    var nextBody = Data()
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: nextStatusCode, httpVersion: nil, headerFields: nil)!
        return (nextBody, response)
    }
}

final class GoogleCalendarOAuthServiceTests: XCTestCase {
    /// GoogleCalendarPreferences is backed by UserDefaults.standard, which
    /// persists to disk across process launches -- unlike the fakes above,
    /// it isn't reset just by constructing a fresh service, so every test
    /// must reset it explicitly or a value written by one test (or a prior
    /// `swift test` run) leaks into the next.
    override func setUp() {
        super.setUp()
        GoogleCalendarPreferences.setClientID("")
        GoogleCalendarPreferences.setTokenExpiration(0)
    }

    override func tearDown() {
        GoogleCalendarPreferences.setClientID("")
        GoogleCalendarPreferences.setTokenExpiration(0)
        super.tearDown()
    }

    private func makeService() -> (GoogleCalendarOAuthService, SyncFakeGoogleCalendarTokenStore, FakeGoogleCalendarHTTPClient) {
        let tokenStore = SyncFakeGoogleCalendarTokenStore()
        let httpClient = FakeGoogleCalendarHTTPClient()
        let service = GoogleCalendarOAuthService(tokenStore: tokenStore, httpClient: httpClient)
        return (service, tokenStore, httpClient)
    }

    func testValidAccessTokenWithNoRefreshTokenReturnsNilWithoutNetworkCall() async {
        let (service, tokenStore, httpClient) = makeService()
        tokenStore.write("cached-access-token", account: .accessToken)
        // No refresh token stored, and the cached access token's expiry
        // (seeded from GoogleCalendarPreferences, reset to 0 in setUp) is
        // already in the past -- validAccessToken must fall through to nil
        // rather than fabricating a valid token or attempting a refresh it
        // has no token for.
        let token = await service.validAccessToken(forceRefresh: false)
        XCTAssertNil(token)
        XCTAssertTrue(httpClient.requests.isEmpty)
    }

    func testValidAccessTokenRefreshesWhenNoCachedTokenIsValid() async {
        let (service, tokenStore, httpClient) = makeService()
        tokenStore.write("stale-refresh-token", account: .refreshToken)
        tokenStore.write("secret", account: .clientSecret)
        GoogleCalendarPreferences.setClientID("test-client-id")

        httpClient.nextStatusCode = 200
        httpClient.nextBody = Data("""
        {"access_token":"fresh-token","refresh_token":"rotated-refresh-token","expires_in":3600}
        """.utf8)

        let token = await service.validAccessToken(forceRefresh: true)
        XCTAssertEqual(token, "fresh-token")
        XCTAssertEqual(tokenStore.read(.refreshToken), "rotated-refresh-token")
        XCTAssertEqual(httpClient.requests.count, 1)
        XCTAssertEqual(httpClient.requests.first?.url?.absoluteString, "https://oauth2.googleapis.com/token")
    }

    func testInvalidGrantOnRefreshClearsTokenPair() async {
        let (service, tokenStore, httpClient) = makeService()
        tokenStore.write("revoked-refresh-token", account: .refreshToken)
        tokenStore.write("secret", account: .clientSecret)
        GoogleCalendarPreferences.setClientID("test-client-id")

        httpClient.nextStatusCode = 400
        httpClient.nextBody = Data("""
        {"error":"invalid_grant","error_description":"Token has been expired or revoked."}
        """.utf8)

        let token = await service.validAccessToken(forceRefresh: true)
        XCTAssertNil(token)
        XCTAssertNil(tokenStore.read(.refreshToken), "invalid_grant must clear the refresh token so the UI stops reporting a live connection")
        XCTAssertNil(tokenStore.read(.accessToken))
    }

    func testConcurrentRefreshCallsShareOneInFlightRequest() async {
        let (service, tokenStore, httpClient) = makeService()
        tokenStore.write("stale-refresh-token", account: .refreshToken)
        tokenStore.write("secret", account: .clientSecret)
        GoogleCalendarPreferences.setClientID("test-client-id")

        httpClient.nextStatusCode = 200
        httpClient.nextBody = Data("""
        {"access_token":"fresh-token","expires_in":3600}
        """.utf8)

        async let first = service.validAccessToken(forceRefresh: true)
        async let second = service.validAccessToken(forceRefresh: true)
        let (firstToken, secondToken) = await (first, second)

        XCTAssertEqual(firstToken, "fresh-token")
        XCTAssertEqual(secondToken, "fresh-token")
        XCTAssertEqual(httpClient.requests.count, 1, "two concurrent refreshes must share a single token exchange")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
