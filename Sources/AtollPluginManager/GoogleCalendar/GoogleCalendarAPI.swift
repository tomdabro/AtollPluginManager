//
//  GoogleCalendarAPI.swift
//  AtollPluginManager
//
//  Read-only Google Calendar API v3 access: calendarList + per-calendar
//  events, scoped to calendar.readonly (this broker never writes to Google
//  Calendar). Maps Google's JSON directly into the wire payload structs
//  published to Atoll, so no intermediate model is needed.
//

import Foundation

actor GoogleCalendarAPI {
    private static let baseURL = "https://www.googleapis.com/calendar/v3"

    private let tokenProvider: GoogleCalendarTokenProviding
    private let httpClient: GoogleCalendarHTTPClient

    init(tokenProvider: GoogleCalendarTokenProviding, httpClient: GoogleCalendarHTTPClient) {
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
    }

    func calendars() async -> [CalendarSourceCalendarPayload] {
        guard let data = await request(path: "/users/me/calendarList?minAccessRole=reader&maxResults=250") else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode(GoogleCalendarListResponse.self, from: data) else {
            return []
        }
        return decoded.items.map {
            CalendarSourceCalendarPayload(
                id: $0.id,
                title: $0.summary ?? $0.id,
                colorHex: $0.backgroundColor ?? "#4285F4",
                isSubscribed: $0.primary != true
            )
        }
    }

    /// Fans out across every requested calendar concurrently.
    func events(from start: Date, to end: Date, calendarIDs: [String]) async -> [CalendarSourceEventPayload] {
        guard !calendarIDs.isEmpty else { return [] }

        let formatter = ISO8601DateFormatter()
        let timeMin = formatter.string(from: start)
        let timeMax = formatter.string(from: end)

        return await withTaskGroup(of: [CalendarSourceEventPayload].self) { group in
            for id in calendarIDs {
                group.addTask { [weak self] in
                    await self?.events(calendarID: id, timeMin: timeMin, timeMax: timeMax) ?? []
                }
            }
            var all: [CalendarSourceEventPayload] = []
            for await events in group {
                all.append(contentsOf: events)
            }
            return all
        }
    }

    private func events(calendarID: String, timeMin: String, timeMax: String) async -> [CalendarSourceEventPayload] {
        guard let encodedID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return [] }
        let path = "/calendars/\(encodedID)/events"
            + "?singleEvents=true&orderBy=startTime&maxResults=250"
            + "&timeMin=\(timeMin)&timeMax=\(timeMax)"
        guard let data = await request(path: path) else { return [] }
        guard let decoded = try? JSONDecoder().decode(GoogleEventListResponse.self, from: data) else { return [] }

        return decoded.items.compactMap { item -> CalendarSourceEventPayload? in
            // Cancelled instances of a recurring event still appear in the feed; skip them.
            guard item.status != "cancelled" else { return nil }
            guard let start = item.start, let end = item.end else { return nil }

            let startString = start.dateTime ?? start.date
            let endString = end.dateTime ?? end.date
            guard let startString, let endString else { return nil }

            let attendees = item.attendees ?? []
            let participants = attendees.map { attendee in
                CalendarSourceParticipantPayload(
                    name: attendee.displayName ?? attendee.email ?? "",
                    status: attendee.responseStatus ?? "unknown",
                    isOrganizer: attendee.organizer == true,
                    isCurrentUser: attendee.isSelf == true
                )
            }
            let selfResponseStatus = attendees.first(where: { $0.isSelf == true })?.responseStatus

            return CalendarSourceEventPayload(
                id: item.id,
                calendarID: calendarID,
                title: item.summary ?? "",
                start: startString,
                end: endString,
                isAllDay: start.dateTime == nil,
                location: item.location,
                notes: item.description,
                url: item.htmlLink,
                attendanceStatus: selfResponseStatus,
                participants: participants,
                timeZoneIdentifier: start.timeZone,
                hasRecurrenceRules: item.recurringEventId != nil,
                conferenceURL: Self.conferenceURL(from: item)
            )
        }
    }

    private static func conferenceURL(from item: GoogleCalendarEventItem) -> String? {
        if let hangout = item.hangoutLink { return hangout }
        guard let entryPoints = item.conferenceData?.entryPoints else { return nil }
        let video = entryPoints.first { $0.entryPointType == "video" } ?? entryPoints.first
        return video?.uri
    }

    /// A 401 retries once against a force-refreshed token; any other failure
    /// (including a second 401) returns nil rather than throwing -- the poll
    /// loop just retries on its own schedule.
    private func request(path: String, allowUnauthorizedRetry: Bool = true) async -> Data? {
        guard let token = await tokenProvider.validAccessToken(forceRefresh: false),
              let url = URL(string: Self.baseURL + path)
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await httpClient.data(for: request) else { return nil }

        if response.statusCode == 401, allowUnauthorizedRetry {
            guard let refreshedToken = await tokenProvider.validAccessToken(forceRefresh: true) else { return nil }
            var retryRequest = URLRequest(url: url)
            retryRequest.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
            guard let (retryData, retryResponse) = try? await httpClient.data(for: retryRequest),
                  (200..<300).contains(retryResponse.statusCode)
            else { return nil }
            return retryData
        }

        guard (200..<300).contains(response.statusCode) else { return nil }
        return data
    }
}

// MARK: - REST DTOs

private struct GoogleCalendarListItem: Decodable {
    let id: String
    let summary: String?
    let backgroundColor: String?
    let primary: Bool?
}

private struct GoogleCalendarListResponse: Decodable {
    let items: [GoogleCalendarListItem]
}

private struct GoogleEventDateTime: Decodable {
    let date: String?
    let dateTime: String?
    let timeZone: String?
}

private struct GoogleEventAttendee: Decodable {
    let email: String?
    let displayName: String?
    let responseStatus: String?
    let organizer: Bool?
    let isSelf: Bool?

    enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus, organizer
        case isSelf = "self"
    }
}

private struct GoogleConferenceEntryPoint: Decodable {
    let entryPointType: String?
    let uri: String?
}

private struct GoogleConferenceData: Decodable {
    let entryPoints: [GoogleConferenceEntryPoint]?
}

private struct GoogleCalendarEventItem: Decodable {
    let id: String
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let htmlLink: String?
    let hangoutLink: String?
    let start: GoogleEventDateTime?
    let end: GoogleEventDateTime?
    let attendees: [GoogleEventAttendee]?
    let recurringEventId: String?
    let conferenceData: GoogleConferenceData?
}

private struct GoogleEventListResponse: Decodable {
    let items: [GoogleCalendarEventItem]
}
