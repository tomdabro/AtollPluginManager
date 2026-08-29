//
//  CalendarSourcePayloadsTests.swift
//  AtollPluginManagerTests
//
//  Wire-format round-trip: these structs must decode identically on Atoll's
//  side (ExtensionCalendarSourceManager.swift), so a broken field name or
//  type here would silently drop calendar data with no compiler error on
//  either side of the RPC boundary.
//

import XCTest
@testable import AtollPluginManager

final class CalendarSourcePayloadsTests: XCTestCase {
    func testCalendarPayloadRoundTripsThroughRPCValue() throws {
        let payload = CalendarSourceCalendarPayload(
            id: "primary",
            title: "Work",
            colorHex: "#4285F4",
            isSubscribed: false
        )

        let wrapped = try RPCValue.encoding(payload)
        guard case .object(let fields) = wrapped else {
            return XCTFail("Expected an object")
        }
        XCTAssertEqual(fields["id"]?.stringValue, "primary")
        XCTAssertEqual(fields["title"]?.stringValue, "Work")
        XCTAssertEqual(fields["colorHex"]?.stringValue, "#4285F4")
        XCTAssertEqual(fields["isSubscribed"]?.boolValue, false)

        let data = try JSONEncoder().encode(wrapped)
        let decoded = try JSONDecoder().decode(CalendarSourceCalendarPayload.self, from: data)
        XCTAssertEqual(decoded.id, payload.id)
        XCTAssertEqual(decoded.title, payload.title)
        XCTAssertEqual(decoded.colorHex, payload.colorHex)
        XCTAssertEqual(decoded.isSubscribed, payload.isSubscribed)
    }

    func testEventPayloadArrayRoundTripsThroughRPCValueEncoding() throws {
        let events = [
            CalendarSourceEventPayload(
                id: "evt1",
                calendarID: "primary",
                title: "Standup",
                start: "2026-08-29T09:00:00Z",
                end: "2026-08-29T09:15:00Z",
                isAllDay: false,
                location: "Room 4",
                notes: nil,
                url: "https://example.com/evt1",
                attendanceStatus: "accepted",
                participants: [
                    CalendarSourceParticipantPayload(name: "Alice", status: "accepted", isOrganizer: true, isCurrentUser: false)
                ],
                timeZoneIdentifier: "Europe/Warsaw",
                hasRecurrenceRules: true,
                conferenceURL: "https://meet.google.com/abc-defg-hij"
            )
        ]

        let wrapped = try RPCValue.encoding(events)
        guard case .array(let items) = wrapped, items.count == 1, case .object(let fields) = items[0] else {
            return XCTFail("Expected a single-element array of objects")
        }
        XCTAssertEqual(fields["calendarID"]?.stringValue, "primary")
        XCTAssertEqual(fields["hasRecurrenceRules"]?.boolValue, true)

        let data = try JSONEncoder().encode(wrapped)
        let decoded = try JSONDecoder().decode([CalendarSourceEventPayload].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, "evt1")
        XCTAssertEqual(decoded[0].participants.first?.name, "Alice")
        XCTAssertEqual(decoded[0].conferenceURL, "https://meet.google.com/abc-defg-hij")
    }

    func testEventPayloadOmitsOptionalFieldsCleanlyWhenNil() throws {
        let event = CalendarSourceEventPayload(
            id: "evt2",
            calendarID: "primary",
            title: "Focus block",
            start: "2026-08-30",
            end: "2026-08-31",
            isAllDay: true,
            location: nil,
            notes: nil,
            url: nil,
            attendanceStatus: nil,
            participants: [],
            timeZoneIdentifier: nil,
            hasRecurrenceRules: false,
            conferenceURL: nil
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarSourceEventPayload.self, from: data)
        XCTAssertNil(decoded.location)
        XCTAssertNil(decoded.attendanceStatus)
        XCTAssertNil(decoded.conferenceURL)
        XCTAssertTrue(decoded.participants.isEmpty)
        XCTAssertTrue(decoded.isAllDay)
    }
}
