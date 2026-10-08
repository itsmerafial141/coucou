#if !APPSTORE
import AppKit
import Combine
import Foundation

// MARK: - Superset Service

/// Watches the Superset desktop app's workspaces and agents through its local host database (read-only,
/// no network, no login). Checks every 5 s only while the pill is on, and re-reads the database only
/// when its files changed. Answers an agent's numbered prompt or sends it a reply through the host service
/// on 127.0.0.1 (endpoint and token from its manifest, read on each call), only on an explicit click.
/// Codex requests Coucou's own hook is holding are answered through that hook instead. GitHub build only.
@MainActor
final class SupersetService: ObservableObject {
    static let shared = SupersetService()
    static let pillId = "integration_superset"
    static let colorHex = "#FB923C"

    enum Health { case ok, working, needsYou, off }

    @Published private(set) var workspaces: [Superset.Workspace] = []
    @Published private(set) var dbPath: String?
    @Published private(set) var error: String?
    /// Agents that asked for the user or finished a turn, not yet seen (newest first).
    @Published private(set) var events: [String] = []
    /// Numbered prompts read from the screens of agents that need the user, by terminal id.
    @Published private(set) var prompts: [String: Superset.Prompt] = [:]
    @Published private(set) var sending: Set<String> = []

    private var previous: [String: Superset.Status]?
    private var lastStamp: Date?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    var isInstalled: Bool { dbPath != nil }
    var counts: Superset.Counts { Superset.counts(workspaces) }

    var overall: Health {
        if dbPath == nil || error != nil { return .off }
        let c = counts
        if c.needsYou > 0 { return .needsYou }
        return c.working > 0 ? .working : .ok
    }

    private init() {
        dbPath = Superset.defaultDBPath()
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] on in on ? self?.start() : self?.stop() }
            .store(in: &cancellables)
    }

    // MARK: - Polling (only while the pill is on)

    private func start() {
        stop()
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in SupersetService.shared.refresh() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        previous = nil
        lastStamp = nil
    }

    func refresh(force: Bool = false) {
        if dbPath == nil { dbPath = Superset.defaultDBPath() }
        guard let path = dbPath else { syncTask(); return }
        // Superset writes through its WAL: the newest of the two files says whether anything changed.
        let stamp = [path, path + "-wal"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }.max()
        guard force || stamp != lastStamp else { return }
        lastStamp = stamp
        guard let ws = Superset.load(path: path) else {
            error = "Can't read Superset's database (app updated?)"
            syncTask()
            return
        }
        error = nil
        for (w, a) in Superset.transitions(from: previous, to: ws) { announce(w, a) }
        previous = Superset.snapshot(ws)
        workspaces = ws
        syncTask()
        loadPrompts()
    }

    // MARK: - Prompts, answers and replies (host service, explicit clicks only)

    /// The Codex request Coucou's hook is holding, if this agent is the one asking.
    /// ponytail: matched by agent kind; two Codex agents asking at once share the one hook card.
    func hookApproval(for agent: Superset.Agent) -> ApprovalInfo? {
        guard agent.agentId == "codex", agent.status == .needsYou,
              let a = AppState.shared.pendingApproval, a.pillId == "agent_codex" else { return nil }
        return a
    }

    func answerHook(_ decision: String) {
        HookServer.shared.sendApprovalDecision(decision)
    }

    /// Reads the screen of every agent that needs the user and has no prompt yet; drops stale ones.
    func loadPrompts() {
        let asking = workspaces.flatMap { w in w.agents.filter { $0.status == .needsYou }.map { (w, $0) } }
        prompts = prompts.filter { id, _ in asking.contains { $0.1.terminalId == id } }
        for (w, a) in asking where prompts[a.terminalId] == nil && hookApproval(for: a) == nil {
            Task {
                // The status lands a moment before the prompt is drawn: one retry.
                for attempt in 0..<2 {
                    if attempt > 0 { try? await Task.sleep(for: .seconds(1.5)) }
                    if let screen = await snapshot(w, a), let p = Superset.prompt(fromScreen: screen) {
                        prompts[a.terminalId] = p
                        return
                    }
                }
            }
        }
    }

    /// Presses the option's digit in the agent's terminal (no Enter: the digit is the answer).
    func answer(_ w: Superset.Workspace, _ a: Superset.Agent, key: String) {
        Task {
            if await send(w, a, text: key, submit: false) { prompts[a.terminalId] = nil }
        }
    }

    /// Types a message into the agent's terminal and presses Enter.
    @discardableResult
    func reply(_ w: Superset.Workspace, _ a: Superset.Agent, text: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return await send(w, a, text: t, submit: true)
    }

    private func snapshot(_ w: Superset.Workspace, _ a: Superset.Agent) async -> String? {
        let input = ["json": ["workspaceId": w.id, "terminalId": a.terminalId, "maxLines": 40]]
        guard let data = try? JSONSerialization.data(withJSONObject: input),
              let q = String(data: data, encoding: .utf8)?.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let json = await host("GET", "terminal.snapshot?input=\(q)") else { return nil }
        return json["text"] as? String
    }

    private func send(_ w: Superset.Workspace, _ a: Superset.Agent, text: String, submit: Bool) async -> Bool {
        sending.insert(a.terminalId)
        defer { sending.remove(a.terminalId) }
        let body = ["json": ["workspaceId": w.id, "terminalId": a.terminalId, "text": text, "submit": submit] as [String: Any]]
        guard await host("POST", "terminal.send", body: body) != nil else {
            error = "Superset didn't take the answer (is the app running?)"
            return false
        }
        error = nil
        try? await Task.sleep(for: .seconds(1))
        refresh(force: true)
        return true
    }

    /// One tRPC call to Superset's local host service; the `result.data.json` payload, nil on any failure.
    private func host(_ method: String, _ path: String, body: [String: Any]? = nil) async -> [String: Any]? {
        guard let dir = dbPath.map({ ($0 as NSString).deletingLastPathComponent }),
              let data = FileManager.default.contents(atPath: dir + "/manifest.json"),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoint = manifest["endpoint"] as? String, let token = manifest["authToken"] as? String,
              let url = URL(string: endpoint + "/trpc/" + path),
              ["127.0.0.1", "localhost"].contains(url.host) else { return nil }   // never off this Mac
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (resp, http) = try? await URLSession.shared.data(for: req),
              (http as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
              let result = (obj["result"] as? [String: Any])?["data"] as? [String: Any] else { return nil }
        return result["json"] as? [String: Any] ?? [:]
    }

    // MARK: - Actions

    func open(_ workspace: Superset.Workspace? = nil) {
        let url = workspace.map { URL(string: "superset://v2-workspace/\($0.id)") } ?? URL(string: "superset://app")
        if let url { NSWorkspace.shared.open(url) }
    }

    func openPR(_ pr: Superset.PullRequest) {
        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
    }

    func markSeen() {
        guard !events.isEmpty else { return }
        events = []
        if let i = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }) {
            AppState.shared.tasks[i].pillBadge = nil
        }
    }

    // MARK: - Internals

    private func announce(_ w: Superset.Workspace, _ a: Superset.Agent) {
        let asks = a.status == .needsYou
        events.insert("\(w.title) · \(a.agentId) \(asks ? "needs you" : "finished")", at: 0)
        if events.count > 5 { events.removeLast() }
        let state = AppState.shared
        if let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }), state.focusId != Self.pillId {
            state.tasks[i].pillBadge = asks ? .approval : .finished
        }
        // Coucou's own hook already rings for Claude Code sessions (Superset terminals included):
        // only the badge here, so one event never sounds twice.
        guard a.agentId != "claude" else { return }
        SoundEngine.shared.play(asks ? "approval" : "finish")
        NotificationCenter.default.post(name: .triggerEmote, object: asks ? BotEmote.surprised : BotEmote.proud)
        NotificationCenter.default.post(name: .hookReveal, object: nil)
    }

    private func syncTask() {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let new: BotState
        switch overall {
        case .needsYou: new = .approval
        case .working:  new = .working
        case .ok, .off: new = error != nil ? .error : .idle
        }
        if state.tasks[i].state != new { state.tasks[i].state = new }
    }
}
#endif
