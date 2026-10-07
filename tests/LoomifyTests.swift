import Foundation

@main
enum LoomifyTests {
    static var failures = 0

    static func check(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        let json = """
        {"items":[
          {"id":146,"title":"To-Do","tasks":[{"id":49,"identifier":"#9","title":"Superset","due_date":"2026-10-07T16:59:00Z","done":false}]},
          {"id":147,"title":"Doing","tasks":[{"id":47,"identifier":"#8","title":"Loomify","due_date":"0001-01-01T00:00:00Z","done":false}]},
          {"id":149,"title":"Testing","tasks":null},
          {"id":148,"title":"Done","tasks":[{"id":48,"identifier":"#7","title":"Grid","due_date":"2026-10-01T10:00:00Z","done":true}]}
        ],"total":4}
        """.data(using: .utf8)!
        let buckets = Loomify.parseBuckets(json) ?? []
        check("four buckets in board order", buckets.map(\.id) == [146, 147, 149, 148])
        check("null tasks → empty column", buckets.count > 2 && buckets[2].cards.isEmpty)
        check("0001 date means no due", buckets.count > 1 && buckets[1].cards.first?.due == nil)
        check("due date parsed", buckets.first?.cards.first?.due != nil)

        let now = ISO8601DateFormatter().date(from: "2026-10-08T00:00:00Z")!
        let late = Loomify.overdue(buckets, doneBucketId: 148, now: now)
        check("overdue skips the done bucket", late.map(\.id) == [49])

        check("first load announces nothing", Loomify.newCards(in: buckets, seen: nil).isEmpty)
        check("new To-Do card detected", Loomify.newCards(in: buckets, seen: [47, 48]).map(\.id) == [49])
        check("known card not repeated", Loomify.newCards(in: buckets, seen: [49]).isEmpty)

        check("kinds", Loomify.kind(of: "Doing") == .doing && Loomify.kind(of: "QA") == .testing
              && Loomify.kind(of: "To-Do") == .todo && Loomify.kind(of: "Whatever", isDone: true) == .done)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = { (s: String) in ISO8601DateFormatter().date(from: s)! }
        check("late label", Loomify.dueLabel(d("2026-10-07T21:00:00Z"), now: now, calendar: cal) == "telat 3j")
        check("today label", Loomify.dueLabel(d("2026-10-08T20:00:00Z"), now: now, calendar: cal) == "hari ini")
        check("tomorrow label", Loomify.dueLabel(d("2026-10-09T09:00:00Z"), now: now, calendar: cal) == "besok")
        check("days label", Loomify.dueLabel(d("2026-10-11T09:00:00Z"), now: now, calendar: cal) == "3 hr")
        check("no due → nil", Loomify.dueLabel(nil, now: now) == nil)

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("loomify: ok")
    }
}
