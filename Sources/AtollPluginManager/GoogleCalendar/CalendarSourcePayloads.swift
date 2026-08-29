//
//  CalendarSourcePayloads.swift
//  AtollPluginManager
//
//  Wire payloads for `atoll.publishCalendarState`, matching Atoll's
//  CalendarSourceCalendarPayload / CalendarSourceEventPayload /
//  CalendarSourceParticipantPayload (ExtensionCalendarSourceManager.swift)
//  field-for-field -- no shared package between the two repos, so keep
//  these in sync by hand, same as RPCWireTypes.swift already is for the
//  base JSON-RPC types.
//

import Foundation

struct CalendarSourceCalendarPayload: Codable {
    let id: String
    let title: String
    let colorHex: String
    let isSubscribed: Bool
}

struct CalendarSourceParticipantPayload: Codable {
    let name: String
    let status: String
    let isOrganizer: Bool
    let isCurrentUser: Bool
}

struct CalendarSourceEventPayload: Codable {
    let id: String
    let calendarID: String
    let title: String
    let start: String
    let end: String
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: String?
    let attendanceStatus: String?
    let participants: [CalendarSourceParticipantPayload]
    let timeZoneIdentifier: String?
    let hasRecurrenceRules: Bool
    let conferenceURL: String?
}
