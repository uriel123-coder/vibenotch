import AppKit

/// Now playing for Spotify and Apple Music, from their public distributed notifications (no permission needed).
/// Playback controls use AppleScript, so macOS asks once for Automation access.
@MainActor
final class MusicStore: ObservableObject {
    static let shared = MusicStore()

    enum Player: String {
        case spotify = "Spotify"
        case music = "Music"

        var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
        var displayName: String { self == .spotify ? "Spotify" : "Música" }
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var playing: Bool
        var player: Player
        var artwork: URL?
    }

    @Published private(set) var track: Track?

    var isPlaying: Bool { track?.playing == true }

    func demo(_ t: Track) { track = t }

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { n in
            let info = n.userInfo as? [String: Any] ?? [:]
            MainActor.assumeIsolated { MusicStore.shared.update(.spotify, info) }
        }
        center.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { n in
            let info = n.userInfo as? [String: Any] ?? [:]
            MainActor.assumeIsolated { MusicStore.shared.update(.music, info) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if let t = MusicStore.shared.track, t.player.bundleID == id { MusicStore.shared.track = nil }
            }
        }
    }

    private func update(_ player: Player, _ info: [String: Any]) {
        let state = info["Player State"] as? String ?? ""
        guard state != "Stopped", let title = info["Name"] as? String else {
            if track?.player == player { track = nil }
            return
        }
        let previous = track
        var new = Track(title: title, artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "",
                        playing: state == "Playing", player: player, artwork: nil)
        if previous?.title == new.title && previous?.player == player { new.artwork = previous?.artwork }
        track = new
        if player == .spotify, new.artwork == nil, let id = info["Track ID"] as? String { fetchSpotifyArtwork(id, title: title) }
    }

    private func fetchSpotifyArtwork(_ trackID: String, title: String) {
        let path = trackID.replacingOccurrences(of: "spotify:track:", with: "")
        guard !path.contains(":"),
              let url = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/track/\(path)") else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumb = (j["thumbnail_url"] as? String).flatMap(URL.init(string:)) else { return }
            if MusicStore.shared.track?.title == title { MusicStore.shared.track?.artwork = thumb }
        }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send(track?.player == .music ? "back track" : "previous track") }

    func openPlayer() {
        guard let player = track?.player else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first?.activate()
    }

    private func send(_ command: String) {
        guard let player = track?.player,
              !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application id \"\(player.bundleID)\" to \(command)")?.executeAndReturnError(&error)
        if command == "playpause" { track?.playing.toggle() }
    }
}
