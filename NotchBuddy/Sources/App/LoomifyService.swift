#if !APPSTORE
import AppKit
import Combine
import Foundation

// MARK: - Loomify Service

/// Reads one kanban board of a Loomify instance (the user's own server) over its REST API v2, moves
/// cards between columns and creates tasks. URL in UserDefaults, API token in the Keychain.
/// Polls every 60 s only while the pill is on. GitHub build only.
@MainActor
final class LoomifyService: ObservableObject {
    static let shared = LoomifyService()
    static let pillId = "integration_loomify"
    static let colorHex = "#A855F7"
    static let tokenKey = "loomify-token"

    struct Project: Identifiable, Hashable { let id: Int; let title: String }

    enum Health { case ok, news, failing, off }

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "loomifyURL"); restartIfActive() }
    }
    @Published private(set) var projectId: Int
    @Published private(set) var projects: [Project] = []
    @Published private(set) var buckets: [Loomify.Bucket] = []
    @Published private(set) var doneBucketId = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// New To-Do cards and comment notifications not yet seen on the board (newest first).
    @Published private(set) var events: [String] = []

    private(set) var viewId = 0
    private var seenCards: Set<Int>?
    private var lastNotificationId: Int?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    var hasToken: Bool { !(KeychainStore.shared.get(Self.tokenKey) ?? "").isEmpty }
    var isPillActive: Bool { AppState.shared.activeIntegrations.contains(Self.pillId) }
    var projectTitle: String { projects.first { $0.id == projectId }?.title ?? (projectId == 0 ? "Loomify" : "Project \(projectId)") }
    var overdue: [Loomify.Card] { Loomify.overdue(buckets, doneBucketId: doneBucketId) }
    var openBuckets: [Loomify.Bucket] { buckets.filter { $0.id != doneBucketId } }
    var doneBucket: Loomify.Bucket? { buckets.first { $0.id == doneBucketId } }
    /// The card being worked on: first card of the in-progress column.
    var current: Loomify.Card? {
        buckets.first { Loomify.kind(of: $0.title) == .doing }?.cards.first
    }

    var overall: Health {
        if !hasToken || projectId == 0 { return .off }
        if error != nil || !overdue.isEmpty { return .failing }
        return events.isEmpty ? .ok : .news
    }

    private init() {
        baseURL = UserDefaults.standard.string(forKey: "loomifyURL") ?? "http://localhost:4173"
        projectId = UserDefaults.standard.integer(forKey: "loomifyProject")
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] on in on ? self?.start() : self?.stop() }
            .store(in: &cancellables)
    }

    // MARK: - Polling (only while the pill is on)

    private func start() {
        stop()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in LoomifyService.shared.refresh() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartIfActive() {
        seenCards = nil
        lastNotificationId = nil
        if isPillActive { start() }
    }

    func setToken(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { KeychainStore.shared.remove(Self.tokenKey) } else { KeychainStore.shared.set(Self.tokenKey, value: t) }
        objectWillChange.send()
        restartIfActive()
    }

    func selectProject(_ id: Int) {
        guard id != projectId else { return }
        projectId = id
        UserDefaults.standard.set(id, forKey: "loomifyProject")
        viewId = 0
        buckets = []
        events = []
        restartIfActive()
    }

    func refresh() {
        guard hasToken, !loading else { return }
        loading = true
        Task {
            defer { loading = false; syncTask() }
            do {
                if projects.isEmpty || projectId == 0 { try await loadProjects() }
                guard projectId != 0 else { return }
                if viewId == 0 { try await resolveView() }
                let data = try await request("GET", "/projects/\(projectId)/views/\(viewId)/buckets/tasks")
                guard let parsed = Loomify.parseBuckets(data) else { throw LoomifyError("Unexpected board data") }
                let fresh = Loomify.newCards(in: parsed, seen: seenCards)
                seenCards = Set(parsed.flatMap(\.cards).map(\.id))
                buckets = parsed
                error = nil
                for card in fresh { announce("\(card.identifier) masuk \(parsed.first?.title ?? "To-Do") · \(card.title)") }
                await checkNotifications()
            } catch {
                self.error = (error as? LoomifyError)?.message ?? error.localizedDescription
            }
        }
    }

    // MARK: - Board actions (each from an explicit click or drop)

    func move(_ card: Loomify.Card, to bucketId: Int) {
        guard let from = buckets.firstIndex(where: { $0.cards.contains(card) }),
              let to = buckets.firstIndex(where: { $0.id == bucketId }), from != to else { return }
        // Optimistic: the card moves at once, the next refresh confirms (or restores) it.
        buckets[from].cards.removeAll { $0.id == card.id }
        buckets[to].cards.insert(card, at: 0)
        Task {
            do {
                _ = try await request("PUT", "/projects/\(projectId)/views/\(viewId)/buckets/\(bucketId)/tasks",
                                      body: ["task_id": card.id])
            } catch {
                self.error = (error as? LoomifyError)?.message ?? error.localizedDescription
            }
            refresh()
        }
    }

    /// Adjacent column (including Done) for the ◀ ▶ buttons.
    func neighbour(of card: Loomify.Card, step: Int) -> Int? {
        guard let i = buckets.firstIndex(where: { $0.cards.contains(card) }),
              buckets.indices.contains(i + step) else { return nil }
        return buckets[i + step].id
    }

    func create(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, projectId != 0 else { return }
        Task {
            do {
                let data = try await request("POST", "/projects/\(projectId)/tasks", body: ["title": t])
                // Our own task is not "new": remember it before the refresh sees it.
                if let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? Int {
                    seenCards?.insert(id)
                }
            } catch {
                self.error = (error as? LoomifyError)?.message ?? error.localizedDescription
            }
            refresh()
        }
    }

    func markSeen() {
        guard !events.isEmpty else { return }
        events = []
        if let i = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }) {
            AppState.shared.tasks[i].pillBadge = nil
        }
        syncTask()
    }

    func open(_ card: Loomify.Card? = nil) {
        let path = card.map { "/tasks/\($0.id)" } ?? (viewId != 0 ? "/projects/\(projectId)/\(viewId)" : "/projects/\(projectId)")
        if let url = URL(string: webBase + path) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Internals

    private var webBase: String { baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }

    private func loadProjects() async throws {
        let data = try await request("GET", "/projects?per_page=100")
        let items = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        projects = items.compactMap { p in
            guard let id = p["id"] as? Int, id > 0, !(p["is_archived"] as? Bool ?? false) else { return nil }
            return Project(id: id, title: p["title"] as? String ?? "#\(id)")
        }
        if projectId == 0 || !projects.contains(where: { $0.id == projectId }) {
            // ponytail: first project by default; picked properly in Settings or the board's ▾ menu.
            if let first = projects.first { selectProject(first.id) }
        }
    }

    private func resolveView() async throws {
        let data = try await request("GET", "/projects/\(projectId)/views")
        let obj = try? JSONSerialization.jsonObject(with: data)
        let items = (obj as? [String: Any])?["items"] as? [[String: Any]] ?? obj as? [[String: Any]] ?? []
        guard let kanban = items.first(where: { $0["view_kind"] as? String == "kanban" }),
              let id = kanban["id"] as? Int else { throw LoomifyError("This project has no kanban view") }
        viewId = id
        doneBucketId = kanban["done_bucket_id"] as? Int ?? 0
    }

    private func checkNotifications() async {
        guard let data = try? await request("GET", "/notifications?per_page=10"),
              let items = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]]
        else { return }
        let newestId = items.compactMap { $0["id"] as? Int }.max()
        defer { if let newestId { lastNotificationId = max(lastNotificationId ?? 0, newestId) } }
        guard let last = lastNotificationId else { return }   // first read: only remember where we are
        for n in items.reversed() {
            guard let id = n["id"] as? Int, id > last, (n["name"] as? String)?.hasPrefix("task.comment") == true,
                  Loomify.date(n["read_at"]) == nil,
                  let payload = n["notification"] as? [String: Any],
                  let task = payload["task"] as? [String: Any] else { continue }
            let who = (payload["doer"] as? [String: Any])?["name"] as? String ?? "Someone"
            announce("\(who) berkomentar di \(task["identifier"] as? String ?? "") · \(task["title"] as? String ?? "")")
        }
    }

    private func announce(_ line: String) {
        events.insert(line, at: 0)
        if events.count > 5 { events.removeLast() }
        let state = AppState.shared
        if let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }), state.focusId != Self.pillId {
            state.tasks[i].pillBadge = .news
        }
        SoundEngine.shared.play("blip")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)
        NotificationCenter.default.post(name: .hookReveal, object: nil)
    }

    private func syncTask() {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let new: BotState = overall == .failing ? .error : .idle
        if state.tasks[i].state != new { state.tasks[i].state = new }
    }

    private struct LoomifyError: Error {
        let message: String
        init(_ m: String) { message = m }
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let token = KeychainStore.shared.get(Self.tokenKey), !token.isEmpty else { throw LoomifyError("No API token") }
        guard let url = URL(string: webBase + "/api/v2" + path) else { throw LoomifyError("Invalid Loomify URL") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["detail"] as? String ?? $0["message"] as? String }
            throw LoomifyError(code == 401 ? "Token rejected (401)" : "HTTP \(code)\(detail.map { ": \($0)" } ?? "")")
        }
        return data
    }
}
#endif
