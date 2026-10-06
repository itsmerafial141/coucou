#if !APPSTORE
import SwiftUI
import UniformTypeIdentifiers

private let blurple = Color(hex: "#5865F2")
private let blurpleSoft = Color(hex: "#C9CEFF")

private func clock(_ since: Date?, now: Date) -> String {
    guard let since else { return "" }
    let t = Int(now.timeIntervalSince(since))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

private func timeOf(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM"
    return f.string(from: d)
}

private struct Avatar: View {
    let url: URL?
    var size: CGFloat = 20
    var ring = false

    var body: some View {
        AsyncImage(url: url) { img in img.resizable() } placeholder: { Color(hex: "#3A3D44") }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(hex: "#22C55E"), lineWidth: ring ? 2 : 0))
    }
}

private struct ExpandButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                .frame(width: 20, height: 20)
                .background(Color(hex: "#1D1F23"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Details")
    }
}

/// Three bars that bounce while the mic is live and lie flat when muted.
private struct VoiceBars: View {
    let live: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !live)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(Color(hex: live ? "#22C55E" : "#4A4E55"))
                        .frame(width: 2, height: live ? 3 + 7 * abs(sin(t * 4 + Double(i) * 0.9)) : 3)
                }
            }
            .frame(height: 10, alignment: .bottom)
        }
    }
}

// MARK: - Home card (focus on the Discord pill)

struct DiscordCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var discord = DiscordService.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let me = discord.myVoice {
                voiceCard(me)
            } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Discord").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                    if let n = discord.unread, n > 0 {
                        Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 5).background(Color(hex: "#F4505E")).clipShape(Capsule())
                    }
                }
                Text(unreadLine).font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                if let me = discord.myVoice {
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        Text("🔊 \(discord.channel(me.channelId)?.name ?? "Voice") · \(discord.occupiedVoice.first { $0.channel.id == me.channelId }?.members.count ?? 1) orang · \(clock(discord.voiceSince, now: tl.date))")
                            .font(.system(size: 11)).foregroundColor(Color(hex: "#22C55E")).lineLimit(1)
                    }
                } else if let m = discord.mentions.first {
                    Text("\(m.author): \(m.content)").font(.system(size: 11)).foregroundColor(blurpleSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Open Discord") { discord.openDiscord() }
                    .font(.system(size: 11, weight: .medium)).foregroundColor(blurple).buttonStyle(.plain)
            }
            .padding(.top, 9).padding(.bottom, 8)
            .padding(.leading, 108).padding(.trailing, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            ExpandButton {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .discord }
            }
            .padding(.top, 8).padding(.trailing, 10)
        }
    }

    /// In a voice channel: channel, people, time, and the mute toggle (Mochi mirrors the state).
    private func voiceCard(_ me: DiscordService.VoiceMember) -> some View {
        let count = discord.occupiedVoice.first { $0.channel.id == me.channelId }?.members.count ?? 1
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                VoiceBars(live: !me.muted).fixedSize()
                Text("🔊 \(discord.channel(me.channelId)?.name ?? "Voice")")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1).truncationMode(.tail)
            }
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                Text("\(count) orang · \(clock(discord.voiceSince, now: tl.date))" + (me.muted ? " · muted" : ""))
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                // Icon only: the card is narrow next to Mochi.
                Button { discord.toggleMute() } label: {
                    Image(systemName: me.muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: me.muted ? "#FCA5A5" : "#86EFAC"))
                        .frame(width: 28, height: 28)
                        .background(Color(hex: me.muted ? "#F4505E" : "#22C55E").opacity(me.muted ? 0.2 : 0.16))
                        .overlay(Circle().stroke(Color(hex: me.muted ? "#F4505E" : "#22C55E").opacity(0.55)))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(me.muted ? "Unmute (⌘⇧M in Discord)" : "Mute (⌘⇧M in Discord)")
                Button("Buka Discord") { discord.openDiscord() }
                    .font(.system(size: 11, weight: .medium)).foregroundColor(blurple).buttonStyle(.plain)
            }
        }
        .padding(.top, 9).padding(.bottom, 9)
        .padding(.leading, 108).padding(.trailing, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var unreadLine: String {
        guard let n = discord.unread else { return "Discord tidak berjalan" }
        return n == 0 ? "Tidak ada pesan belum dibaca" : "\(n) belum dibaca"
    }
}

// MARK: - Full view (IslandView.discord)

/// Mochi sits in the left gutter: the `.discord` layout in IslandConst matches the 116pt inset.
struct DiscordFullView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var discord = DiscordService.shared
    @State private var draft = ""
    @State private var attachment: URL?
    @State private var sending = false
    @State private var sendError = false

    private var tabs: [(id: String, label: String)] {
        var t = discord.selectedChannels.map { ($0, "# " + (discord.channel($0)?.name ?? "…")) }
        if !discord.mentions.isEmpty { t.append(("mentions", "@ Mentions")) }
        t.append(("voice", "🔊 Voice" + (discord.occupiedVoice.isEmpty ? "" : " · \(discord.occupiedVoice.count)")))
        return t
    }

    private var current: String { discord.selectedTab.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first!.id }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 6) {
                tabBar
                Group {
                    if !discord.hasToken || discord.connection != .connected {
                        status
                    } else if current == "voice" {
                        voiceList
                    } else {
                        messageList(current == "mentions" ? discord.mentions.reversed() : discord.messages[current] ?? [])
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if current != "voice" && current != "mentions" && discord.connection == .connected { composer }
            }
            .padding(.leading, 116).padding(.trailing, 14).padding(.vertical, 10)
        }
        .onChange(of: state.view) { _, v in
            if v != .discord { discord.highlightedMessage = nil }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.id) { tab in
                    Button { discord.selectedTab = tab.id } label: {
                        Text(tab.label).font(.system(size: 11))
                            .foregroundColor(current == tab.id ? blurpleSoft : Color(hex: "#8E939C"))
                            .padding(.horizontal, 9).padding(.vertical, 2)
                            .background(current == tab.id ? blurple.opacity(0.25) : Color(hex: "#1D1F23"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        let text: String = {
            if !discord.hasToken { return "Token bot Space Assistant tidak ditemukan di Keychain." }
            if discord.selectedChannels.isEmpty && discord.connection == .connected { return "Pilih channel di Settings → Integrations → Discord." }
            switch discord.connection {
            case .off, .connecting: return "Menghubungkan ke Discord…"
            case .failed(let e): return "Tidak tersambung: \(e)"
            case .connected: return ""
            }
        }()
        Text(text).font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C"))
    }

    private func messageList(_ list: [DiscordService.Message]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    if list.isEmpty {
                        Text(discord.selectedChannels.isEmpty ? "Pilih channel di Settings → Integrations → Discord." : "Belum ada pesan.")
                            .font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079"))
                    }
                    ForEach(list) { m in
                        Button { discord.open(m) } label: { messageRow(m) }
                            .buttonStyle(.plain)
                            .id(m.id)
                    }
                }
            }
            .onAppear { scroll(proxy, list) }
            .onChange(of: list.last?.id) { _, _ in scroll(proxy, list) }
            .onChange(of: discord.highlightedMessage) { _, _ in scroll(proxy, list) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, _ list: [DiscordService.Message]) {
        let target = discord.highlightedMessage.flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list.last?.id
        if let target { proxy.scrollTo(target, anchor: .bottom) }
    }

    private func messageRow(_ m: DiscordService.Message) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(url: m.avatar)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(m.author).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                    Text(timeOf(m.date)).font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
                    if current == "mentions", let c = discord.channel(m.channelId) {
                        Text("#\(c.name)").font(.system(size: 9.5)).foregroundColor(blurpleSoft)
                    }
                }
                Text(m.content).font(.system(size: 11.5)).foregroundColor(Color(hex: "#C5C8CD")).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, m.mentionsMe ? 3 : 0).padding(.horizontal, m.mentionsMe ? 6 : 0)
        .background(m.mentionsMe ? Color(hex: "#F5A524").opacity(m.id == discord.highlightedMessage ? 0.18 : 0.09) : .clear)
        .overlay(alignment: .leading) {
            if m.mentionsMe { Rectangle().fill(Color(hex: "#F5A524")).frame(width: 2) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }

    private var voiceList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 5) {
                if discord.occupiedVoice.isEmpty {
                    Text("Tidak ada yang di voice.").font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079"))
                }
                ForEach(discord.occupiedVoice, id: \.channel.id) { group in
                    HStack(spacing: 6) {
                        Text("🔊 \(group.channel.name)").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Color(hex: "#C5C8CD"))
                        Spacer()
                        if group.members.contains(where: { $0.id == discord.userId }) {
                            TimelineView(.periodic(from: .now, by: 1)) { tl in
                                Text(clock(discord.voiceSince, now: tl.date)).font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(Color(hex: "#22C55E"))
                            }
                        }
                        Button("Join") { discord.open(group.channel) }
                            .font(.system(size: 10.5, weight: .medium)).foregroundColor(blurple).buttonStyle(.plain)
                    }
                    ForEach(group.members) { member in
                        HStack(spacing: 6) {
                            Avatar(url: member.avatar, size: 16, ring: member.id == discord.userId)
                            Text(member.id == discord.userId ? "\(member.name) (Anda)" : member.name)
                                .font(.system(size: 11)).foregroundColor(Color(hex: member.id == discord.userId ? "#F5F6F8" : "#8E939C"))
                            if member.muted { Image(systemName: "mic.slash.fill").font(.system(size: 9)).foregroundColor(Color(hex: "#6B7079")) }
                            if member.deafened { Image(systemName: "speaker.slash.fill").font(.system(size: 9)).foregroundColor(Color(hex: "#6B7079")) }
                            if member.live {
                                Text("LIVE").font(.system(size: 8.5, weight: .bold)).foregroundColor(.white)
                                    .padding(.horizontal, 4).background(Color(hex: "#F4505E")).clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            // No user ID yet: pick yourself from the people in voice.
                            if discord.userId.isEmpty {
                                Button("Ini saya") { discord.userId = member.id }
                                    .font(.system(size: 10, weight: .medium)).foregroundColor(blurple).buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 16)
                    }
                }
            }
        }
    }

    /// Text and/or one file; drop a file on it or pick one. Sent as the bot, only on click.
    private var composer: some View {
        HStack(spacing: 6) {
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                if panel.runModal() == .OK { attachment = panel.url }
            } label: {
                Image(systemName: attachment == nil ? "paperclip" : "doc.fill")
                    .font(.system(size: 11)).foregroundColor(attachment == nil ? Color(hex: "#8E939C") : blurpleSoft)
            }
            .buttonStyle(.plain)
            .help(attachment?.lastPathComponent ?? "Attach a file")
            if let a = attachment {
                Text(a.lastPathComponent).font(.system(size: 10.5)).foregroundColor(blurpleSoft).lineLimit(1).frame(maxWidth: 110)
                Button { attachment = nil } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                    .buttonStyle(.plain).foregroundColor(Color(hex: "#6B7079"))
            }
            TextField("Pesan ke #\(discord.channel(current)?.name ?? "…") (sebagai bot)", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(hex: "#0E0F11"))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: sendError ? "#F4505E" : "#2A2C31")))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .onSubmit(sendNow)
            Button(sending ? "…" : "Kirim", action: sendNow)
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(blurple.opacity(draft.isEmpty && attachment == nil ? 0.4 : 1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .buttonStyle(.plain)
                .disabled(sending || (draft.isEmpty && attachment == nil))
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { attachment = url } }
            }
            return true
        }
    }

    private func sendNow() {
        guard !sending, !(draft.isEmpty && attachment == nil) else { return }
        let channel = current, text = draft, file = attachment
        sending = true; sendError = false
        Task {
            let ok = await discord.post(text, file: file, to: channel)
            sending = false
            if ok { draft = ""; attachment = nil; SoundEngine.shared.play("pop") } else { sendError = true }
        }
    }
}

// MARK: - Settings → Integrations → Discord

struct DiscordSettingsSection: View {
    @ObservedObject private var discord = DiscordService.shared

    var body: some View {
        GroupBox("Discord") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    Text(statusText).font(.system(size: 12))
                }
                TextField("Username Discord (mis. rafial141) atau User ID", text: $discord.userId)
                    .textFieldStyle(.roundedBorder)
                Text("Channel untuk feed dan kirim cepat (maks \(DiscordService.maxChannels)). Pesan dikirim sebagai bot Space Assistant.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                let text = discord.channels.filter { !$0.isVoice }
                if text.isEmpty {
                    Text(discord.isPillActive ? "Daftar channel muncul setelah bot tersambung." : "Aktifkan pill Discord untuk memuat channel.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
                            ForEach(text) { c in
                                Toggle("#\(c.name)", isOn: Binding(
                                    get: { discord.selectedChannels.contains(c.id) },
                                    set: { on in
                                        if on, discord.selectedChannels.count < DiscordService.maxChannels {
                                            discord.selectedChannels.append(c.id)
                                        } else if !on {
                                            discord.selectedChannels.removeAll { $0 == c.id }
                                        }
                                    }))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11.5))
                                .disabled(!discord.selectedChannels.contains(c.id) && discord.selectedChannels.count >= DiscordService.maxChannels)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
            .padding(6)
        }
    }

    private var dotColor: Color {
        switch discord.connection {
        case .connected: return Color(hex: "#22C55E")
        case .connecting: return Color(hex: "#F5A524")
        case .off: return Color(hex: "#6B7079")
        case .failed: return Color(hex: "#F4505E")
        }
    }

    private var statusText: String {
        if !discord.hasToken { return "Token bot Space Assistant tidak ada di Keychain" }
        switch discord.connection {
        case .connected: return "Tersambung sebagai bot Space Assistant"
        case .connecting: return "Menghubungkan…"
        case .off: return "Aktifkan pill Discord di Active pills"
        case .failed(let e): return "Gagal: \(e)"
        }
    }
}
#endif
