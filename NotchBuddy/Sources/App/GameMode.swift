import SwiftUI

#if !APPSTORE  // ponytail: runs Xcode's gamepolicyctl, which the sandboxed App Store build can't

/// macOS Game Mode: forces it on for games macOS doesn't recognise (Wine/Bridgeplay windows aren't
/// "games" and aren't native fullscreen, so the automatic policy never kicks in). Uses Xcode's
/// `gamepolicyctl` (no root needed). Forcing it on outlives Coucou, so "off" means back to automatic.
@MainActor
final class GameMode: ObservableObject {
    static let shared = GameMode()

    @Published private(set) var forced = false   // policy is "on"
    @Published private(set) var active = false   // Game Mode currently running (forced or automatic)
    @Published private(set) var available = true // gamepolicyctl found (needs Xcode)

    func refresh() async {
        guard let out = await Self.ctl("status") else { available = false; return }
        available = true
        forced = out.contains("forced always on")
        active = out.contains("Game mode is on")
    }

    func setForced(_ on: Bool) async {
        _ = await Self.ctl("set", on ? "on" : "auto")
        await refresh()
    }

    /// Output of `xcrun gamepolicyctl game-mode <args>` without colour codes, nil if it failed.
    nonisolated static func ctl(_ args: String...) async -> String? {
        await Task.detached {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["gamepolicyctl", "game-mode"] + args
            p.standardOutput = pipe
            p.standardError = pipe
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        }.value
    }
}

// MARK: - Island tab

struct GameModeView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var game = GameMode.shared

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Game Mode")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Spacer(minLength: 4)
                    Text(game.active ? "Active" : "Off")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: game.active ? "#7EE0A1" : "#8E939C"))
                    Toggle("", isOn: Binding(get: { game.forced }, set: { on in Task { await game.setForced(on) } }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.7)
                        .frame(width: 40)
                        .disabled(!game.available)
                }
                hint(game.available
                     ? "Gives the game top CPU/GPU priority and slows background tasks. Stays on after you quit the game, turn it off when you're done."
                     : "Needs Xcode: gamepolicyctl wasn't found.")
                if game.forced == false && game.active {
                    hint("On automatically: a fullscreen game is running.")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
        }
        // ponytail: polls only while the tab is visible (the task ends when it disappears).
        .task {
            while !Task.isCancelled {
                await game.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(Color(hex: "#8E939C"))
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
