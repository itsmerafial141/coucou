import Foundation

@main
enum LRCLineTests {
    static var failures = 0

    static func check(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        let lines = LRCLine.parse("""
            [ar: Mahalini]
            [00:12.50] Second
            [00:03.00] First
            [00:20.00]
            no stamp here
            [01:02.25]  Third
            """)
        check("keeps the 3 timed lines with text", lines.count == 3)
        check("sorted by time", lines.map(\.text) == ["First", "Second", "Third"])
        check("mm:ss.xx → seconds", lines.last?.time == 62.25)
        check("metadata tag is dropped", !lines.contains { $0.text.contains("Mahalini") })
        check("empty input → no lines", LRCLine.parse("").isEmpty)
        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All LRC tests passed")
    }
}
