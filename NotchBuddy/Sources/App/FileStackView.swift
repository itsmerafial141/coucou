import AppKit
import SwiftUI

// MARK: - File stack
//
// Dropped files shown as a small pile of sheets. Drag the closed pile → every file
// lands at once; click it → it fans out into cards, and each card drags one file.
// Click a card (without dragging) folds it back.

struct FileStackView: View {
    let files: [URL]
    /// Extra right-click items for each file (e.g. the shelf's Ask / Remove).
    var menu: ((URL) -> [FileMenuItem])? = nil
    /// Files that landed somewhere else (drop accepted). Callers clear them.
    var onDropped: (([URL]) -> Void)? = nil
    @State private var open = false

    var body: some View {
        Group {
            if open && files.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(files.enumerated()), id: \.element) { i, url in
                            card(url)
                                .overlay(FileDragSource(
                                    files: FileStackLogic.dragged(files, open: true, index: i),
                                    menu: menuItems(url),
                                    onDropped: dropped,
                                    onClick: { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { open = false } }))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
            } else {
                pile
                    .overlay(FileDragSource(
                        files: files,
                        menu: files.count == 1 ? menuItems(files[0]) : [],
                        onDropped: dropped,
                        onClick: files.count > 1
                            ? { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { open = true } }
                            : nil))
                    .help(files.count > 1 ? "Drag to drop all · click to pick one" : files.first?.lastPathComponent ?? "")
            }
        }
    }

    private var pile: some View {
        let shown = FileStackLogic.visible(files)
        return VStack(spacing: 6) {
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element) { i, url in
                    FileIcon(url: url, size: 40)
                        .rotationEffect(.degrees(FileStackLogic.angle(index: i, count: shown.count)), anchor: .bottom)
                        .offset(x: FileStackLogic.angle(index: i, count: shown.count))
                        .shadow(color: .black.opacity(0.55), radius: 5, y: 4)
                }
            }
            .frame(width: 84, height: 54)
            Text(files.count == 1 ? files[0].lastPathComponent : FileStackLogic.label(files.count))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Color(hex: "#F1F2F4"))
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
                .frame(maxWidth: 140)
        }
        .contentShape(Rectangle())
    }

    private func card(_ url: URL) -> some View {
        VStack(spacing: 4) {
            FileIcon(url: url, size: 34)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 3)
            Text(url.lastPathComponent)
                .font(.system(size: 9.5))
                .foregroundColor(Color(hex: "#B9BDC4"))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 58)
        }
        .padding(.horizontal, 3).padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func menuItems(_ url: URL) -> [FileMenuItem] { menu?(url) ?? [] }

    private func dropped(_ urls: [URL]) {
        if files.count - urls.count <= 1 { open = false }
        onDropped?(urls)
    }
}

private struct FileIcon: View {
    let url: URL
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct FileMenuItem {
    let title: String
    let action: () -> Void
}

// MARK: - AppKit drag source (one drag session carrying any number of files)

struct FileDragSource: NSViewRepresentable {
    let files: [URL]
    var menu: [FileMenuItem] = []
    var onDropped: (([URL]) -> Void)?
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ v: DragSourceView, context: Context) {
        v.files = files
        v.menuItems = menu
        v.onDropped = onDropped
        v.onClick = onClick
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var files: [URL] = []
        var menuItems: [FileMenuItem] = []
        var onDropped: (([URL]) -> Void)?
        var onClick: (() -> Void)?
        private var downAt: NSPoint?
        private var dragging: [URL] = []

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow }
        override func mouseUp(with e: NSEvent) {
            if downAt != nil { onClick?() }
            downAt = nil
        }
        override func mouseDragged(with e: NSEvent) {
            guard let start = downAt, !files.isEmpty,
                  hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > 3 else { return }
            downAt = nil
            dragging = files
            let p = convert(e.locationInWindow, from: nil)
            let items = files.enumerated().map { i, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                // Fan the drag images slightly so the pile reads as several files.
                let o = CGFloat(min(i, 4)) * 5
                item.setDraggingFrame(NSRect(x: p.x - 20 + o, y: p.y - 20 - o, width: 40, height: 40), contents: icon)
                return item
            }
            let session = beginDraggingSession(with: items, event: e, source: self)
            session.draggingFormation = .pile
        }

        // Copy, never move: the originals stay where they were.
        func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }

        // Accepted somewhere (operation != none) → the files have been delivered.
        func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
            let delivered = dragging
            dragging = []
            if !operation.isEmpty, !delivered.isEmpty { onDropped?(delivered) }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard !menuItems.isEmpty else { return nil }
            let m = NSMenu()
            for item in menuItems {
                let mi = NSMenuItem(title: item.title, action: #selector(run(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = item.action
                m.addItem(mi)
            }
            return m
        }
        @objc private func run(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
    }
}
