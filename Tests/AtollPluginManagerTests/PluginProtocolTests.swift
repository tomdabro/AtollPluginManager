//
//  PluginProtocolTests.swift
//  AtollPluginManagerTests
//

import XCTest
import AtollExtensionKit
@testable import AtollPluginManager

final class PluginProtocolTests: XCTestCase {
    func testDecodesPresentActivityMessage() throws {
        let json = """
        {"type":"presentActivity","id":"my-timer","title":"Brewing","subtitle":"3:00 left","icon":"timer","accentColorHex":"#FF8800","priority":"high"}
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(PluginMessage.self, from: json)
        XCTAssertEqual(message.type, .presentActivity)
        XCTAssertEqual(message.id, "my-timer")
        XCTAssertEqual(message.title, "Brewing")
    }

    func testDecodesDismissActivityMessageWithoutOptionalFields() throws {
        let json = #"{"type":"dismissActivity","id":"my-timer"}"#.data(using: .utf8)!
        let message = try JSONDecoder().decode(PluginMessage.self, from: json)
        XCTAssertEqual(message.type, .dismissActivity)
        XCTAssertNil(message.title)
    }

    func testMakeDescriptorQualifiesIDWithPluginPrefixAndBrokerBundleIdentifier() throws {
        let message = PluginMessage(type: .presentActivity, id: "my-timer", title: "Brewing")
        let descriptor = try message.makeDescriptor(qualifiedID: "cliamp:my-timer", brokerBundleIdentifier: "com.atollpluginmanager.broker")

        XCTAssertEqual(descriptor.id, "cliamp:my-timer")
        XCTAssertEqual(descriptor.bundleIdentifier, "com.atollpluginmanager.broker")
        XCTAssertEqual(descriptor.title, "Brewing")
        XCTAssertEqual(descriptor.priority, .normal)
    }

    func testMakeDescriptorThrowsWithoutTitle() {
        let message = PluginMessage(type: .presentActivity, id: "x", title: nil)
        XCTAssertThrowsError(try message.makeDescriptor(qualifiedID: "p:x", brokerBundleIdentifier: "broker")) { error in
            XCTAssertEqual(error as? PluginMessageError, .missingTitle)
        }
    }

    func testMakeDescriptorParsesAccentColorHex() throws {
        let message = PluginMessage(type: .presentActivity, id: "x", title: "T", accentColorHex: "#FF8800")
        let descriptor = try message.makeDescriptor(qualifiedID: "p:x", brokerBundleIdentifier: "broker")

        XCTAssertEqual(descriptor.accentColor.red, 1.0, accuracy: 0.01)
        XCTAssertEqual(descriptor.accentColor.green, 136.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(descriptor.accentColor.blue, 0.0, accuracy: 0.01)
    }

    func testMakeDescriptorRejectsMalformedAccentColorHex() {
        let message = PluginMessage(type: .presentActivity, id: "x", title: "T", accentColorHex: "not-a-color")
        XCTAssertThrowsError(try message.makeDescriptor(qualifiedID: "p:x", brokerBundleIdentifier: "broker"))
    }

    func testMakeDescriptorParsesPriority() throws {
        let message = PluginMessage(type: .presentActivity, id: "x", title: "T", priority: "critical")
        let descriptor = try message.makeDescriptor(qualifiedID: "p:x", brokerBundleIdentifier: "broker")
        XCTAssertEqual(descriptor.priority, .critical)
    }

    func testMakeDescriptorRejectsUnknownPriority() {
        let message = PluginMessage(type: .presentActivity, id: "x", title: "T", priority: "urgent")
        XCTAssertThrowsError(try message.makeDescriptor(qualifiedID: "p:x", brokerBundleIdentifier: "broker"))
    }

    func testMakeDescriptorDefaultsToSymbolNoneIconWhenOmitted() throws {
        let message = PluginMessage(type: .presentActivity, id: "x", title: "T")
        let descriptor = try message.makeDescriptor(qualifiedID: "p:x", brokerBundleIdentifier: "broker")
        XCTAssertEqual(descriptor.leadingIcon, .none)
    }
}

extension PluginMessageError: Equatable {
    public static func == (lhs: PluginMessageError, rhs: PluginMessageError) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }
}
