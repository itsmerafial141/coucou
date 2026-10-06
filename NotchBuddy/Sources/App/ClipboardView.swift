import SwiftUI

/// Island tab with the clipboard history (`ClipboardStore`): filter, search, pin, click to copy.
struct ClipboardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = ClipboardStore.shared
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var hovered: UUID?
    @State private var flashed: UUID?
    @State private var toast = false
    @FocusState private var searchFocused: Bool

    enum Filter: String, CaseIterable {
        case all = "All", pinned = "★ Pinned", text = "Text", link = "Links", image = "Images", file = "Files"
    }

    private var shown: [ClipboardStore.Item] {
        let q = query.lowercased()
        let list = store.items.filter { item in
            switch filter {
            case .all: break
            case .pinned: guard item.pinned else { return false }
            case .text: guard item.kind == .text || item.kind == .color else { return false }
            case .link: guard item.kind == .link else { return false }
            case .image: guard item.kind == .image else { return false }
            case .file: guard item.kind == .file else { return false }
            }
            return q.isEmpty || item.text.lowercased().contains(q)
        }
        return list.filter(\.pinned) + list.filter { !$0.pinned }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 7) {
                header
                chips
                strip
            }
            .padding(.leading, 84)
            .padding(.top, 9)
            .padding(.bottom, 9)

            if toast {
                Text("Copied ✓")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#86EFAC"))
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background(Color(hex: "#22C55E").opacity(0.16))
                    .overlay(Capsule().stroke(Color(hex: "#22C55E").opacity(0.45)))
                    .clipShape(Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardPick)) { note in
            guard let n = note.object as? Int else { return }
            let list = shown
            if n <= list.count { store.copy(list[n - 1]) }
        }
        .onChange(of: store.lastCopied) { _, id in
            guard let id else { return }
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            withAnimation(.easeOut(duration: 0.15)) { flashed = id }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { toast = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation(.easeIn(duration: 0.25)) { toast = false; if flashed == id { flashed = nil } }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Clipboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text("\(store.items.count) items")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 9.5, weight: .semibold))
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                }
            }
            .foregroundColor(Color(hex: "#6B7079"))
            .padding(.horizontal, 8)
            .frame(width: searchFocused || !query.isEmpty ? 180 : 140, height: 22)
            .background(Color(hex: "#0E0F11"))
            .overlay(Capsule().stroke(searchFocused ? Color(hex: "#0A84FF").opacity(0.6) : Color(hex: "#2A2C31")))
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.2), value: searchFocused)
        }
        .padding(.trailing, 12)
    }

    private var chips: some View {
        HStack(spacing: 5) {
            ForEach(Filter.allCases, id: \.self) { f in
                Button { withAnimation(.easeOut(duration: 0.18)) { filter = f } } label: {
                    Text(f.rawValue)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Color(hex: filter == f ? "#F5F6F8" : "#8E939C"))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color(hex: filter == f ? "#2A2D33" : "#1D1F23"))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(hex: "#3A3D44").opacity(filter == f ? 1 : 0)))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder private var strip: some View {
        let list = shown
        if store.items.isEmpty {
            placeholder("Nothing copied yet. Press ⌘C in any app and it shows up here.")
        } else if list.isEmpty {
            placeholder("No match")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 7) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { n, item in
                        card(item, number: n < 9 ? n + 1 : nil)
                            .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                }
                .padding(.trailing, 12)
                .padding(.vertical, 3)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: list.map(\.id))
            }
            .frame(height: 68)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(Color(hex: "#6B7079"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: "#2E3036"), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .padding(.trailing, 12)
    }

    private func card(_ item: ClipboardStore.Item, number: Int?) -> some View {
        let hover = hovered == item.id
        let flash = flashed == item.id
        return Button { store.copy(item) } label: {
            ZStack(alignment: .topLeading) {
                cardBody(item)
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        if let icon = Self.appIcon(item.appBundleId) {
                            Image(nsImage: icon).resizable().frame(width: 11, height: 11)
                        }
                        Text(Self.label(item.kind)).font(.system(size: 8.5, weight: .bold)).kerning(0.3)
                        Spacer(minLength: 2)
                        Text(Self.ago(item.date)).font(.system(size: 9))
                        if let number { Text("\(number)").font(.system(size: 8.5, design: .monospaced)).foregroundColor(Color(hex: "#4A4E55")) }
                    }
                    .foregroundColor(item.kind == .image ? .white.opacity(0.9) : Color(hex: "#6B7079"))
                    .shadow(color: item.kind == .image ? .black.opacity(0.6) : .clear, radius: 2)
                }
                .padding(.horizontal, 8).padding(.bottom, 5)
            }
            .frame(width: 118, height: 62)
            .background(Color(hex: hover ? "#131417" : "#0E0F11"))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(
                flash ? Color(hex: "#22C55E") : item.pinned ? Color(hex: "#F5B83D").opacity(0.35) : Color(hex: hover ? "#44474F" : "#2A2C31"),
                lineWidth: flash ? 1.5 : 1))
            .overlay(alignment: .topTrailing) { pinButton(item, visible: hover || item.pinned) }
            .offset(y: hover ? -2 : 0)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .help(item.kind == .image ? item.text : String(item.text.prefix(300)))
        .contextMenu {
            Button("Copy") { store.copy(item) }
            Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Button("Delete") { withAnimation { store.delete(item) } }
            Divider()
            Button("Clear all unpinned") { withAnimation { store.clearUnpinned() } }
        }
    }

    @ViewBuilder private func cardBody(_ item: ClipboardStore.Item) -> some View {
        switch item.kind {
        case .image:
            if let img = store.thumbnail(for: item) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 118, height: 62).clipped()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom))
            }
        case .color:
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7).fill(Color(hex: item.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.15)))
                    .frame(width: 24, height: 24)
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Color(hex: "#D5D8DE"))
            }
            .padding(.horizontal, 8).padding(.top, 7)
        case .file:
            HStack(alignment: .top, spacing: 6) {
                let paths = item.text.split(separator: "\n")
                Image(nsImage: NSWorkspace.shared.icon(forFile: String(paths.first ?? "")))
                    .resizable().frame(width: 20, height: 20)
                Text(paths.count > 1 ? "\(paths.count) files" : (paths.first.map { ($0 as NSString).lastPathComponent } ?? ""))
                    .font(.system(size: 10.5)).foregroundColor(Color(hex: "#D5D8DE")).lineLimit(2)
            }
            .padding(.horizontal, 8).padding(.top, 7)
        case .link, .text:
            Text(item.kind == .link ? item.text.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
                                    : item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: item.kind == .link ? "#7DB8FF" : "#D5D8DE"))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 8).padding(.top, 7).padding(.trailing, 14)
        }
    }

    private func pinButton(_ item: ClipboardStore.Item, visible: Bool) -> some View {
        Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { store.togglePin(item) } } label: {
            Image(systemName: item.pinned ? "star.fill" : "star")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(Color(hex: item.pinned ? "#F5B83D" : "#8E939C"))
                .frame(width: 17, height: 17)
                .background(item.pinned ? Color(hex: "#F5B83D").opacity(0.15) : Color(hex: "#26282D"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .padding(5)
        .opacity(visible ? 1 : 0)
        .help(item.pinned ? "Unpin" : "Pin")
    }

    // MARK: - Helpers

    private static func label(_ k: ClipboardStore.Kind) -> String {
        switch k {
        case .text: "TEXT"
        case .link: "LINK"
        case .color: "COLOR"
        case .image: "IMAGE"
        case .file: "FILE"
        }
    }

    private static func ago(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    private static var icons: [String: NSImage] = [:]
    private static func appIcon(_ bundleId: String?) -> NSImage? {
        guard let bundleId else { return nil }
        if let i = icons[bundleId] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleId] = i
        return i
    }
}
