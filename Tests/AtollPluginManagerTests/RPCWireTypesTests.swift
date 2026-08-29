//
//  RPCWireTypesTests.swift
//  AtollPluginManagerTests
//

import XCTest
@testable import AtollPluginManager

final class RPCWireTypesTests: XCTestCase {
    func testRPCRequestEncodesJSONRPC20Envelope() throws {
        let request = RPCRequest(method: "atoll.presentLiveActivity", params: ["foo": .string("bar")], id: "req-1")
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json?["method"] as? String, "atoll.presentLiveActivity")
        XCTAssertEqual(json?["id"] as? String, "req-1")
        XCTAssertEqual((json?["params"] as? [String: Any])?["foo"] as? String, "bar")
    }

    func testRPCResponseDecodesSuccessResult() throws {
        let json = """
        {"jsonrpc":"2.0","result":{"authorized":true},"id":"req-1"}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RPCResponse.self, from: json)
        XCTAssertEqual(response.id, "req-1")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?["authorized"]?.boolValue, true)
    }

    func testRPCResponseDecodesErrorObject() throws {
        let json = """
        {"jsonrpc":"2.0","error":{"code":-32001,"message":"unauthorized","data":null},"id":"req-2"}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RPCResponse.self, from: json)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32001)
        XCTAssertEqual(response.error?.message, "unauthorized")
    }

    func testRPCValueEncodingWrapsEncodableAsObject() throws {
        struct Sample: Codable { let name: String; let count: Int }
        let value = try RPCValue.encoding(Sample(name: "cliamp", count: 3))

        guard case .object(let fields) = value else {
            return XCTFail("Expected .object, got \(value)")
        }
        XCTAssertEqual(fields["name"]?.stringValue, "cliamp")
        if case .int(let count) = fields["count"] {
            XCTAssertEqual(count, 3)
        } else {
            XCTFail("Expected count to decode as .int")
        }
    }

    func testAtollRPCErrorFromWirePreservesCodeAndMessage() {
        let wireError = RPCErrorObject(code: RPCErrorCode.featureDisabled, message: "Extensions are disabled", data: nil)
        let error = AtollRPCError.fromWire(wireError)
        XCTAssertEqual(error.code, RPCErrorCode.featureDisabled)
        XCTAssertEqual(error.message, "Extensions are disabled")
    }
}
