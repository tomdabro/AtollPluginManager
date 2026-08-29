//
//  RPCWireTypes.swift
//  AtollPluginManager
//
//  JSON-RPC 2.0 wire types matching Atoll's ExtensionRPCServer
//  (ws://127.0.0.1:9020). Kept separate from any Atoll source so this app
//  only ever depends on AtollExtensionKit for descriptor types.
//

import Foundation

/// Outgoing JSON-RPC 2.0 request.
struct RPCRequest: Codable {
    let jsonrpc: String
    let method: String
    let params: [String: RPCValue]?
    let id: String

    init(method: String, params: [String: RPCValue]?, id: String = UUID().uuidString) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
        self.id = id
    }
}

/// Incoming JSON-RPC 2.0 response — success and error are mutually exclusive,
/// so this decodes whichever is present rather than picking a side up front.
struct RPCResponse: Codable {
    let jsonrpc: String
    let result: [String: RPCValue]?
    let error: RPCErrorObject?
    let id: String?
}

/// Incoming JSON-RPC 2.0 notification (server → client, no id).
struct RPCNotification: Codable {
    let jsonrpc: String
    let method: String
    let params: [String: RPCValue]?
}

struct RPCErrorObject: Codable {
    let code: Int
    let message: String
    let data: String?
}

enum RPCErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let unauthorized = -32001
    static let featureDisabled = -32002
    static let capacityExceeded = -32003
    static let descriptorInvalid = -32004
    static let unsupported = -32005
}

/// Type-erased JSON value, matching Atoll's `RPCValue` field-for-field so
/// encoding/decoding round-trips identically over the wire.
enum RPCValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case object([String: RPCValue])
    case array([RPCValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let obj = try? container.decode([String: RPCValue].self) {
            self = .object(obj)
        } else if let arr = try? container.decode([RPCValue].self) {
            self = .array(arr)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Wrap any `Encodable` value (e.g. an `AtollExtensionKit` descriptor) as
    /// an `RPCValue` by round-tripping it through JSON.
    static func encoding<T: Encodable>(_ value: T, using encoder: JSONEncoder = JSONEncoder()) throws -> RPCValue {
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(RPCValue.self, from: data)
    }
}

/// Errors surfaced by `AtollRPCClient`.
struct AtollRPCError: Error, LocalizedError, Equatable {
    let code: Int
    let message: String

    var errorDescription: String? { message }

    static func fromWire(_ object: RPCErrorObject) -> AtollRPCError {
        AtollRPCError(code: object.code, message: object.message)
    }

    static let notConnected = AtollRPCError(code: RPCErrorCode.internalError, message: "Not connected to Atoll")
    static let malformedResponse = AtollRPCError(code: RPCErrorCode.parseError, message: "Malformed response from Atoll")
}
