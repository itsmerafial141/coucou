// Run with scripts/test-clipboard.sh
@main struct ClipboardKindTests {
    @MainActor static func main() {
        let cases: [(String, ClipboardStore.Kind)] = [
            ("https://github.com/x/y", .link), ("  http://a.b/c \n", .link),
            ("see https://a.b", .text), ("ftp://a.b", .text), ("https:// nope", .text),
            ("#5865F2", .color), ("#fff", .color), ("#12345", .text), ("hello", .text),
        ]
        for (s, k) in cases { precondition(ClipboardStore.kind(of: s) == k, "\(s) → \(ClipboardStore.kind(of: s)), want \(k)") }
        print("clipboard kind tests passed (\(cases.count))")
    }
}
