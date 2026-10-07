#if !APPSTORE
import AppKit
import Combine
import Foundation

// MARK: - Superset Service

/// Watches the Superset desktop app's workspaces and agents through its local host database (read-only,
/// no network, no login). Checks every 5 s only while the pill is on, and re-reads the database only
/// when its files changed. GitHub build only.
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
