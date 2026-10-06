import Foundation

// swiftc -parse-as-library NotchBuddy/Sources/App/FileStackLogic.swift tests/FileStackTests.swift -o /tmp/fs && /tmp/fs
@main
enum FileStackTests {
    static func main() {
        let f = (1...5).map { URL(fileURLWithPath: "/tmp/f\($0).svg") }

        precondition(FileStackLogic.visible(f).count == 3, "closed stack shows at most 3")
        precondition(FileStackLogic.visible(Array(f.prefix(2))).count == 2)

        precondition(FileStackLogic.angle(index: 0, count: 1) == 0, "single file is straight")
        precondition(FileStackLogic.angle(index: 0, count: 3) == -10)
        precondition(FileStackLogic.angle(index: 1, count: 3) == 0)
        precondition(FileStackLogic.angle(index: 2, count: 3) == 10)

        precondition(FileStackLogic.dragged(f, open: false, index: 2) == f, "closed: drag all")
        precondition(FileStackLogic.dragged(f, open: true, index: 2) == [f[2]], "open: drag one")
        precondition(FileStackLogic.dragged(f, open: true, index: 9) == f, "bad index falls back to all")

        precondition(FileStackLogic.label(1) == "drag out")
        precondition(FileStackLogic.label(5) == "5 files · drag all")
        let n = ["a.svg", "b.svg", "c.svg"]
        precondition(FileStackLogic.uploadLabel(["a.svg"], progress: 0.5) == "Uploading a.svg")
        precondition(FileStackLogic.uploadLabel(n, progress: 0) == "Uploading a.svg · 1/3")
        precondition(FileStackLogic.uploadLabel(n, progress: 0.5) == "Uploading b.svg · 2/3")
        precondition(FileStackLogic.uploadLabel(n, progress: 1) == "Uploading c.svg · 3/3", "full bar stays on last")
        print("FileStack: all cases passed")
    }
}
