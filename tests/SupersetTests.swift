import Foundation
import SQLite3

@main
enum SupersetTests {
    static var failures = 0

    static func check(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        // A trimmed copy of Superset's host.db schema with three workspaces.
        let path = NSTemporaryDirectory() + "superset-test-\(getpid()).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        let sql = """
        CREATE TABLE projects (id text, name text, deleted_at integer);
        CREATE TABLE pull_requests (id text, pr_number integer, title text, state text, checks_status text, url text);
        CREATE TABLE workspaces (id text, project_id text, name text, branch text, last_activity_at integer,
                                 updated_at integer, created_at integer, archived_at integer, pull_request_id text);
        CREATE TABLE terminal_sessions (id text, status text);
        CREATE TABLE terminal_agent_bindings (terminal_id text, workspace_id text, agent_id text,
                                              last_event_type text, last_event_at integer, ended_at integer);
        INSERT INTO projects VALUES ('p1','coucou',NULL), ('p2','loomify-web',NULL), ('p3','gone',1);
        INSERT INTO pull_requests VALUES ('pr1', 12, 'Fix', 'open', 'failure', 'https://github.com/x/y/pull/12');
        INSERT INTO workspaces VALUES
          ('w1','p1','local','main',1000,0,0,NULL,NULL),
          ('w2','p2','Run Loomify locally','redesign',2000,0,0,NULL,'pr1'),
          ('w3','p1','old','old',3000,0,0,5,NULL),
          ('w4','p3','deleted project','x',4000,0,0,NULL,NULL),
          ('w5','p1','quiet','quiet',500,0,0,NULL,NULL);
        INSERT INTO terminal_sessions VALUES ('t1','active'), ('t2','active'), ('t3','disposed'), ('t4','active'), ('t5','active');
        INSERT INTO terminal_agent_bindings VALUES
          ('t1','w1','claude','Start',1500,NULL),
          ('t2','w2','claude','PermissionRequest',2500,NULL),
          ('t3','w1','claude','Start',1600,NULL),
          ('t4','w1','codex','Stop',1700,NULL),
          ('t5','w2','claude','Start',2600,99);
        """
        check("schema created", sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let ws = Superset.load(path: path) ?? []
        check("archived and deleted-project workspaces skipped", ws.map(\.id).sorted() == ["w1", "w2", "w5"])
        check("needs-you first, then working, then no agent", ws.map(\.id) == ["w2", "w1", "w5"])
        check("disposed and ended terminals ignored", ws.first { $0.id == "w1" }?.agents.map(\.terminalId).sorted() == ["t1", "t4"])
        check("PR joined", ws.first?.pr?.number == 12 && ws.first?.pr?.checks == "failure")
        check("\"local\" shows the project name", ws.first { $0.id == "w1" }?.title == "coucou")
        check("named workspace keeps its name", ws.first?.title == "Run Loomify locally")
        check("ms timestamps", ws.first { $0.id == "w5" }?.lastActivity == Date(timeIntervalSince1970: 0.5))
        check("counts", Superset.counts(ws) == .init(working: 1, needsYou: 1, idle: 1))
        check("unknown schema → nil", Superset.load(path: "/nonexistent/host.db") == nil)

        check("first load announces nothing", Superset.transitions(from: nil, to: ws).isEmpty)
        let snap = Superset.snapshot(ws)
        check("no change → nothing", Superset.transitions(from: snap, to: ws).isEmpty)
        var later = ws
        let w1 = later.firstIndex { $0.id == "w1" }!
        later[w1].agents[later[w1].agents.firstIndex { $0.terminalId == "t1" }!] =
            .init(terminalId: "t1", agentId: "claude", status: .idle, lastEventAt: Date())
        check("working → idle is a finish", Superset.transitions(from: snap, to: later).map(\.1.terminalId) == ["t1"])
        check("new terminal already asking is announced",
              Superset.transitions(from: ["t1": .working], to: ws).map(\.1.terminalId) == ["t2"])
        check("idle → idle is not a finish", Superset.transitions(from: ["t4": .idle, "t1": .working, "t2": .needsYou], to: ws).isEmpty)

        let now = Date(timeIntervalSince1970: 100_000)
        check("ago", Superset.ago(now, now: now) == "now" && Superset.ago(now - 300, now: now) == "5m"
              && Superset.ago(now - 7200, now: now) == "2h" && Superset.ago(now - 172_800, now: now) == "2d")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("superset: ok")
    }
}
