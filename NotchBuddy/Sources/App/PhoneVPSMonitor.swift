#if !APPSTORE
import AppKit
import Combine
import Foundation

// MARK: - Phone VPS Monitor

/// Watches the phone server (Galaxy A50 / Termux) behind ssh.pipo.web.id. Everything on the phone
/// goes through its `mcp-gate` (the same validated verbs the phone-vps MCP uses), over the user's own
/// `ssh phonevps-tunnel` host from ~/.ssh/config: the app holds no key or token. Sites are checked
/// from the Mac, so they still answer when the phone is unreachable. GitHub build only.
@MainActor
final class PhoneVPSMonitor: ObservableObject {
    static let shared = PhoneVPSMonitor()
    static let pillId = "integration_phonevps"
    static let colorHex = "#A3E635"
    nonisolated static let sshHost = "phonevps-tunnel"
    /// Services `restart` accepts on the phone (mcp-gate's list).
    static let restartable: Set<String> = ["health-api", "space-mcp", "jenkins", "postgres"]
    /// Services with a log `log` can tail.
    static let withLog: Set<String> = ["cloudflared", "cloudflared-watchdog", "jenkins", "space-mcp", "health-api"]
    /// Hosts served by nginx on the phone (same list as the MCP's luar.py).
    nonisolated static let sites = ["jenkins", "space-mcp", "health", "health-view", "venturo", "venturo-dev", "venturo-staging"]

    enum Health { case ok, busy, failing, off }

    typealias Service = PhoneVPS.Service
    typealias Site = PhoneVPS.Site
    typealias Stats = PhoneVPS.Stats

    /// Result panel of a troubleshooting action (diagnose, log, restart, nginx reload).
    struct Output {
        let title: String
        var text: String
        var running: Bool
        var ok: Bool = true
    }

    @Published private(set) var reachable: Health = .off
    @Published private(set) var services: [Service] = []
    @Published private(set) var siteResults: [Site] = []
    @Published private(set) var stats = Stats()
    @Published private(set) var checking = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?
    @Published var output: Output?

    var isConfigured: Bool {
        let cfg = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        return (try? String(contentsOf: cfg, encoding: .utf8))?.contains("Host \(Self.sshHost)") ?? false
    }

    /// Worst state across SSH, services and sites (drives the pill dot and Mochi).
    var overall: Health {
        if reachable == .failing { return .failing }
        if services.contains(where: { !$0.healthy }) || siteResults.contains(where: { !$0.healthy }) { return .failing }
        if checking || output?.running == true { return .busy }
        return reachable
    }

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] on in on ? self?.start() : self?.stop() }
            .store(in: &cancellables)
    }

    // MARK: - Polling (only while the pill is on)

    // ponytail: 5 min poll over SSH; push from the phone (webhook) if it ever needs to be live.
    private func start() {
        stop()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in PhoneVPSMonitor.shared.refresh() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !checking else { return }
        checking = true
        syncTask()
        Task {
            async let sitesResult = Self.checkSites()
            async let svc = Self.gate("services")
            async let st = Self.gate("status")
            let (s, status, sites) = await (svc, st, sitesResult)
            siteResults = sites
            if s.code == 0 {
                reachable = .ok
                lastError = nil
                services = PhoneVPS.parseServices(s.text)
                if status.code == 0 { stats = PhoneVPS.parseStats(status.text) }
            } else {
                reachable = .failing
                lastError = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                services = []
            }
            lastCheck = Date()
            checking = false
            syncTask()
        }
    }

    // MARK: - Troubleshooting (each runs only on an explicit click)

    func diagnose() {
        run(title: "Diagnose") {
            async let sites = Self.checkSites()
            async let svc = Self.gate("services")
            let (s, siteList) = await (svc, sites)
            let list = PhoneVPS.parseServices(s.text)
            let down = list.filter { !$0.healthy }.map(\.name)
            let broken = siteList.filter { !$0.healthy }
            let conclusion: String
            if s.code != 0 {
                conclusion = siteList.allSatisfy({ $0.code == 530 || $0.code == 1033 || $0.code == nil })
                    ? "Tunnel is down: the phone is unreachable. Check the phone, or restart cloudflared over LAN (ssh phonevps-lan)."
                    : "SSH fails while sites answer: sshd down, mcp-gate/key problem, or the phone is very slow."
            } else if !down.isEmpty {
                conclusion = "Services down: \(down.joined(separator: ", ")). Restart them or read their log."
            } else if !broken.isEmpty {
                conclusion = "Sites failing while services run: \(broken.map(\.name).joined(separator: ", ")). Check nginx (reload, error log)."
            } else {
                conclusion = "All healthy."
            }
            let svcText = s.code == 0
                ? list.map { "\($0.name)  \($0.alive ? "running" : "stopped")  port \($0.port)" }.joined(separator: "\n")
                : "SSH failed: \(s.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            let siteText = siteList.map { "\($0.name)  \($0.code.map(String.init) ?? "error")  \($0.ms) ms" }.joined(separator: "\n")
            return (conclusion == "All healthy.", "\(conclusion)\n\nServices\n\(svcText)\n\nSites\n\(siteText)")
        }
    }

    func showLog(_ service: String) {
        guard Self.withLog.contains(service) else { return }
        run(title: "\(service) log") {
            let r = await Self.gate("log", service, "40")
            return (r.code == 0, r.text.isEmpty ? "(empty)" : r.text)
        }
    }

    func restart(_ service: String) {
        guard Self.restartable.contains(service) else { return }
        run(title: "Restart \(service)") {
            let r = await Self.gate("restart", service, timeout: 90)
            return (r.code == 0, r.text)
        }
    }

    func nginxErrors() {
        run(title: "nginx errors (60 min)") {
            let r = await Self.gate("nginx_errors", "60")
            return (r.code == 0, r.text)
        }
    }

    func nginxReload() {
        run(title: "Reload nginx") {
            let r = await Self.gate("nginx_reload")
            return (r.code == 0, r.text)
        }
    }

    func dismissOutput() { output = nil; syncTask() }

    private func run(title: String, _ work: @escaping () async -> (Bool, String)) {
        guard output?.running != true else { return }
        output = Output(title: title, text: "", running: true)
        syncTask()
        Task {
            let (ok, text) = await work()
            guard output?.title == title else { return }
            output = Output(title: title, text: text.trimmingCharacters(in: .whitespacesAndNewlines), running: false, ok: ok)
            if title != "Diagnose" { refresh() } else { syncTask() }
        }
    }

    // MARK: - Pill

    private func syncTask() {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let new: BotState = switch overall {
        case .busy: .working
        case .failing: .error
        default: .idle
        }
        if state.tasks[i].state != new { state.tasks[i].state = new }
    }

    // MARK: - SSH through mcp-gate

    /// Runs one mcp-gate verb on the phone. Code 255 / non-zero = unreachable or refused.
    nonisolated static func gate(_ verb: String, _ args: String..., timeout: TimeInterval = 30) async -> (code: Int32, text: String) {
        let command = ([verb] + args).joined(separator: " ")
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", sshHost,
                           "SSH_ORIGINAL_COMMAND='\(command)' ~/bin/mcp-gate"]
            // ProxyCommand runs `cloudflared`, which Homebrew puts outside a GUI app's PATH.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: (proc.terminationStatus, text))
            }
            do {
                try p.run()
                nonisolated(unsafe) let proc = p
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if proc.isRunning { proc.terminate() } }
            } catch {
                cont.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    nonisolated static func checkSites() async -> [Site] {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: cfg)
        return await withTaskGroup(of: Site.self) { group in
            for name in sites {
                group.addTask {
                    let start = Date()
                    var req = URLRequest(url: URL(string: "https://\(name).pipo.web.id/")!)
                    req.httpMethod = "HEAD"
                    let code = (try? await session.data(for: req)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
                    return Site(name: name, code: code, ms: Int(Date().timeIntervalSince(start) * 1000))
                }
            }
            var all: [Site] = []
            for await s in group { all.append(s) }
            return sites.compactMap { n in all.first { $0.name == n } }
        }
    }

    func openTerminal() {
        let script = "tell application \"Terminal\" to do script \"ssh \(Self.sshHost)\"\nactivate application \"Terminal\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

#endif
