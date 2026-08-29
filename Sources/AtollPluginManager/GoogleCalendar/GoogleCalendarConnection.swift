//
//  GoogleCalendarConnection.swift
//  AtollPluginManager
//
//  Broker-native Google Calendar integration: unlike media sources, there's
//  no independently-useful external "Google Calendar" plugin process to
//  relay -- this actor does the OAuth + REST polling itself and pushes
//  snapshots to Atoll over the calendar-source RPC channel, mirroring
//  MediaPluginConnection's relationship to `relay` but without a Unix
//  socket to an external process.
//

import Foundation

actor GoogleCalendarConnection {
    static let sourceID = "google-calendar"
    static let sourceName = "Google Calendar"

    /// How far ahead/behind "now" each poll fetches events for -- generous
    /// enough to cover the notch's day view and the lock screen's "all time"
    /// lookahead option without Atoll needing to ask the broker for a
    /// specific window (this is push-based: whatever's published here is
    /// all Atoll has until the next poll).
    private static let lookBehind: TimeInterval = 24 * 3600
    private static let lookAhead: TimeInterval = 60 * 24 * 3600
    /// Google API quota is generous for a single desktop app; this is about
    /// keeping calendar data reasonably fresh without polling pointlessly
    /// often for something that isn't as latency-sensitive as Now Playing state.
    private static let pollInterval: TimeInterval = 180

    private let relay: any CalendarRelay
    private let oauth: GoogleCalendarOAuthService
    private let api: GoogleCalendarAPI
    private let tokenStore: GoogleCalendarTokenStoring
    private let onLog: @Sendable (String) -> Void

    private var pollTask: Task<Void, Never>?
    private var isRegistered = false

    private(set) var isAuthenticated = false
    private(set) var isAuthorizing = false
    private(set) var error: GoogleCalendarError?
    private(set) var isEnabled = true
    private var onStateChange: (@MainActor () -> Void)?

    init(
        relay: any CalendarRelay,
        tokenStore: GoogleCalendarTokenStoring = KeychainGoogleCalendarTokenStore(),
        httpClient: GoogleCalendarHTTPClient = URLSessionGoogleCalendarHTTPClient(),
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.relay = relay
        self.tokenStore = tokenStore
        let oauth = GoogleCalendarOAuthService(tokenStore: tokenStore, httpClient: httpClient)
        self.oauth = oauth
        self.api = GoogleCalendarAPI(tokenProvider: oauth, httpClient: httpClient)
        self.onLog = onLog
    }

    /// The UI's `@MainActor` bridge wires this up before calling `start()`.
    func setOnStateChange(_ handler: @escaping @MainActor () -> Void) {
        onStateChange = handler
    }

    private func notifyStateChange() {
        guard let onStateChange else { return }
        Task { @MainActor in onStateChange() }
    }

    /// Resumes polling on launch if a token pair is already stored and the
    /// integration hasn't been paused, without requiring the user to click
    /// Connect again every relaunch.
    func start() async {
        refreshAuthenticationState()
        isEnabled = GoogleCalendarPreferences.isEnabled()
        if isAuthenticated && isEnabled {
            startPolling()
        }
    }

    func getClientSecret() -> String {
        tokenStore.read(.clientSecret) ?? ""
    }

    func setClientSecret(_ newValue: String) {
        if newValue.isEmpty {
            tokenStore.delete(.clientSecret)
        } else {
            tokenStore.write(newValue, account: .clientSecret)
        }
    }

    // MARK: - Connect / Disconnect

    func connect() async {
        error = nil
        notifyStateChange()
        let clientID = GoogleCalendarPreferences.clientID().trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = getClientSecret().trimmingCharacters(in: .whitespacesAndNewlines)
        onLog("connect() clientID.isEmpty=\(clientID.isEmpty) secret.isEmpty=\(secret.isEmpty)")
        guard !clientID.isEmpty else {
            error = .missingClientID
            notifyStateChange()
            return
        }
        guard !secret.isEmpty else {
            error = .missingClientSecret
            notifyStateChange()
            return
        }

        isAuthorizing = true
        notifyStateChange()

        do {
            onLog("calling oauth.authorize()")
            try await oauth.authorize(clientID: clientID, clientSecret: secret)
            onLog("oauth.authorize() succeeded")
            error = nil
        } catch GoogleCalendarError.canceled {
            onLog("oauth.authorize() canceled/timed out")
            // The user closed the browser tab, or never got to it; not an error.
        } catch let calendarError as GoogleCalendarError {
            onLog("oauth.authorize() failed: \(calendarError)")
            error = calendarError
        } catch {
            onLog("oauth.authorize() failed with unexpected error: \(error)")
            self.error = .loopbackServerFailed(String(describing: error))
        }

        isAuthorizing = false
        refreshAuthenticationState()
        if isAuthenticated {
            isEnabled = true
            GoogleCalendarPreferences.setEnabled(true)
            startPolling()
        }
        notifyStateChange()
    }

    /// Pauses or resumes without touching the OAuth token pair: turning it
    /// back on resumes immediately, no reconnect needed. Distinct from
    /// disconnect(), which clears tokens and requires a fresh sign-in.
    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        GoogleCalendarPreferences.setEnabled(enabled)
        if enabled {
            if isAuthenticated {
                startPolling()
            }
        } else {
            stopPolling()
            if isRegistered {
                try? await relay.unregisterCalendarSource(sourceID: Self.sourceID)
                isRegistered = false
            }
        }
        notifyStateChange()
    }

    func disconnect() async {
        stopPolling()
        if isRegistered {
            try? await relay.unregisterCalendarSource(sourceID: Self.sourceID)
            isRegistered = false
        }
        await oauth.clearTokens()
        error = nil
        isEnabled = true
        GoogleCalendarPreferences.setEnabled(true)
        refreshAuthenticationState()
        notifyStateChange()
    }

    /// A still-authenticated connection never gets a reason to re-register
    /// just because Atoll itself restarted -- polling keeps running against
    /// the same broker-side `isRegistered = true` flag, but the fresh Atoll
    /// instance has forgotten the source entirely, so the next publish would
    /// fail with "sourceID not owned by this connection" (same class of bug
    /// already fixed for media sources via
    /// `MediaPluginConnection.resyncRegistration()`). Resetting the flag and
    /// running a poll immediately re-registers and republishes in one step,
    /// rather than waiting up to `pollInterval` for the next scheduled poll.
    func resyncRegistration() async {
        guard isAuthenticated, isEnabled else { return }
        isRegistered = false
        await pollOnce()
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { await self.pollLoop() }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
    }

    private func pollOnce() async {
        if !isRegistered {
            do {
                try await relay.registerCalendarSource(sourceID: Self.sourceID, name: Self.sourceName, accountLabel: nil)
                isRegistered = true
            } catch {
                onLog("[google-calendar] failed to register calendar source: \(error.localizedDescription)")
                return
            }
        }

        let calendars = await api.calendars()
        let now = Date()
        let start = now.addingTimeInterval(-Self.lookBehind)
        let end = now.addingTimeInterval(Self.lookAhead)
        let events = await api.events(from: start, to: end, calendarIDs: calendars.map { $0.id })
        onLog("[google-calendar] fetched \(calendars.count) calendars, \(events.count) events")

        do {
            try await relay.publishCalendarState(sourceID: Self.sourceID, calendars: calendars, events: events)
            onLog("[google-calendar] published state to Atoll successfully")
        } catch {
            onLog("[google-calendar] failed to publish calendar state: \(error.localizedDescription)")
        }
    }

    // MARK: - State

    private func refreshAuthenticationState() {
        let hasRefreshToken = !(tokenStore.read(.refreshToken) ?? "").isEmpty
        isAuthenticated = hasRefreshToken && !GoogleCalendarPreferences.clientID().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
