import Foundation

/// Pure rules of the file stack (no UI): what is drawn and what a drag carries.
enum FileStackLogic {
    static let maxVisible = 3

    /// Files drawn in the closed stack, top of the pile last.
    static func visible(_ files: [URL]) -> [URL] { Array(files.prefix(maxVisible)) }

    /// Tilt of each visible sheet, fanned around the middle one; a lone file stays straight.
    static func angle(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        let mid = Double(count - 1) / 2
        return (Double(index) - mid) * (20 / Double(max(count - 1, 1)))
    }

    static func label(_ count: Int) -> String {
        count == 1 ? "drag out" : "\(count) files · drag all"
    }

    /// Upload label for a drop of several files: walks through them as the bar fills.
    static func uploadLabel(_ names: [String], progress: Double) -> String {
        guard names.count > 1 else { return "Uploading \(names.first ?? "file")" }
        let i = min(names.count - 1, max(0, Int(progress * Double(names.count))))
        return "Uploading \(names[i]) · \(i + 1)/\(names.count)"
    }

    /// A closed stack drags every file; an open stack drags only the sheet you grab.
    static func dragged(_ files: [URL], open: Bool, index: Int) -> [URL] {
        open && files.indices.contains(index) ? [files[index]] : files
    }
}
