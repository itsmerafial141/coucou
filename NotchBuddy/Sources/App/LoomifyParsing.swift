import CryptoKit
import Foundation

/// Loomify board models and the pure logic behind the Loomify pill (tested by scripts/test-loomify.sh).
enum Loomify {
    struct Card: Identifiable, Equatable {
        let id: Int
        let identifier: String    // "#8"
        let title: String
        let due: Date?
        let done: Bool
    }

    struct Bucket: Identifiable, Equatable {
        let id: Int
        let title: String
        var cards: [Card]
    }

    enum Kind { case todo, doing, testing, done, other }

    /// Same title lists as the loomify-start skill, so the pill and the board agree on what a column means.
    static func kind(of title: String, isDone: Bool = false) -> Kind {
        if isDone { return .done }
        switch title.lowercased().trimmingCharacters(in: .whitespaces) {
        case "to-do", "todo", "to do", "backlog": return .todo
        case "ongoing", "in progress", "doing", "wip", "on progress", "dikerjakan": return .doing
        case "testing", "qa", "review", "in review", "to test": return .testing
        case "done", "selesai": return .done
        default: return .other
        }
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Loomify sends "0001-01-01T00:00:00Z" for "no date".
    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String, !s.hasPrefix("0001-") else { return nil }
        return iso.date(from: s) ?? isoFrac.date(from: s)
    }

    /// `GET /projects/{p}/views/{v}/buckets/tasks` → buckets in board order.
    static func parseBuckets(_ data: Data) -> [Bucket]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let items = (obj as? [String: Any])?["items"] as? [[String: Any]] ?? obj as? [[String: Any]]
        else { return nil }
        return items.compactMap { b in
            guard let id = b["id"] as? Int else { return nil }
            let cards = (b["tasks"] as? [[String: Any]] ?? []).compactMap { t -> Card? in
                guard let tid = t["id"] as? Int else { return nil }
                return Card(id: tid,
                            identifier: t["identifier"] as? String ?? "#\(t["index"] as? Int ?? tid)",
                            title: t["title"] as? String ?? "",
                            due: date(t["due_date"]),
                            done: t["done"] as? Bool ?? false)
            }
            return Bucket(id: id, title: b["title"] as? String ?? "", cards: cards)
        }
    }

    /// Open cards past their due date (cards in the done bucket never count).
    static func overdue(_ buckets: [Bucket], doneBucketId: Int, now: Date = Date()) -> [Card] {
        buckets.filter { $0.id != doneBucketId }
            .flatMap(\.cards)
            .filter { !$0.done && ($0.due.map { $0 < now } ?? false) }
    }

    /// Cards that showed up in the first (To-Do) bucket since the previous load. Empty on the first load.
    static func newCards(in buckets: [Bucket], seen: Set<Int>?) -> [Card] {
        guard let seen, let first = buckets.first else { return [] }
        return first.cards.filter { !seen.contains($0.id) }
    }

    /// Short due label for a card: "telat 2j", "hari ini", "besok", "3 hr", "12 Okt".
    static func dueLabel(_ due: Date?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let due else { return nil }
        if due < now {
            let h = Int(now.timeIntervalSince(due) / 3600)
            return h < 24 ? "telat \(max(1, h))j" : "telat \(h / 24)hr"
        }
        if calendar.isDate(due, inSameDayAs: now) { return "hari ini" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: t) { return "besok" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        if days < 7 { return "\(days) hr" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = "d MMM"
        return f.string(from: due)
    }

    // MARK: - Webhook (project webhook → Coucou's local listener)

    struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]   // lowercased names
        let body: Data
    }

    /// One HTTP/1.1 request from raw bytes; nil until the headers and the Content-Length body are all in.
    static func parseHTTP(_ raw: Data) -> HTTPRequest? {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: raw[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let body = raw[split.upperBound...]
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    /// Loomify signs the body with HMAC-SHA256 (hex) in an `X-…-Signature` header.
    static func validSignature(_ req: HTTPRequest, secret: String) -> Bool {
        guard !secret.isEmpty,
              let sig = req.headers.first(where: { $0.key.hasSuffix("-signature") })?.value.lowercased() else { return false }
        let mac = HMAC<SHA256>.authenticationCode(for: req.body, using: SymmetricKey(data: Data(secret.utf8)))
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        // Constant-time compare.
        return sig.utf8.count == hex.utf8.count && zip(sig.utf8, hex.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    struct WebhookEvent: Equatable {
        let name: String
        let taskId: Int?
        let doerId: Int?
        let line: String
    }

    /// `{"event_name":"task.updated","data":{"task":{…},"doer":{…},"comment":{…}}}` → one notch line.
    static func parseWebhook(_ body: Data) -> WebhookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = obj["event_name"] as? String else { return nil }
        let data = obj["data"] as? [String: Any] ?? [:]
        let task = data["task"] as? [String: Any]
        let doer = data["doer"] as? [String: Any]
        let who = (doer?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? doer?["username"] as? String ?? "Seseorang"
        let verb: String
        switch name {
        case "task.created":           verb = "membuat"
        case "task.updated":           verb = "mengubah"
        case "task.deleted":           verb = "menghapus"
        case "task.comment.created":   verb = "berkomentar di"
        case "task.comment.edited":    verb = "mengedit komentar di"
        case "task.comment.deleted":   verb = "menghapus komentar di"
        case "task.assignee.created":  verb = "menugaskan"
        case "task.assignee.deleted":  verb = "melepas penugasan"
        case "task.attachment.created": verb = "melampirkan file di"
        case "task.attachment.deleted": verb = "menghapus lampiran di"
        case "task.relation.created", "task.relation.deleted": verb = "mengubah relasi"
        case "task.overdue":           verb = "telat:"
        case "task.reminder.fired":    verb = "pengingat:"
        default:                       verb = name
        }
        let subject = task.map { t in
            let id = t["identifier"] as? String ?? (t["index"] as? Int).map { "#\($0)" } ?? ""
            return " \(id) · \(t["title"] as? String ?? "")"
        } ?? ""
        let automatic = name.hasSuffix("overdue") || name == "task.reminder.fired"
        return WebhookEvent(name: name, taskId: task?["id"] as? Int, doerId: doer?["id"] as? Int,
                            line: (automatic ? verb : "\(who) \(verb)") + subject)
    }
}
