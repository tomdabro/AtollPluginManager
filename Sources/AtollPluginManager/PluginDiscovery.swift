//
//  PluginDiscovery.swift
//  AtollPluginManager
//
//  Scans ~/Library/Application Support/AtollPluginManager/Plugins/ for
//  subfolders containing a plugin.json, and re-scans on any change to that
//  directory. Passive: this never launches anything, it just finds manifests
//  for already-running (or about-to-run) plugins to connect out to.
//

import Foundation

/// A manifest paired with the folder it was found in (needed to resolve a
/// relative `socketPath`).
struct DiscoveredPlugin: Equatable {
    let manifest: PluginManifest
    let folderURL: URL

    var socketURL: URL { manifest.resolvedSocketURL(relativeTo: folderURL) }
}

@MainActor
final class PluginDiscovery: ObservableObject {
    @Published private(set) var plugins: [String: DiscoveredPlugin] = [:]
    /// Human-readable rejection reasons, keyed by the offending folder name,
    /// for a future Settings UI (Phase 5) to surface instead of only logging.
    @Published private(set) var rejectedManifests: [String: String] = [:]

    private let pluginsDirectory: URL
    private var watchSource: DispatchSourceFileSystemObject?

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, one of which is the
    /// null terminator. Network.framework traps rather than returning an
    /// error when a path doesn't fit, so this has to be checked up front —
    /// discovered the hard way while writing the integration tests for this
    /// exact code path.
    static let maxUnixSocketPathBytes = 103

    nonisolated static let defaultPluginsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("AtollPluginManager", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }()

    init(pluginsDirectory: URL = PluginDiscovery.defaultPluginsDirectory) {
        self.pluginsDirectory = pluginsDirectory
    }

    func start() {
        try? FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        rescan()
        watchDirectory()
    }

    func stop() {
        watchSource?.cancel()
        watchSource = nil
    }

    func rescan() {
        var found: [String: DiscoveredPlugin] = [:]
        var rejected: [String: String] = [:]

        let folders = (try? FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let folderName = folder.lastPathComponent
            let manifestURL = folder.appendingPathComponent("plugin.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }

            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
                if let reason = manifest.validationError {
                    rejected[folderName] = reason
                    continue
                }
                let discovered = DiscoveredPlugin(manifest: manifest, folderURL: folder)
                let socketPathByteCount = discovered.socketURL.path.utf8.count
                guard socketPathByteCount < Self.maxUnixSocketPathBytes else {
                    rejected[folderName] = "resolved socket path is \(socketPathByteCount) bytes, exceeds the \(Self.maxUnixSocketPathBytes)-byte Unix domain socket limit (sockaddr_un.sun_path) — use a shorter socketPath, ideally an absolute path outside Application Support"
                    continue
                }
                if let existing = found[manifest.id] {
                    rejected[folderName] = "duplicate plugin id \"\(manifest.id)\" (already used by \(existing.folderURL.lastPathComponent))"
                    continue
                }
                found[manifest.id] = discovered
            } catch {
                rejected[folderName] = error.localizedDescription
            }
        }

        plugins = found
        rejectedManifests = rejected
    }

    /// Watches the plugins directory itself (not each plugin subfolder) for
    /// writes/renames and re-scans on any change. Coarse but simple: adding,
    /// removing, or editing any manifest triggers a full rescan.
    private func watchDirectory() {
        let fd = open(pluginsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.rescan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
    }
}
