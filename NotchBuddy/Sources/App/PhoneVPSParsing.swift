import Foundation

/// Phone VPS models and the parsers for mcp-gate output (pure: tested by scripts/test-phone-vps.sh).
enum PhoneVPS {
    struct Service: Identifiable {
        let name: String
        let alive: Bool
        let port: String      // ok / tutup / -
        var id: String { name }
        var healthy: Bool { alive && port != "tutup" }
    }

    struct Site: Identifiable {
        let name: String
        let code: Int?        // nil = transport error
        let ms: Int
        var id: String { name }
        /// 530/1033 = tunnel down, 502/504 = the app on the phone; 401/403/404 still mean it answers.
        var healthy: Bool { code.map { $0 < 500 } ?? false }
    }

    struct Stats: Equatable {
        var uptime = "", load = "", ram = "", disk = ""
    }

    /// `services` prints "name\thidup|mati\tok|tutup|-" per line.
    static func parseServices(_ text: String) -> [Service] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 3 else { return nil }
            return Service(name: f[0], alive: f[1] == "hidup", port: f[2])
        }
    }

    /// `status` prints the phone clock, `uptime`, `free -m` and one `df -h` line.
    static func parseStats(_ text: String) -> Stats {
        var s = Stats()
        for line in text.split(separator: "\n").map(String.init) {
            if line.contains("load average:"), let r = line.range(of: " up ") {
                s.uptime = line[r.upperBound...].components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                s.load = line.components(separatedBy: "load average:").last?
                    .components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            } else if line.hasPrefix("Mem:") {
                let f = line.split(separator: " ").compactMap { Double($0) }
                // used = total - available (buff/cache is reclaimable)
                if f.count >= 6 { s.ram = String(format: "%.1f / %.1f GB", (f[0] - f[5]) / 1024, f[0] / 1024) }
            } else if line.hasPrefix("/") {
                let f = line.split(separator: " ")
                if f.count >= 5 { s.disk = "\(f[4]) of \(f[1])" }
            }
        }
        return s
    }
}
