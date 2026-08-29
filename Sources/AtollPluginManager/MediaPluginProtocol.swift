//
//  MediaPluginProtocol.swift
//  AtollPluginManager
//
//  Local wire protocol for category == .media plugins: newline-delimited
//  JSON, one message per line, same shape as the live-activity protocol
//  (PluginProtocol.swift) but for Now Playing state. The plugin's manifest
//  id/name/supportsSeek/supportsSkip double as the source's registration
//  config, so there's no separate "register" message — a connection existing
//  at all means the source is live.
//

import Foundation

/// One line of the plugin -> broker protocol.
struct MediaNowPlayingMessage: Codable {
    var title: String
    var artist: String?
    var album: String?
    /// Base64-encoded artwork image data (PNG/JPEG), if any.
    var artworkBase64: String?
    var isPlaying: Bool
    var elapsedTime: TimeInterval
    var duration: TimeInterval?
    /// nil = the plugin doesn't report shuffle/repeat state.
    var isShuffled: Bool?
    /// "off" / "one" / "all"; nil carries the same "unknown" meaning as
    /// `isShuffled`.
    var repeatMode: String?
}

enum MediaPluginMessageError: Error, LocalizedError {
    case missingTitle

    var errorDescription: String? {
        switch self {
        case .missingTitle: return "\"title\" is required"
        }
    }
}

/// One line of the broker -> plugin protocol: a playback command in
/// response to user interaction (notch controls, media keys).
struct MediaCommandMessage: Codable {
    let type: String
    var command: String
    var seekTo: TimeInterval?

    init(command: AtollMediaCommand) {
        self.type = "mediaCommand"
        switch command {
        case .play: self.command = "play"
        case .pause: self.command = "pause"
        case .togglePlayPause: self.command = "togglePlayPause"
        case .nextTrack: self.command = "nextTrack"
        case .previousTrack: self.command = "previousTrack"
        case .seek(let position):
            self.command = "seek"
            self.seekTo = position
        case .toggleShuffle: self.command = "toggleShuffle"
        case .toggleRepeat: self.command = "toggleRepeat"
        }
    }
}
