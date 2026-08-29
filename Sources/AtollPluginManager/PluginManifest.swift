//
//  PluginManifest.swift
//  AtollPluginManager
//
//  Schema for a plugin's `plugin.json`, dropped into a subfolder of the
//  plugins directory. Passive discovery: the plugin launches and listens on
//  its own Unix socket; this manifest just tells the broker where to find it.
//

import Foundation

/// What kind of Atoll surface a plugin presents.
enum PluginCategory: String, Codable {
    case liveActivity
    /// A Now Playing / media source (registered over
    /// `atoll.registerMediaSource`, see `MediaPluginConnection`).
    case media
}

/// How the broker reaches the plugin. Only Unix domain sockets are
/// supported — decided over a shared TCP port to avoid port-collision and
/// firewall-prompt risk for macOS-only plugins.
enum PluginTransport: String, Codable {
    case unixSocket
}

struct PluginManifest: Codable, Equatable {
    let id: String
    let name: String
    let category: PluginCategory
    let transport: PluginTransport
    /// Path to the plugin's listening socket. Relative paths resolve against
    /// the manifest's own folder; absolute paths (leading "/") are used as-is.
    let socketPath: String
    /// Which version of the plugin<->broker wire protocol
    /// (PluginProtocolVersion.current) the plugin speaks. Defaults to 1 if
    /// omitted, since that was the only version before this field existed.
    let protocolVersion: Int
    /// `category == .media` config: whether the source can seek to an
    /// arbitrary position. Ignored for other categories. Defaults to true.
    let supportsSeek: Bool
    /// `category == .media` config: whether next/previous track navigation
    /// is available. Ignored for other categories. Defaults to true.
    let supportsSkip: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, category, transport, socketPath, protocolVersion, supportsSeek, supportsSkip
    }

    init(
        id: String,
        name: String,
        category: PluginCategory,
        transport: PluginTransport,
        socketPath: String,
        protocolVersion: Int = PluginProtocolVersion.current,
        supportsSeek: Bool = true,
        supportsSkip: Bool = true
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.transport = transport
        self.socketPath = socketPath
        self.protocolVersion = protocolVersion
        self.supportsSeek = supportsSeek
        self.supportsSkip = supportsSkip
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decode(PluginCategory.self, forKey: .category)
        transport = try container.decode(PluginTransport.self, forKey: .transport)
        socketPath = try container.decode(String.self, forKey: .socketPath)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        supportsSeek = try container.decodeIfPresent(Bool.self, forKey: .supportsSeek) ?? true
        supportsSkip = try container.decodeIfPresent(Bool.self, forKey: .supportsSkip) ?? true
    }

    /// Structural validation beyond what decoding already guarantees (decoding
    /// already rejects unknown `category`/`transport` values and missing keys).
    var validationError: String? {
        if id.trimmingCharacters(in: .whitespaces).isEmpty { return "\"id\" is empty" }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "\"name\" is empty" }
        if socketPath.trimmingCharacters(in: .whitespaces).isEmpty { return "\"socketPath\" is empty" }
        if !PluginProtocolVersion.supported.contains(protocolVersion) {
            return "protocolVersion \(protocolVersion) is not supported by this broker (supports \(PluginProtocolVersion.supported))"
        }
        return nil
    }

    /// Resolves `socketPath` against the manifest's containing folder.
    func resolvedSocketURL(relativeTo folderURL: URL) -> URL {
        socketPath.hasPrefix("/") ? URL(fileURLWithPath: socketPath) : folderURL.appendingPathComponent(socketPath)
    }
}
