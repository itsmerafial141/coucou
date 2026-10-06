import Foundation

/// One line of synced lyrics (LRC format, as served by LRCLIB).
struct LRCLine: Equatable, Sendable {
    let time: Double
    let text: String

    /// "[mm:ss.xx] text" lines → lines sorted by time; untimed, metadata and empty lines are dropped.
    static func parse(_ lrc: String) -> [LRCLine] {
        lrc.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let stamp = line[line.index(after: line.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1]) else { return nil }
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : LRCLine(time: m * 60 + s, text: text)
        }.sorted { $0.time < $1.time }
    }
}
