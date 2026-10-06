#if !APPSTORE
import AppKit
import Combine
import Foundation

// MARK: - Venturo Bot Monitor

/// Reads the local files of the Venturo Bot app (Space Assistance status, runs, usage log) and
/// watches them for changes; never reads its webhooks or tokens. GitHub build only.
@MainActor
final class VenturoBotMonitor: ObservableObject {
    static let shared = VenturoBotMonitor()
    static let pillId = "integration_venturo"
    static let bundleId = "pro.venturo.venturo-bot"

    enum Health { case ok, busy, failing, off }

    struct Run: Identifiable {
        let id: String            // runs/<id>-result.json
        let date: Date
        let created: Bool
        let code: String?         // KC-1234
        let title: String         // task name, or the error summary
        let permalink: URL?
    }

    @Published private(set) var discord: Health = .off
    @Published private(set) var listener: Health = .off
    @Published private(set) var mcp: Health = .ok
    @Published private(set) var claude: Health = .ok
    @Published private(set) var daily: Health = .off
    @Published private(set) var weekly: Health = .off
    @Published private(set) var since: Date?
    @Published private(set) var currentVerb: String?
    @Published private(set) var runs: [Run] = []
    @Published private(set) var lastError: (date: Date, text: String)?
    @Published private(set) var lastDaily: Date?
    @Published private(set) var lastWeekly: (date: Date, text: String)?
    @Published private(set) var dailyTime: String?

    var lastRun: Run? { runs.first }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) != nil }
    /// Worst state across the components (drives the pill dot and Mochi).
    var overall: Health {
        let all = [discord, listener, mcp, claude]
        if all.contains(.failing) { return .failing }
        if discord == .busy { return .busy }
        return all.contains(.off) ? .off : .ok
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var assistDir: URL { home.appendingPathComponent(".claude/space-assistance") }
    private var runsDir: URL { assistDir.appendingPathComponent("runs") }
    private var usageLog: URL { home.appendingPathComponent("Library/Logs/claude-usage-discord.log") }
    private var botConfig: URL { home.appendingPathComponent(".config/venturo-bot/config.json") }

    private var watchers: [DispatchSourceFileSystemObject] = []
    private var mcpCheck: (date: Date, health: Health)?
    private var reloadWork: DispatchWorkItem?
    private var seenRunId: String?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] on in on ? self?.start() : self?.stop() }
            .store(in: &cancellables)
    }

    // MARK: - Watching (no polling: file-system events only, and only while the pill is on)

    private func start() {
        stop()
        // status.json and the usage log are rewritten / appended in place: watch the files.
        // runs/ gets new files and the config is saved whole: watch those directories.
        let paths = [assistDir.appendingPathComponent("status.json"), usageLog, runsDir, botConfig.deletingLastPathComponent()]
        for url in paths {
            let fd = Darwin.open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleReload() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers.append(src)
        }
        reload(announce: false)
    }

    private func stop() {
        watchers.forEach { $0.cancel() }
        watchers = []
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload(announce: true, refreshListener: false) }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Re-reads everything. `refreshListener` also asks launchd (spawns launchctl, so only on demand).
    func reload(announce: Bool = false, refreshListener: Bool = true) {
        readStatus()
        readRuns(announce: announce)
        readUsage()
        if refreshListener {
            readListener()
            Task { await checkMCP() }
        }
        syncTask()
    }

    // MARK: - Readers

    private func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static let isoLocal: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }()
    private static let logDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    private static let runDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f
    }()

    private func readStatus() {
        guard let s = json(assistDir.appendingPathComponent("status.json")) else { discord = .off; return }
        let connected = s["connected"] as? Bool ?? false
        currentVerb = (s["current"] as? [String: Any])?["verb"] as? String
        discord = !connected ? .failing : (currentVerb != nil ? .busy : .ok)
        since = (s["since"] as? String).flatMap(Self.isoLocal.date(from:))
    }

    private func readRuns(announce: Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: runsDir.path)) ?? []
        let ids = names.filter { $0.hasSuffix("-result.json") }
            .map { String($0.dropLast("-result.json".count)) }
            .sorted(by: >).prefix(4)
        runs = ids.compactMap { id in
            guard let r = json(runsDir.appendingPathComponent("\(id)-result.json")) else { return nil }
            let req = json(runsDir.appendingPathComponent("\(id)-request.json"))
            let task = (r["tasks"] as? [[String: Any]])?.first
            let created = r["status"] as? String == "created"
            let title = created ? (task?["name"] as? String ?? "") : (r["summary"] as? String ?? "Failed")
            return Run(id: id, date: Self.runDate.date(from: String(id.prefix(15))) ?? .distantPast,
                       created: created, code: task?["code_issue"] as? String, title: title,
                       permalink: (req?["permalink"] as? String).flatMap(URL.init(string:)))
        }
        // MCP / Claude health: inferred from the latest run's error (the bot keeps no direct status).
        mcp = .ok; claude = .ok; lastError = nil
        if let last = runs.first, !last.created {
            lastError = (last.date, last.title)
            let t = last.title.lowercased()
            if t.contains("mcp") || t.contains("oauth") || t.contains("space") { mcp = .failing } else { claude = .failing }
        }
        // A live `claude mcp get space` newer than that failure wins over the guess.
        if let check = mcpCheck, check.date > (lastError?.date ?? .distantPast) { mcp = check.health }
        guard let newest = runs.first, newest.id != seenRunId else { return }
        let first = seenRunId == nil
        seenRunId = newest.id
        if announce && !first { announceRun(newest) }
    }

    private func readUsage() {
        let cfg = json(botConfig)
        let d = cfg?["daily"] as? [String: Any], w = cfg?["weekly"] as? [String: Any]
        let dailyOn = d?["enabled"] as? Bool ?? false, weeklyOn = w?["enabled"] as? Bool ?? false
        if let h = d?["hour"] as? Int, let m = d?["minute"] as? Int { dailyTime = String(format: "%02d:%02d", h, m) }
        // Only the tail matters: the log grows forever.
        let text = (try? FileHandle(forReadingFrom: usageLog)).flatMap { fh -> String? in
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            try? fh.seek(toOffset: size > 16_000 ? size - 16_000 : 0)
            return String(data: fh.readDataToEndOfFile(), encoding: .utf8)
        } ?? ""
        var dailyFailed = false, weeklyFailed = false
        lastDaily = nil; lastWeekly = nil
        for line in text.split(separator: "\n") {
            let date = Self.logDate.date(from: String(line.prefix(19)))
            if line.contains("[harian]") {
                dailyFailed = !line.contains("terkirim")
                if !dailyFailed { lastDaily = date }
            } else if line.contains("[peringatan]") {
                weeklyFailed = !line.contains("terkirim")
                if !weeklyFailed, let date {
                    let pct = line.range(of: #"weekly \d+%"#, options: .regularExpression).map { String(line[$0]) }
                    lastWeekly = (date, pct ?? "")
                }
            }
        }
        daily = !dailyOn ? .off : (dailyFailed ? .failing : .ok)
        weekly = !weeklyOn ? .off : (weeklyFailed ? .failing : .ok)
    }

    private func readListener() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/pro.venturo.space-assistance"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = Pipe()
        p.terminationHandler = { [weak self] proc in
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let running = proc.terminationStatus == 0 && text.contains("state = running")
            Task { @MainActor in
                self?.listener = running ? .ok : .failing
                self?.syncTask()
            }
        }
        try? p.run()
    }

    // MARK: - Pill + events

    private func syncTask() {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let new: BotState = switch overall {
        case .busy: .thinking
        case .failing: .error
        default: state.tasks[i].state == .finished ? .finished : .idle
        }
        if state.tasks[i].state != new { state.tasks[i].state = new }
    }

    private func announceRun(_ run: Run) {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let focused = state.focusId == Self.pillId
        if run.created {
            state.tasks[i].state = .finished
            if !focused { state.tasks[i].pillBadge = .finished }
            SoundEngine.shared.play("finish")
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let j = state.tasks.firstIndex(where: { $0.id == Self.pillId }),
                      state.tasks[j].state == .finished else { return }
                state.tasks[j].state = .idle
                self?.syncTask()
            }
        } else {
            if !focused { state.tasks[i].pillBadge = .error }
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.annoyed)
        }
        NotificationCenter.default.post(name: .hookReveal, object: nil)
    }

    // MARK: - Troubleshooting

    enum FixTarget { case discord, listener, mcp, claude, daily, weekly }

    struct Outcome {
        enum Kind { case fixed, needsYou, failed }
        let kind: Kind
        let title: String
        let detail: String
        var action: (label: String, run: FixAction)? = nil
    }

    enum FixAction { case terminal(String), sendDaily, testWeekly }

    struct FixState {
        let target: FixTarget
        let steps: [String]
        var step = 0              // running step; == steps.count once done
        var outcome: Outcome?
    }

    @Published private(set) var fix: FixState?

    func dismissFix() {
        fix = nil
        reload()
    }

    /// Runs the checks/repairs for one component, step by step (each step lasts at least 0.7 s so
    /// the repair animation reads). Only the listener restart changes anything; sending a report
    /// waits for an explicit click on the outcome's button.
    func troubleshoot(_ target: FixTarget) {
        guard fix == nil else { return }
        let steps: [String] = switch target {
        case .discord, .listener: ["Memeriksa listener", "Menjalankan ulang listener", "Menunggu Discord terhubung"]
        case .mcp:                ["Memeriksa MCP Space", "Memeriksa login (OAuth)"]
        case .claude:             ["Memeriksa Claude CLI", "Memeriksa login"]
        case .daily, .weekly:     ["Memeriksa skrip laporan", "Uji ambil usage (dry-run)"]
        }
        fix = FixState(target: target, steps: steps)
        setMochi(.working)
        Task {
            let outcome: Outcome = switch target {
            case .discord, .listener: await fixListener()
            case .mcp:                await fixMCP()
            case .claude:             await fixClaude()
            case .daily, .weekly:     await fixReport(weekly: target == .weekly)
            }
            fix?.step = steps.count
            fix?.outcome = outcome
            setMochi(outcome.kind == .fixed ? .finished : .error)
            if outcome.kind == .fixed {
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
                SoundEngine.shared.play("finish")
            }
        }
    }

    /// Advances to `index` after `body`, keeping each step on screen for at least 0.7 s.
    private func step<T>(_ index: Int, _ body: () async -> T) async -> T {
        fix?.step = index
        let start = Date()
        let result = await body()
        let left = 0.7 - Date().timeIntervalSince(start)
        if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000)) }
        return result
    }

    private func fixListener() async -> Outcome {
        let label = "gui/\(getuid())/pro.venturo.space-assistance"
        let started = Date()
        let loaded = await step(0) { await Self.sh("/bin/launchctl", ["print", label]).status == 0 }
        let restarted = await step(1) { () -> Bool in
            if loaded { return await Self.sh("/bin/launchctl", ["kickstart", "-k", label]).status == 0 }
            let plist = home.appendingPathComponent("Library/LaunchAgents/pro.venturo.space-assistance.plist").path
            return await Self.sh("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist]).status == 0
        }
        guard restarted else {
            return Outcome(kind: .failed, title: "Listener gagal dijalankan",
                           detail: "Nyalakan Space Assistance dari panel Venturo Bot, lalu cek log.")
        }
        // Wait for the fresh process to report itself connected (checked once a second, max 30 s).
        let connected = await step(2) { () -> Bool in
            for _ in 0..<30 {
                if let s = json(assistDir.appendingPathComponent("status.json")),
                   s["connected"] as? Bool == true,
                   let updated = (s["updated_at"] as? String).flatMap(Self.isoLocal.date(from:)),
                   updated >= started.addingTimeInterval(-1) { return true }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return false
        }
        let secs = Int(Date().timeIntervalSince(started))
        return connected
            ? Outcome(kind: .fixed, title: "Listener berjalan lagi", detail: "Discord terhubung kembali · \(secs) dtk")
            : Outcome(kind: .failed, title: "Discord belum terhubung", detail: "Listener jalan, tapi belum tersambung ke Discord dalam 30 dtk. Cek log.")
    }

    private func fixMCP() async -> Outcome {
        let health = await step(0) { await checkMCP() }
        await step(1) { }
        switch health {
        case .ok:
            return Outcome(kind: .fixed, title: "MCP Space terhubung", detail: "Error terakhir sudah tidak terjadi lagi.")
        case .failing where lastMCPOutput.contains("Needs authentication"):
            return Outcome(kind: .needsYou, title: "MCP Space minta login ulang",
                           detail: "Di Terminal ketik /mcp → pilih space → Authenticate.",
                           action: ("Buka Terminal", .terminal("claude")))
        default:
            return Outcome(kind: .failed, title: "MCP Space tidak terjangkau",
                           detail: lastMCPOutput.split(separator: "\n").first { $0.contains("Status") }.map(String.init)
                               ?? "Server space-mcp tidak menjawab.")
        }
    }

    private func fixClaude() async -> Outcome {
        let out = await step(0) { await Self.sh(Self.claudePath, ["auth", "status"]) }
        let loggedIn = await step(1) { out.text.contains("\"loggedIn\": true") }
        if !loggedIn {
            return Outcome(kind: .needsYou, title: "Claude belum login", detail: "Di Terminal ketik /login.",
                           action: ("Buka Terminal", .terminal("claude")))
        }
        return Outcome(kind: .fixed, title: "Claude CLI siap",
                       detail: "Login OK. Error terakhir kemungkinan limit atau timeout sementara; run berikutnya dicoba lagi.")
    }

    private func fixReport(weekly: Bool) async -> Outcome {
        let exists = await step(0) { FileManager.default.isExecutableFile(atPath: Self.reportScript) }
        guard exists else {
            return Outcome(kind: .failed, title: "Skrip laporan tidak ada", detail: "Jalankan build.sh Venturo Bot untuk memasangnya lagi.")
        }
        let dry = await step(1) { await Self.sh(Self.reportScript, ["--dry-run"]) }
        guard dry.status == 0 else {
            return Outcome(kind: .failed, title: "Usage gagal diambil",
                           detail: dry.text.split(separator: "\n").last.map(String.init) ?? "Cek log laporan.")
        }
        return Outcome(kind: .needsYou, title: "Usage berhasil diambil",
                       detail: weekly ? "Kirim tes peringatan weekly ke Discord?" : "Kirim ulang laporan harian ke Discord?",
                       action: weekly ? ("Kirim tes", .testWeekly) : ("Kirim ulang", .sendDaily))
    }

    /// The outcome's button: only runs on an explicit click.
    func runFixAction(_ action: FixAction) {
        switch action {
        case .terminal(let command):
            // A .command file opens in Terminal without needing Automation permission.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-venturo.command")
            try? "#!/bin/zsh -l\n\(Self.claudePath) \(command == "claude" ? "" : command)\n"
                .write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            dismissFix()
        case .sendDaily, .testWeekly:
            let args = action.isWeekly ? "--test weekly" : ""
            fix?.outcome = Outcome(kind: .needsYou, title: "Mengirim…", detail: "")
            setMochi(.working)
            Task {
                // Same log as launchd, so the status dot follows.
                let r = await Self.sh("/bin/sh", ["-c", "'\(Self.reportScript)' \(args) >> '\(usageLog.path)' 2>&1"])
                fix?.outcome = r.status == 0
                    ? Outcome(kind: .fixed, title: "Terkirim ke Discord", detail: action.isWeekly ? "Tes peringatan weekly" : "Laporan harian")
                    : Outcome(kind: .failed, title: "Gagal mengirim", detail: "Lihat baris GAGAL di log laporan.")
                setMochi(r.status == 0 ? .finished : .error)
            }
        }
    }

    private var lastMCPOutput = ""

    /// `claude mcp get space` (~10 s, network): run on pill start, detail open and repair only.
    @discardableResult
    private func checkMCP() async -> Health {
        let r = await Self.sh(Self.claudePath, ["mcp", "get", "space"], timeout: 30)
        lastMCPOutput = r.text
        let health: Health = r.text.contains("✔ Connected") ? .ok : .failing
        mcpCheck = (Date(), health)
        mcp = health
        syncTask()
        return health
    }

    private func setMochi(_ s: BotState) {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        state.tasks[i].state = s
    }

    private static let claudePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
    private static let reportScript = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude-usage-discord.py").path

    /// Runs a tool off the main thread; output is small (status lines), read after exit.
    private static func sh(_ exe: String, _ args: [String], timeout: TimeInterval = 60) async -> (status: Int32, text: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out; p.standardError = out
            p.terminationHandler = { proc in
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: (proc.terminationStatus, text))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, "\(error)")); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }

    // MARK: - Actions

    /// Opens the Venturo Bot panel by pressing its menu bar icon (Menu Bar tray), else launches it.
    func openApp() {
        let tray = MenuBarTray.shared
        if tray.canListItems {
            tray.refresh()
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first?.processIdentifier
            if let item = tray.items.first(where: { $0.pid == pid }) { tray.press(item); return }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func openLastThread() {
        guard let url = runs.first(where: { $0.permalink != nil })?.permalink else { return }
        NSWorkspace.shared.open(url)
    }

    func openThread(of run: Run) {
        if let url = run.permalink { NSWorkspace.shared.open(url) }
    }

    func openLog() {
        NSWorkspace.shared.open(assistDir.appendingPathComponent("bot.log"))
    }
}

extension VenturoBotMonitor.FixAction {
    var isWeekly: Bool { if case .testWeekly = self { return true }; return false }
}
#endif
