#if !APPSTORE
import AppKit
import ApplicationServices
import Combine
import Foundation
import Security
import os

// MARK: - Discord Service

/// Discord pill. Two sources:
/// - the unread badge of Discord's Dock tile, read through Accessibility (no token);
/// - a Gateway connection with the Space Assistant bot token (Keychain, owned by Venturo Bot):
///   messages of the chosen channels, mentions of the user, and who sits in which voice channel.
/// The bot can't see DMs or the user's own unread state, and never posts as the user.
/// Lives only while the pill is active. GitHub build only.
@MainActor
final class DiscordService: ObservableObject {
    static let shared = DiscordService()
    static let pillId = "integration_discord"
    static let bundleId = "com.hnc.Discord"
    static let maxChannels = 3

    enum Connection: Equatable { case off, connecting, connected, failed(String) }

    struct Channel: Identifiable, Hashable { let id: String; let guildId: String; let name: String; let isVoice: Bool }

    struct Message: Identifiable, Equatable {
        let id: String
        let channelId: String
        let guildId: String
        let author: String
        let avatar: URL?
        let content: String
        let date: Date
        let mentionsMe: Bool
    }

    struct VoiceMember: Identifiable, Equatable {
        let id: String           // user id
        var name: String
        var username: String?
        var avatar: URL?
        var channelId: String
        var guildId: String
        var muted: Bool
        var deafened: Bool
        var live: Bool
    }

    @Published private(set) var unread: Int?
    @Published private(set) var connection: Connection = .off
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var messages: [String: [Message]] = [:]
    @Published private(set) var mentions: [Message] = []
    @Published private(set) var voice: [String: VoiceMember] = [:]   // by user id
    @Published private(set) var voiceSince: Date?
    @Published var highlightedMessage: String?
    @Published var selectedTab: String?                               // channel id, "mentions" or "voice"

    @Published var userId: String = UserDefaults.standard.string(forKey: "discord.userId") ?? "" {
        didSet {
            UserDefaults.standard.set(userId.trimmingCharacters(in: .whitespaces), forKey: "discord.userId")
            refreshMyVoice()
        }
    }
    @Published var selectedChannels: [String] = UserDefaults.standard.stringArray(forKey: "discord.channels") ?? [] {
        didSet {
            UserDefaults.standard.set(selectedChannels, forKey: "discord.channels")
            loadHistory()
        }
    }

    var isPillActive: Bool { AppState.shared.activeIntegrations.contains(Self.pillId) }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) != nil }
    /// Never reads the Keychain itself (views render before the pill is on): set by connect().
    var hasToken: Bool { !tokenMissing }
    @Published private(set) var tokenMissing = false
    var myVoice: VoiceMember? { voice[userId] }
    func channel(_ id: String) -> Channel? { channels.first { $0.id == id } }
    /// Voice channels with people in them, with their members.
    var occupiedVoice: [(channel: Channel, members: [VoiceMember])] {
        Dictionary(grouping: voice.values, by: \.channelId)
            .compactMap { id, members in channel(id).map { ($0, members.sorted { $0.name < $1.name }) } }
            .sorted { $0.channel.name < $1.channel.name }
    }

    private var token: String?
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var sequence: Int?
    private var retry = 0
    private var badgeTimer: Timer?
    private var lastBadgeAlert = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    private init() {
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] on in on ? self?.start() : self?.stop() }
            .store(in: &cancellables)
        // Reading Discord's messages in the app usually clears the badge: refresh when it loses focus.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard id == Self.bundleId else { return }
            Task { @MainActor in self?.readBadge() }
        }
    }

    private func start() {
        readBadge()
        // ponytail: the Dock posts no event when a badge changes, so it is read every 20 s while
        // the pill is on (one AX call). Gateway messages also refresh it right away.
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readBadge() }
        }
        connect()
    }

    private func stop() {
        badgeTimer?.invalidate(); badgeTimer = nil
        disconnect()
        unread = nil
        AppState.shared.voiceOutfit = nil
    }

    // MARK: - Dock badge (Accessibility, no token)

    func readBadge() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        let ax = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        var count: Int? = nil
        for list in Self.attr(ax, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            for item in Self.attr(list, kAXChildrenAttribute) as? [AXUIElement] ?? []
            where (Self.attr(item, kAXTitleAttribute) as? String) == "Discord" {
                let label = Self.attr(item, "AXStatusLabel") as? String
                count = label.map { Int($0) ?? 1 } ?? 0   // "•" or "99+" style labels still mean unread
            }
        }
        let previous = unread
        unread = count
        syncTask()
        // Badge went up (not on the first read) and no Gateway mention just showed it: reveal quietly.
        if let previous, let count, count > previous, Date().timeIntervalSince(lastBadgeAlert) > 10 {
            lastBadgeAlert = Date()
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
    }

    // MARK: - Gateway

    private static let intents = 1 | 1 << 7 | 1 << 9 | 1 << 15   // guilds, voice states, guild messages, message content

    private func connect() {
        guard isPillActive, socket == nil else { return }
        if token == nil {   // macOS asks once before sharing Venturo Bot's item
            let r = Self.readToken()
            token = r.token
            discordLog("keychain status \(r.status) token \(r.token == nil ? "nil" : "ok")")
            if token == nil {
                tokenMissing = true
                connection = .failed(r.status == errSecItemNotFound ? "Token tidak ada di Keychain"
                                     : "Akses Keychain ditolak (\(r.status))")
                return
            }
        }
        tokenMissing = false
        connection = .connecting
        var req = URLRequest(url: URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!)
        req.setValue("DiscordBot (coucou, 1.0)", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.webSocketTask(with: req)
        task.maximumMessageSize = 32 * 1024 * 1024   // GUILD_CREATE can be large
        socket = task
        task.resume()
        receive(on: task)
    }

    private func disconnect() {
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        sequence = nil
        connection = .off
        voice = [:]
        voiceSince = nil
    }

    private func reconnectLater() {
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(); socket = nil
        guard isPillActive else { return }
        retry += 1
        let delay = [2.0, 5, 15, 60][min(retry - 1, 3)]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.socket else { return }
                switch result {
                case .failure(let error):
                    discordLog("gateway error \(error.localizedDescription) close \(task.closeCode.rawValue)")
                    self.connection = .failed(error.localizedDescription)
                    self.reconnectLater()
                case .success(let message):
                    let data: Data? = switch message {
                    case .string(let s): s.data(using: .utf8)
                    case .data(let d): d
                    @unknown default: nil
                    }
                    if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(json)
                    }
                    self.receive(on: task)
                }
            }
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func handle(_ p: [String: Any]) {
        if let s = p["s"] as? Int { sequence = s }
        switch p["op"] as? Int {
        case 10:   // HELLO
            let interval = ((p["d"] as? [String: Any])?["heartbeat_interval"] as? Double ?? 41_250) / 1000
            heartbeat?.cancel()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard let self else { return }
                    self.send(["op": 1, "d": self.sequence as Any])
                }
            }
            send(["op": 2, "d": ["token": token ?? "", "intents": Self.intents,
                                 "properties": ["os": "macos", "browser": "coucou", "device": "coucou"]]])
        case 7, 9:  // RECONNECT, INVALID_SESSION
            discordLog("gateway op \(p["op"] ?? "")")
            reconnectLater()
        case 0:
            dispatch(p["t"] as? String ?? "", p["d"] as? [String: Any] ?? [:])
        default:
            break
        }
    }

    private func dispatch(_ type: String, _ d: [String: Any]) {
        switch type {
        case "READY":
            discordLog("gateway READY")
            connection = .connected
            retry = 0
        case "GUILD_CREATE":
            let guild = d["id"] as? String ?? ""
            let found = (d["channels"] as? [[String: Any]] ?? []).compactMap { c -> Channel? in
                guard let id = c["id"] as? String, let name = c["name"] as? String, let t = c["type"] as? Int,
                      [0, 2, 5, 13].contains(t) else { return nil }   // text, voice, news, stage
                return Channel(id: id, guildId: guild, name: name, isVoice: t == 2 || t == 13)
            }
            channels = (channels.filter { $0.guildId != guild } + found).sorted { $0.name < $1.name }
            let names = Dictionary((d["members"] as? [[String: Any]] ?? []).compactMap { m -> (String, [String: Any])? in
                guard let u = m["user"] as? [String: Any], let id = u["id"] as? String else { return nil }
                return (id, m)
            }, uniquingKeysWith: { a, _ in a })
            for vs in d["voice_states"] as? [[String: Any]] ?? [] {
                var state = vs; state["guild_id"] = guild
                if state["member"] == nil, let id = vs["user_id"] as? String { state["member"] = names[id] }
                updateVoice(state)
            }
            discordLog("guild \(guild): \(found.count) channels, \((d["voice_states"] as? [Any])?.count ?? 0) in voice")
            loadHistory()
        case "VOICE_STATE_UPDATE":
            updateVoice(d)
        case "MESSAGE_CREATE":
            guard let m = message(d) else { return }
            if selectedChannels.contains(m.channelId) {
                messages[m.channelId, default: []].append(m)
                messages[m.channelId] = Array(messages[m.channelId]!.suffix(20))
            }
            if m.mentionsMe { announceMention(m) }
            readBadge()
        default:
            break
        }
    }

    private func updateVoice(_ d: [String: Any]) {
        guard let userId = d["user_id"] as? String else { return }
        resolveUsername()
        let wasInVoice = myVoice != nil
        if let channelId = d["channel_id"] as? String {
            let member = d["member"] as? [String: Any]
            let user = member?["user"] as? [String: Any]
            let name = (member?["nick"] as? String) ?? (user?["global_name"] as? String)
                ?? (user?["username"] as? String) ?? voice[userId]?.name ?? "…"
            voice[userId] = VoiceMember(
                id: userId, name: name, username: (user?["username"] as? String) ?? voice[userId]?.username,
                avatar: user.flatMap { Self.avatarURL($0) } ?? voice[userId]?.avatar,
                channelId: channelId, guildId: d["guild_id"] as? String ?? "",
                muted: (d["self_mute"] as? Bool ?? false) || (d["mute"] as? Bool ?? false),
                deafened: (d["self_deaf"] as? Bool ?? false) || (d["deaf"] as? Bool ?? false),
                live: d["self_stream"] as? Bool ?? false)
            if name == "…", let guild = d["guild_id"] as? String { fetchMemberName(userId, guild: guild) }
        } else {
            voice[userId] = nil
        }
        resolveUsername()
        applyMyVoice(wasInVoice: wasInVoice)
    }

    /// Re-evaluates "am I in voice" (state change, or the user ID just got set).
    private func refreshMyVoice() {
        resolveUsername()
        applyMyVoice(wasInVoice: voiceSince != nil)
    }

    /// The Settings field also takes a username ("rafial141"): once that person shows up
    /// (in voice), it is swapped for the numeric ID mentions and voice states use.
    private func resolveUsername() {
        let wanted = userId.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty, !wanted.allSatisfy(\.isNumber),
              let me = voice.values.first(where: { $0.username?.lowercased() == wanted }) else { return }
        discordLog("username \(wanted) → \(me.id)")
        userId = me.id
    }

    private func applyMyVoice(wasInVoice: Bool) {
        let inVoice = myVoice != nil
        AppState.shared.voiceOutfit = myVoice.map { $0.muted ? .headsetMuted : .headset }
        if inVoice != wasInVoice {
            voiceSince = inVoice ? Date() : nil
            if inVoice {
                // The voice controls live on the Discord card: bring it forward.
                AppState.shared.setFocus(Self.pillId)
                NotificationCenter.default.post(name: .hookReveal, object: nil)
            }
        }
        syncTask()
    }

    private func message(_ d: [String: Any]) -> Message? {
        guard let id = d["id"] as? String, let channelId = d["channel_id"] as? String,
              let author = d["author"] as? [String: Any] else { return nil }
        let member = d["member"] as? [String: Any]
        let mentioned = (d["mentions"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == userId }
        var content = d["content"] as? String ?? ""
        if content.isEmpty, let files = d["attachments"] as? [[String: Any]], !files.isEmpty {
            content = "📎 " + files.compactMap { $0["filename"] as? String }.joined(separator: ", ")
        }
        return Message(
            id: id, channelId: channelId, guildId: d["guild_id"] as? String ?? channel(channelId)?.guildId ?? "",
            author: (member?["nick"] as? String) ?? (author["global_name"] as? String) ?? (author["username"] as? String ?? "?"),
            avatar: Self.avatarURL(author), content: Self.readable(content),
            date: (d["timestamp"] as? String).flatMap { ISO8601DateFormatter.discord.date(from: $0) } ?? Date(),
            mentionsMe: !userId.isEmpty && mentioned)
    }

    /// `<@123>` → `@name` when known, so mentions read naturally.
    private static func readable(_ s: String) -> String {
        s.replacingOccurrences(of: #"<@!?(\d+)>"#, with: "@…", options: .regularExpression)
         .replacingOccurrences(of: #"<#(\d+)>"#, with: "#…", options: .regularExpression)
    }

    private static func avatarURL(_ user: [String: Any]) -> URL? {
        guard let id = user["id"] as? String, let hash = user["avatar"] as? String else { return nil }
        return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(hash).png?size=64")
    }

    private func announceMention(_ m: Message) {
        mentions = Array(([m] + mentions).prefix(10))
        lastBadgeAlert = Date()
        highlightedMessage = m.id
        selectedTab = selectedChannels.contains(m.channelId) ? m.channelId : "mentions"
        let state = AppState.shared
        if let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) {
            if state.focusId != Self.pillId { state.tasks[i].pillBadge = .approval }
        }
        state.setFocus(Self.pillId)
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)
        SoundEngine.shared.play("peek")
        // Opens to the Discord view; folds itself after the usual auto-close delay.
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.discord)
    }

    private func syncTask() {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let name = myVoice.flatMap { channel($0.channelId)?.name }.map { "🔊 \($0)" }
            ?? ((unread ?? 0) > 0 ? "Discord · \(unread!)" : "Discord")
        if state.tasks[i].name != name { state.tasks[i].name = name }
    }

    // MARK: - REST

    private func rest(_ method: String, _ path: String, json: [String: Any]? = nil,
                      file: URL? = nil) async -> (Int, Data?) {
        guard let token, let url = URL(string: "https://discord.com/api/v10\(path)") else { return (0, nil) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("DiscordBot (coucou, 1.0)", forHTTPHeaderField: "User-Agent")
        if let file, let fileData = try? Data(contentsOf: file) {
            let boundary = "coucou-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func part(_ s: String) { body.append(s.data(using: .utf8)!) }
            part("--\(boundary)\r\nContent-Disposition: form-data; name=\"payload_json\"\r\nContent-Type: application/json\r\n\r\n")
            body.append((try? JSONSerialization.data(withJSONObject: json ?? [:])) ?? Data())
            part("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            body.append(fileData)
            part("\r\n--\(boundary)--\r\n")
            req.httpBody = body
        } else if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func loadHistory() {
        guard connection == .connected || connection == .connecting else { return }
        for id in selectedChannels where messages[id] == nil {
            Task {
                let (status, data) = await rest("GET", "/channels/\(id)/messages?limit=15")
                guard status == 200, let data,
                      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
                messages[id] = list.compactMap(message).reversed()
            }
        }
    }

    private func fetchMemberName(_ userId: String, guild: String) {
        Task {
            let (status, data) = await rest("GET", "/guilds/\(guild)/members/\(userId)")
            guard status == 200, let data, let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var v = voice[userId] else { return }
            let user = m["user"] as? [String: Any]
            v.name = (m["nick"] as? String) ?? (user?["global_name"] as? String) ?? (user?["username"] as? String) ?? v.name
            v.avatar = user.flatMap { Self.avatarURL($0) } ?? v.avatar
            v.username = (user?["username"] as? String) ?? v.username
            voice[userId] = v
            refreshMyVoice()
        }
    }

    /// Posts as the bot. Only ever called from the Send button.
    func post(_ text: String, file: URL?, to channelId: String) async -> Bool {
        let (status, _) = await rest("POST", "/channels/\(channelId)/messages",
                                     json: text.isEmpty ? [:] : ["content": text], file: file)
        return status == 200
    }

    // MARK: - Voice mute

    /// Sends Discord's own Toggle Mute shortcut (⌘⇧M) straight to the Discord app, without
    /// bringing it forward. The real state comes back through the Gateway (self_mute).
    func toggleMute() {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first?.processIdentifier
        else { return }
        // Discord reads ⌘⇧M only while one of its windows is open. Minimised or closed, its global
        // keybinds ignore synthetic keys (raw HID), so use Discord's own menu bar item ▸ Mute instead.
        let windowOpen = Self.hasOpenWindow(pid)
        discordLog("toggleMute window=\(windowOpen)")
        guard windowOpen || !Self.pressTrayMute(pid) else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 46, keyDown: down)   // kVK_ANSI_M
            e?.flags = [.maskCommand, .maskShift]
            e?.postToPid(pid)
        }
    }

    /// Opens Discord's menu bar item and presses its "Mute" entry (toggles, like the tray does).
    private static func pressTrayMute(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        func kids(_ e: AXUIElement) -> [AXUIElement] {
            var v: AnyObject?
            AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
            return v as? [AXUIElement] ?? []
        }
        func str(_ e: AXUIElement, _ a: String) -> String? {
            var v: AnyObject?
            AXUIElementCopyAttributeValue(e, a as CFString, &v)
            return v as? String
        }
        var bar: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &bar) == .success,
              let item = kids(bar as! AXUIElement).first else { return false }
        AXUIElementSetMessagingTimeout(item, 0.3)   // AXPress blocks while the menu is open
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard let menu = kids(item).first(where: { str($0, kAXRoleAttribute) == kAXMenuRole }) else { return false }
        guard let mute = kids(menu).first(where: { str($0, kAXTitleAttribute) == "Mute" }) else {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            return false
        }
        AXUIElementPerformAction(mute, kAXPressAction as CFString)
        return true
    }

    private static func hasOpenWindow(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
              let wins = v as? [AXUIElement] else { return false }
        return wins.contains { w in
            var m: AnyObject?
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &m)
            return (m as? Bool) != true
        }
    }

    // MARK: - Links

    func openDiscord() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func open(_ m: Message) { open(path: "\(m.guildId)/\(m.channelId)/\(m.id)") }
    func open(_ c: Channel) { open(path: "\(c.guildId)/\(c.id)") }
    private func open(path: String) {
        if let url = URL(string: "discord://-/channels/\(path)") { NSWorkspace.shared.open(url) }
    }

    // MARK: - Helpers

    /// Space Assistant bot token, stored by Venturo Bot (macOS asks once before sharing it).
    private static func readToken() -> (token: String?, status: OSStatus) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "space-assistance-bot-token",
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        let token = (out as? Data).flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (status == errSecSuccess ? token : nil, status)
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
}

func discordLog(_ s: String) {
    #if DEBUG
    Logger(subsystem: "fr.louisraille.NotchBuddy", category: "discord").notice("\(s, privacy: .public)")
    #endif
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let discord: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
#endif
