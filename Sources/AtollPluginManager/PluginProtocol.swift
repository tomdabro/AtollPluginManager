//
//  PluginProtocol.swift
//  AtollPluginManager
//
//  Minimal local protocol plugins speak to the broker over their Unix socket:
//  newline-delimited JSON, one message per line. Deliberately smaller than
//  the full Atoll descriptor surface so plugin authors don't need to know
//  AtollExtensionKit at all.
//
//  Protocol version 1. Bump `PluginProtocolVersion.current` and branch on
//  a `version` field in `PluginMessage` before changing wire shape, so
//  existing plugins aren't broken by a manager update (Phase 8).
//

import Foundation
import AtollExtensionKit

enum PluginProtocolVersion {
    static let current = 1
}

enum PluginMessageType: String, Codable {
    case presentActivity
    case updateActivity
    case dismissActivity
}

/// One line of the plugin -> broker protocol. `title` is required for
/// `presentActivity`/`updateActivity` and ignored for `dismissActivity`;
/// everything else is optional and defaults sensibly.
struct PluginMessage: Codable {
    let type: PluginMessageType
    /// Plugin-local activity id, unique within this plugin only — the broker
    /// prefixes it with the plugin id before it ever reaches Atoll.
    let id: String
    var title: String?
    var subtitle: String?
    /// SF Symbol name, e.g. "timer" or "music.note".
    var icon: String?
    /// "#RRGGBB" or "#RRGGBBAA"; omitted uses Atoll's system accent color.
    var accentColorHex: String?
    /// One of AtollLiveActivityPriority's raw values: low/normal/high/critical.
    var priority: String?
}

/// A response line the broker writes back: acknowledges a message or reports
/// why it couldn't be relayed (invalid message, Atoll rejected the
/// descriptor, RPC call failed, ...).
struct PluginResponse: Codable {
    enum Kind: String, Codable { case ack, error }
    let type: Kind
    let id: String
    var message: String?

    static func ack(id: String) -> PluginResponse { PluginResponse(type: .ack, id: id, message: nil) }
    static func error(id: String, message: String) -> PluginResponse { PluginResponse(type: .error, id: id, message: message) }
}

enum PluginMessageError: Error, LocalizedError {
    case missingTitle
    case invalidAccentColor(String)
    case invalidPriority(String)

    var errorDescription: String? {
        switch self {
        case .missingTitle: return "\"title\" is required"
        case .invalidAccentColor(let hex): return "invalid accentColorHex \"\(hex)\" — expected #RRGGBB or #RRGGBBAA"
        case .invalidPriority(let value): return "invalid priority \"\(value)\" — expected low/normal/high/critical"
        }
    }
}

extension PluginMessage {
    /// Builds the full Atoll descriptor for a `presentActivity`/`updateActivity`
    /// message. `qualifiedID` is `"<pluginID>:<localID>"` — the broker's own
    /// bundle identifier is used throughout so Atoll's permissions list shows
    /// only the broker, never the plugin.
    func makeDescriptor(qualifiedID: String, brokerBundleIdentifier: String) throws -> AtollLiveActivityDescriptor {
        guard let title, !title.isEmpty else { throw PluginMessageError.missingTitle }

        let accentColor: AtollColorDescriptor
        if let accentColorHex {
            guard let parsed = AtollColorDescriptor(hex: accentColorHex) else {
                throw PluginMessageError.invalidAccentColor(accentColorHex)
            }
            accentColor = parsed
        } else {
            accentColor = .accent
        }

        let resolvedPriority: AtollLiveActivityPriority
        if let priority {
            guard let parsed = AtollLiveActivityPriority(rawValue: priority) else {
                throw PluginMessageError.invalidPriority(priority)
            }
            resolvedPriority = parsed
        } else {
            resolvedPriority = .normal
        }

        let leadingIcon: AtollIconDescriptor = icon.map { .symbol(name: $0) } ?? .none

        return AtollLiveActivityDescriptor(
            id: qualifiedID,
            bundleIdentifier: brokerBundleIdentifier,
            priority: resolvedPriority,
            title: title,
            subtitle: subtitle,
            leadingIcon: leadingIcon,
            accentColor: accentColor
        )
    }
}

private extension AtollColorDescriptor {
    /// Parses "#RRGGBB" or "#RRGGBBAA" (case-insensitive, leading "#" optional).
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let intValue = UInt64(value, radix: 16) else { return nil }

        let hasAlpha = value.count == 8
        let r = Double((intValue >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((intValue >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((intValue >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(intValue & 0xFF) / 255 : 1.0

        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
