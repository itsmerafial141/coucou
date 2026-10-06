#if !APPSTORE
import AppKit
import Combine
import Foundation

// MARK: - Spotify Controller

/// Follows the Spotify app through its distributed notification and drives it with AppleScript.
/// Artwork comes from Spotify's CDN; synced lyrics from LRCLIB, only when the user turned lyrics on.
/// Singleton, @MainActor, GitHub build only.
@MainActor
final class SpotifyController: ObservableObject {
    static let shared = SpotifyController()
    static let pillId = "integration_spotify"
    static let bundleId = "com.spotify.client"
    static let colorHex = "#1DB954"

    @Published private(set) var trackTitle: String?
    @Published private(set) var artist: String?
    @Published private(set) var album: String?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var playing = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var shuffling = false
    @Published private(set) var repeating = false
    @Published private(set) var volume: Double = 50
    @Published private(set) var automationDenied = false
    @Published private(set) var lyrics: [LyricLine]?
    @Published var lyricsEnabled = UserDefaults.standard.bool(forKey: "coucou.spotifyLyrics") {
        didSet {
            UserDefaults.standard.set(lyricsEnabled, forKey: "coucou.spotifyLyrics")
            lyricsEnabled ? fetchLyrics() : (lyrics = nil)
        }
    }

    typealias LyricLine = LRCLine

    /// Position is interpolated from the last known one: no polling while playing.
    private var basePosition: Double = 0
    private var baseDate = Date()
    private var trackId: String?
    private var artworkURL: String?
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.spotify")

    var isPillActive: Bool { AppState.shared.activeIntegrations.contains(Self.pillId) }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) != nil }
    private var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleId }
    }

    func position(at date: Date = Date()) -> Double {
        let p = basePosition + (playing ? date.timeIntervalSince(baseDate) : 0)
        return duration > 0 ? min(p, duration) : p
    }

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] n in
            let info = n.userInfo
            let state = info?["Player State"] as? String
            let id = info?["Track ID"] as? String
            let pos = info?["Playback Position"] as? Double
            Task { @MainActor [weak self] in
                guard let self, self.isPillActive else { return }
                // A fresh read covers everything the notification lacks (artwork, shuffle, volume…).
                self.apply(playing: state == "Playing", position: pos)
                if id != self.trackId || state == "Stopped" { self.fetchAndApply() } else { self.syncTaskName() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard id == Self.bundleId else { return }
            Task { @MainActor [weak self] in self?.clearState() }
        }
        AppState.shared.$activeIntegrations
            .sink { [weak self] ids in
                guard let self else { return }
                if ids.contains(Self.pillId) { if self.isRunning { self.fetchAndApply() } } else { self.clearState() }
            }
            .store(in: &cancellables)
    }

    // MARK: - State

    private func apply(playing newPlaying: Bool, position: Double?) {
        let wasPlaying = playing
        basePosition = position ?? self.position()
        baseDate = Date()
        playing = newPlaying
        if newPlaying && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    private func fetchAndApply() {
        Task {
            let result = await run("""
                tell application id "com.spotify.client"
                    set ps to player state as string
                    if ps is "stopped" then return {ps, "", "", "", "0", "0", "", "false", "false", "50"}
                    set tr to current track
                    return {ps, name of tr, artist of tr, album of tr, (duration of tr) as string, ¬
                        (player position) as string, artwork url of tr, shuffling as string, ¬
                        repeating as string, (sound volume) as string, id of tr}
                end tell
            """)
            guard case .success(let v) = result, v.count >= 10 else { return }
            if v[0] == "stopped" { clearState(); return }
            let newTrack = v.count > 10 ? v[10] : v[1]
            trackTitle = v[1].isEmpty ? nil : v[1]
            artist = v[2].isEmpty ? nil : v[2]
            album = v[3].isEmpty ? nil : v[3]
            duration = (Double(v[4]) ?? 0) / 1000   // ms
            shuffling = v[7] == "true"
            repeating = v[8] == "true"
            volume = Double(v[9]) ?? volume
            apply(playing: v[0] == "playing", position: Double(v[5].replacingOccurrences(of: ",", with: ".")))
            if newTrack != trackId {
                trackId = newTrack
                loadArtwork(v[6])
                lyrics = nil
                if lyricsEnabled { fetchLyrics() }
            }
            syncTaskName()
        }
    }

    private func clearState() {
        trackTitle = nil; artist = nil; album = nil; artwork = nil; lyrics = nil
        trackId = nil; artworkURL = nil; duration = 0; basePosition = 0
        playing = false
        syncTaskName()
    }

    private func syncTaskName() {
        guard let i = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        AppState.shared.tasks[i].name = trackTitle ?? (PillCatalog.definition(for: Self.pillId)?.name ?? "Spotify")
    }

    // MARK: - Artwork & lyrics (network)

    private func loadArtwork(_ urlString: String) {
        guard urlString != artworkURL, let url = URL(string: urlString), url.scheme == "https" else { return }
        artworkURL = urlString
        artwork = nil
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  urlString == artworkURL else { return }
            artwork = NSImage(data: data)
        }
    }

    private func fetchLyrics() {
        guard let title = trackTitle, let artist else { return }
        // /api/search, not /api/get: get needs the duration within ±2 s and the exact album.
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        guard let url = c.url else { return }
        let requested = trackId
        let length = duration
        Task {
            var req = URLRequest(url: url)
            req.setValue("Coucou", forHTTPHeaderField: "User-Agent")
            let results = (try? await URLSession.shared.data(for: req))
                .flatMap { try? JSONSerialization.jsonObject(with: $0.0) as? [[String: Any]] } ?? []
            guard requested == trackId else { return }
            // Closest duration among the results that have synced lyrics (versions differ by a few s).
            let best = results
                .filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }
                .min { abs(($0["duration"] as? Double ?? 0) - length) < abs(($1["duration"] as? Double ?? 0) - length) }
            let close = best.map { length == 0 || abs(($0["duration"] as? Double ?? 0) - length) < 10 } ?? false
            lyrics = close ? LRCLine.parse(best?["syncedLyrics"] as? String ?? "") : []
        }
    }

    /// Index of the line being sung at `position`, nil before the first one.
    func currentLyricIndex(at position: Double) -> Int? {
        lyrics?.lastIndex { $0.time <= position + 0.3 }
    }

    // MARK: - Controls

    func playPause()     { command("playpause") }
    func nextTrack()     { command("next track") }
    func previousTrack() { command("previous track") }

    func seek(to seconds: Double) {
        basePosition = seconds; baseDate = Date()
        command("set player position to \(Int(seconds))")
    }

    func toggleShuffle() {
        shuffling.toggle()
        command("set shuffling to \(shuffling)")
    }

    func toggleRepeat() {
        repeating.toggle()
        command("set repeating to \(repeating)")
    }

    func setVolume(_ v: Double) {
        volume = v
        command("set sound volume to \(Int(v))")
    }

    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func command(_ cmd: String) {
        guard isRunning else { return }
        Task { await run(#"tell application id "com.spotify.client" to \#(cmd)"#) }
    }

    // MARK: - AppleScript runner

    enum ScriptResult { case success([String]), denied, error }

    @discardableResult
    private func run(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { cont in
            queue.async {
                var err: NSDictionary?
                let desc = NSAppleScript(source: source)!.executeAndReturnError(&err)
                if let err {
                    let denied = (err[NSAppleScript.errorNumber] as? Int) == -1743
                    Task { @MainActor in if denied { SpotifyController.shared.automationDenied = true } }
                    cont.resume(returning: denied ? .denied : .error)
                    return
                }
                Task { @MainActor in SpotifyController.shared.automationDenied = false }
                var values: [String] = []
                if desc.numberOfItems > 0 {
                    for i in 1...desc.numberOfItems { values.append(desc.atIndex(i)?.stringValue ?? "") }
                } else {
                    values = [desc.stringValue ?? ""]
                }
                cont.resume(returning: .success(values))
            }
        }
    }
}
#endif
