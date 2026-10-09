import Foundation
import SQLite3

/// Superset (superset.sh) workspaces and agents, read from the host service's local SQLite database
/// (`~/.superset/host/<org>/host.db`), read-only. Pure logic behind the Superset pill, tested by
/// scripts/test-superset.sh. ponytail: Superset's private schema; a schema change makes `load` return nil
/// and the pill says so instead of crashing. Switch to `superset ws list --json` if that gets frequent.
enum Superset {
    /// Ordered by how much it needs the user: a workspace shows its most urgent agent.
    enum Status: Int, Comparable {
        case idle, working, needsYou
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    struct Agent: Equatable {
        let terminalId: String
        let agentId: String        // "claude", "codex", …
        let status: Status
        let lastEventAt: Date
    }

    struct PullRequest: Equatable {
        let number: Int
        let title: String
        let state: String          // open, merged, closed
        let checks: String         // success, failure, pending, none
        let url: String
    }

    struct Workspace: Identifiable, Equatable {
        let id: String
        let project: String
        let name: String
        let branch: String
        let lastActivity: Date
        var agents: [Agent]
        let pr: PullRequest?

        var status: Status? { agents.map(\.status).max() }
        /// Superset names a repo's main checkout "local": show the project instead.
        var title: String { name.isEmpty || name == "local" || name == branch ? project : name }
        var active: Date { max(lastActivity, agents.map(\.lastEventAt).max() ?? .distantPast) }
    }

    /// Agent lifecycle events as normalised by Superset's notify hook.
    static func status(of event: String) -> Status {
        switch event {
        case "Start": return .working
        case "PermissionRequest": return .needsYou
        default: return .idle     // Stop, StopFailure, Attached, …
        }
    }

    /// The first host database under `~/.superset/host/` (one per organisation).
    static func defaultDBPath(home: String = NSHomeDirectory()) -> String? {
        let dir = home + "/.superset/host"
        let orgs = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return orgs.sorted().map { "\(dir)/\($0)/host.db" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Non-archived workspaces with their live agents and linked PR, most urgent then most recent first.
    /// nil when the database can't be opened or its schema is not the one we know.
    static func load(path: String) -> [Workspace]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        let wsSQL = """
            SELECT w.id, COALESCE(p.name, ''), w.name, w.branch, COALESCE(w.last_activity_at, w.updated_at, w.created_at),
                   pr.pr_number, pr.title, pr.state, pr.checks_status, pr.url
            FROM workspaces w
            LEFT JOIN projects p ON p.id = w.project_id
            LEFT JOIN pull_requests pr ON pr.id = w.pull_request_id
            WHERE w.archived_at IS NULL AND p.deleted_at IS NULL
            """
        guard var workspaces = rows(db, wsSQL, { s in
            Workspace(id: text(s, 0), project: text(s, 1), name: text(s, 2), branch: text(s, 3),
                      lastActivity: date(s, 4), agents: [],
                      pr: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil
                          : PullRequest(number: Int(sqlite3_column_int64(s, 5)), title: text(s, 6),
                                        state: text(s, 7), checks: text(s, 8), url: text(s, 9)))
        }) else { return nil }

        let agentSQL = """
            SELECT b.workspace_id, b.terminal_id, b.agent_id, b.last_event_type, b.last_event_at
            FROM terminal_agent_bindings b JOIN terminal_sessions t ON t.id = b.terminal_id
            WHERE b.ended_at IS NULL AND t.status = 'active'
            """
        guard let agents = rows(db, agentSQL, { s in
            (text(s, 0), Agent(terminalId: text(s, 1), agentId: text(s, 2), status: status(of: text(s, 3)), lastEventAt: date(s, 4)))
        }) else { return nil }

        let byWorkspace = Dictionary(grouping: agents, by: \.0)
        for i in workspaces.indices { workspaces[i].agents = byWorkspace[workspaces[i].id]?.map(\.1) ?? [] }
        return sorted(workspaces)
    }

    static func sorted(_ ws: [Workspace]) -> [Workspace] {
        ws.sorted { a, b in
            let ra = a.status?.rawValue ?? -1, rb = b.status?.rawValue ?? -1
            return ra != rb ? ra > rb : a.active > b.active
        }
    }

    struct Counts: Equatable { var working = 0, needsYou = 0, idle = 0 }

    static func counts(_ ws: [Workspace]) -> Counts {
        ws.flatMap(\.agents).reduce(into: Counts()) { c, a in
            switch a.status {
            case .working: c.working += 1
            case .needsYou: c.needsYou += 1
            case .idle: c.idle += 1
            }
        }
    }

    /// Agents that just started needing the user, or just finished a turn (working → idle), since the
    /// previous load. Empty on the first load (`previous` nil) so opening the pill doesn't ring.
    static func transitions(from previous: [String: Status]?, to ws: [Workspace]) -> [(Workspace, Agent)] {
        guard let previous else { return [] }
        return ws.flatMap { w in w.agents.map { (w, $0) } }.filter { _, a in
            let before = previous[a.terminalId]
            if a.status == .needsYou { return before != .needsYou }
            return a.status == .idle && before == .working
        }
    }

    static func snapshot(_ ws: [Workspace]) -> [String: Status] {
        Dictionary(ws.flatMap(\.agents).map { ($0.terminalId, $0.status) }, uniquingKeysWith: { a, _ in a })
    }

    /// "now", "5m", "3h", "2d".
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    // MARK: - Terminal prompt (an agent asking for a choice)

    struct Prompt: Equatable {
        struct Option: Equatable { let key: String; let label: String }
        let question: String
        let detail: [String]       // tool / command lines shown above the question
        let options: [Option]
        /// Claude's question picker ("Enter to select") moves to the digit and waits for Enter.
        var submit = false
    }

    /// The numbered choice an agent is waiting on, read from the bottom of its terminal screen.
    /// Claude Code, Codex and Gemini all draw "1. Yes / 2. … / 3. No" and take the digit as the answer.
    /// ponytail: screen scraping; nil when no 1…n block sits in the last 30 lines.
    static func prompt(fromScreen screen: String) -> Prompt? {
        let frame = CharacterSet(charactersIn: "│┃║╭╮╰╯")
        let lines = screen.replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: "\n").suffix(30)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: frame).trimmingCharacters(in: .whitespaces) }
        func option(_ line: String) -> Prompt.Option? {
            let markers = CharacterSet(charactersIn: "❯›>●○▌▸*").union(.whitespaces)
            let l = String(line.unicodeScalars.drop { markers.contains($0) })
            guard let dot = l.firstIndex(where: { $0 == "." || $0 == ")" }),
                  let n = Int(l[..<dot]), (1...9).contains(n) else { return nil }
            let label = l[l.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? nil : Prompt.Option(key: String(n), label: label)
        }
        // The last "1." whose following options run 2, 3, … without a gap.
        guard let first = lines.indices.last(where: { option(lines[$0])?.key == "1" }) else { return nil }
        var options: [Prompt.Option] = []
        // Lines between options are their descriptions (Claude's question picker); a rule ends the block.
        for line in lines[first...] {
            if line.unicodeScalars.filter({ "─━═".unicodeScalars.contains($0) }).count > 8 { break }
            guard let o = option(line) else { continue }
            guard o.key == String(options.count + 1) else { break }
            options.append(o)
        }
        guard options.count >= 2 else { return nil }
        // Context: the non-empty lines just above the options, up to a rule, an older list or 4 lines.
        var above: [String] = []
        for line in lines[..<first].reversed() {
            if line.unicodeScalars.contains(where: { "─━═".unicodeScalars.contains($0) }) && line.count > 8 { break }
            if option(line) != nil { break }
            if line.isEmpty { continue }
            above.insert(line, at: 0)
            if above.count == 4 { break }
        }
        let question = above.popLast() ?? "Choose an option"
        let submit = lines[first...].contains { $0.contains("Enter to select") }
        // The picker's free-text choice needs typing: the chat field covers it.
        if submit { options.removeAll { $0.label.hasPrefix("Type something") } }
        return Prompt(question: question, detail: above, options: options, submit: submit)
    }

    /// One line of the chat read from a Claude screen: the user's "❯" prompt or the agent's "⏺" line.
    struct Turn: Equatable { let mine: Bool; let text: String }

    /// The conversation on a Claude agent's screen: the user's prompts ("❯", or "> " in older versions)
    /// and the agent's "⏺" lines (messages and tool calls) with their wrapped continuation, without tool
    /// output, boxes, the input box or the status line; the last `limit`. Empty for other agents.
    static func turns(fromScreen screen: String, limit: Int = 8, maxLength: Int = 140) -> [Turn] {
        var turns: [Turn] = []
        var current: Turn?
        var previous = ""
        for raw in screen.replacingOccurrences(of: "\u{00A0}", with: " ").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            defer { previous = line }
            let prompt = (line.hasPrefix("❯ ") || line.hasPrefix("> "))
                && previous.filter({ "─━═".contains($0) }).count <= 8           // the input box sits under a rule
                && line.dropFirst(2).range(of: #"^\d+\."#, options: .regularExpression) == nil   // picker choice
            if line.hasPrefix("⏺") || prompt {
                if let c = current { turns.append(c) }
                current = Turn(mine: prompt, text: line.dropFirst(prompt ? 2 : 1).trimmingCharacters(in: .whitespaces))
            } else if let c = current, raw.hasPrefix("  "), !line.isEmpty, !line.hasPrefix("⎿") {
                current = Turn(mine: c.mine, text: c.text + " " + line)
            } else if let c = current {
                turns.append(c)
                current = nil
            }
        }
        if let c = current { turns.append(c) }
        return turns.filter { !$0.text.isEmpty }.suffix(limit)
            .map { Turn(mine: $0.mine, text: $0.text.count > maxLength ? String($0.text.prefix(maxLength - 1)) + "…" : $0.text) }
    }

    /// The agent's latest output for the notch chat: the end of its screen without the input box and
    /// status lines agents draw at the bottom (everything from the first rule in the last 8 lines).
    /// ponytail: screen scraping, so a reply is whatever the terminal shows, box drawing included.
    /// `asking`: keep the bottom too, since that is where the agent draws its question.
    static func screenTail(_ screen: String, lines limit: Int = 12, asking: Bool = false) -> String {
        func isRule(_ l: String) -> Bool {
            l.hasPrefix("╭") || l.hasPrefix("╰") || l.filter { "─━═".contains($0) }.count > 8
        }
        var lines = screen.replacingOccurrences(of: "\u{00A0}", with: " ").components(separatedBy: "\n")
            .map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let window = max(0, lines.count - 8)
        if !asking, let cut = lines[window...].firstIndex(where: { isRule($0.trimmingCharacters(in: .whitespaces)) }) {
            lines.removeSubrange(cut...)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let tail = lines.suffix(limit).drop { $0.isEmpty }
        return tail.joined(separator: "\n")
    }

    // MARK: - SQLite helpers

    private static func rows<T>(_ db: OpaquePointer?, _ sql: String, _ map: (OpaquePointer?) -> T) -> [T]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { return nil }
            out.append(map(stmt))
        }
    }

    private static func text(_ s: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    /// Superset stores epoch milliseconds.
    private static func date(_ s: OpaquePointer?, _ i: Int32) -> Date {
        Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, i)) / 1000)
    }
}
