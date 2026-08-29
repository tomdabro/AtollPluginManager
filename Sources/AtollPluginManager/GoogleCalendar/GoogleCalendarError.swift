//
//  GoogleCalendarError.swift
//  AtollPluginManager
//
//  Raw failure states of the broker-native Google Calendar integration.
//  Cases carry no user-facing text: the UI owns the wording.
//

import Foundation

enum GoogleCalendarError: Error, Equatable {
    /// The user has not pasted a Client ID from their Google Cloud project.
    case missingClientID
    /// The user has not pasted the Client Secret paired with that Client ID.
    case missingClientSecret
    /// SecRandomCopyBytes failed; continuing would use predictable PKCE material.
    case secureRandomUnavailable
    /// The user closed the browser tab, or the loopback callback timed out
    /// waiting for it. Not surfaced as an error.
    case canceled
    /// The local loopback HTTP listener could not bind or accept a connection.
    case loopbackServerFailed(String)
    case missingAuthorizationCode
    /// The redirect's `state` parameter didn't match what was sent -- possible
    /// CSRF, or a stray/duplicate browser navigation. Aborts rather than
    /// trusting the code.
    case stateMismatch
    case tokenExchangeFailed(String)
    /// Google rejected the refresh token: the user revoked the app, or it
    /// expired (unverified test-mode apps expire refresh tokens after seven
    /// days). The token pair has been cleared; the user must reconnect.
    case refreshTokenRevoked
}
