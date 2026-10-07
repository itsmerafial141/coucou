#if !APPSTORE
import SwiftUI

// MARK: - Shared bits

private let spotifyGreen = Color(hex: "#1DB954")   // SpotifyController.colorHex

/// True while a Spotify view is on screen and playing: the only time progress and lyrics tick.
@MainActor
private func spotifyTicking(_ state: AppState, _ spotify: SpotifyController) -> Bool {
    guard state.mode == .expanded, spotify.playing else { return false }
    return state.view == .spotify || (state.view == .overview && state.focusId == SpotifyController.pillId)
}

private func timeString(_ s: Double) -> String {
    let t = max(0, Int(s.rounded()))
    return String(format: "%d:%02d", t / 60, t % 60)
}

struct SpotifyCover: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(hex: "#1D1F23")
                    Image(systemName: "music.note").font(.system(size: size * 0.3)).foregroundColor(Color(hex: "#6B7079"))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 10 : 6))
    }
}

/// Progress bar that can be dragged to seek. Redraws only while `ticking`.
struct SpotifyProgressBar: View {
    @ObservedObject var spotify: SpotifyController
    let ticking: Bool
    var showTimes = false
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !ticking)) { tl in
            let fraction = dragFraction
                ?? (spotify.duration > 0 ? spotify.position(at: tl.date) / spotify.duration : 0)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: "#2A2D32"))
                        Capsule().fill(spotifyGreen).frame(width: geo.size.width * fraction)
                        Circle().fill(Color.white).frame(width: 9, height: 9)
                            .offset(x: geo.size.width * fraction - 4.5)
                            .opacity(dragFraction != nil ? 1 : 0.85)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = min(1, max(0, $0.location.x / geo.size.width)) }
                        .onEnded { _ in
                            if let f = dragFraction { spotify.seek(to: f * spotify.duration) }
                            dragFraction = nil
                        })
                }
                .frame(height: 10)
                if showTimes {
                    HStack {
                        Text(timeString(fraction * spotify.duration))
                        Spacer()
                        Text("-" + timeString(spotify.duration * (1 - fraction)))
                    }
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundColor(Color(hex: "#6B7079"))
                }
            }
        }
    }
}

private struct IconButton: View {
    let icon: String
    var size: CGFloat = 11
    var color = Color(hex: "#8E939C")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).foregroundColor(color)
                .frame(width: size + 10, height: size + 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Home card (focus on the Spotify pill)

struct SpotifyCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var spotify = SpotifyController.shared

    private func openPlayer() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .spotify }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if spotify.automationDenied {
                Text("Spotify").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text("Allow Coucou to control Spotify").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                Button("Open Settings…") { MusicController.shared.openAutomationSettings() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(spotifyGreen.opacity(0.85))
                    .buttonStyle(.plain)
            } else {
                // No artwork here — the cover belongs to the full player (SpotifyPlayerView).
                VStack(alignment: .leading, spacing: 1) {
                    Text(spotify.trackTitle ?? "Spotify")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1)
                    Text(spotify.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .lineLimit(1)
                    SpotifyProgressBar(spotify: spotify, ticking: spotifyTicking(state, spotify))
                        .padding(.top, 3)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: openPlayer)
                HStack(spacing: 6) {
                    IconButton(icon: "backward.fill") { spotify.previousTrack() }
                    IconButton(icon: spotify.playing ? "pause.fill" : "play.fill", size: 13, color: spotifyGreen) {
                        spotify.playPause()
                    }
                    IconButton(icon: "forward.fill") { spotify.nextTrack() }
                    Spacer()
                    IconButton(icon: "arrow.up.left.and.arrow.down.right", size: 10, action: openPlayer)
                }
            }
        }
        // Centered on Mochi, not on the card: the bot sits at y=54 in card coords
        // (101 in island coords, card top 47) while the 98pt card centers at 49 —
        // the 10pt top padding biases the centered content down by those 5pt.
        .padding(.top, 10)
        .padding(.leading, 108)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Full player (IslandView.spotify)

/// Mochi sits on the middle of the cover: the bot position for `.spotify` in IslandConst
/// matches `coverSize` and the paddings here.
struct SpotifyPlayerView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var spotify = SpotifyController.shared
    static let coverSize: CGFloat = 124

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            HStack(alignment: .top, spacing: 14) {
                SpotifyCover(image: spotify.artwork, size: Self.coverSize)
                controls
                lyricsColumn
            }
            .padding(10)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(spotify.trackTitle ?? "Nothing playing")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
                .lineLimit(1)
            Text([spotify.artist, spotify.album].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
            Spacer(minLength: 6)
            SpotifyProgressBar(spotify: spotify, ticking: spotifyTicking(state, spotify), showTimes: true)
            Spacer(minLength: 4)
            HStack {
                IconButton(icon: "shuffle", color: spotify.shuffling ? spotifyGreen : Color(hex: "#6B7079")) {
                    spotify.toggleShuffle()
                }
                Spacer()
                IconButton(icon: "backward.fill", size: 13) { spotify.previousTrack() }
                IconButton(icon: spotify.playing ? "pause.circle.fill" : "play.circle.fill", size: 24, color: spotifyGreen) {
                    spotify.playPause()
                }
                IconButton(icon: "forward.fill", size: 13) { spotify.nextTrack() }
                Spacer()
                IconButton(icon: "repeat", color: spotify.repeating ? spotifyGreen : Color(hex: "#6B7079")) {
                    spotify.toggleRepeat()
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.system(size: 9))
                Slider(value: Binding(get: { spotify.volume }, set: { spotify.setVolume($0) }), in: 0...100)
                    .controlSize(.mini)
                    .tint(Color(hex: "#8E939C"))
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 9))
            }
            .foregroundColor(Color(hex: "#6B7079"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lyricsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Lyrics").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#C5C8CD"))
                Spacer()
                Toggle("", isOn: $spotify.lyricsEnabled)
                    .toggleStyle(.switch).labelsHidden().scaleEffect(0.6).frame(width: 34, height: 16)
            }
            Group {
                if !spotify.lyricsEnabled {
                    hint("Turn on to fetch synced lyrics from LRCLIB (sends the title and artist).")
                } else if let lines = spotify.lyrics {
                    if lines.isEmpty { hint("No synced lyrics for this song.") } else { lyricLines(lines) }
                } else {
                    hint("Loading…")
                }
            }
            // minHeight 0 + clip: long (wrapped) lyrics must not grow the card past the cover,
            // which ate the island's bottom margin.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .center)
            .clipped()
            if spotify.lyricsEnabled {
                Text("LRCLIB").font(.system(size: 8.5)).foregroundColor(Color(hex: "#4A4E55"))
            }
        }
        .frame(width: 190)
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: "#26282D")).frame(width: 1) }
    }

    private func lyricLines(_ lines: [SpotifyController.LyricLine]) -> some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !spotifyTicking(state, spotify))) { tl in
            let current = spotify.currentLyricIndex(at: spotify.position(at: tl.date))
            let center = current ?? -1
            VStack(alignment: .leading, spacing: 5) {
                ForEach(max(0, center - 1)...min(lines.count - 1, max(0, center) + 2), id: \.self) { i in
                    Text(lines[i].text)
                        .font(.system(size: i == current ? 13 : 11.5, weight: i == current ? .semibold : .regular))
                        .foregroundColor(Color(hex: i == current ? "#F5F6F8" : "#6B7079"))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: current)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079"))
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
