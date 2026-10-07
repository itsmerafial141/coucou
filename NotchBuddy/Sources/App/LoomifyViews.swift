#if !APPSTORE
import SwiftUI

// MARK: - Shared bits

private let grey = Color(hex: "#6B7079"), red = Color(hex: "#F4505E")

private func columnColor(_ bucket: Loomify.Bucket, doneId: Int) -> Color {
    switch Loomify.kind(of: bucket.title, isDone: bucket.id == doneId) {
    case .todo:    return Color(hex: "#6B7079")
    case .doing:   return Color(hex: "#3B82F6")
    case .testing: return Color(hex: "#F5A524")
    case .done:    return Color(hex: "#22C55E")
    case .other:   return Color(hex: "#8E939C")
    }
}

// MARK: - Home card (focus on the Loomify pill): column counts + current card + expand

struct LoomifyCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var lf = LoomifyService.shared
    private let columns = [GridItem(.flexible(), spacing: 10, alignment: .leading),
                           GridItem(.flexible(), spacing: 10, alignment: .leading)]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: LoomifyService.colorHex)).frame(width: 7, height: 7)
                    Text(lf.projectTitle).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8")).lineLimit(1)
                    Text("Loomify").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                }
                if !lf.hasToken {
                    Text("Add the API token in Settings → Integrations").font(.system(size: 11)).foregroundColor(grey)
                } else if let err = lf.error {
                    Text(err).font(.system(size: 11)).foregroundColor(red).lineLimit(2)
                } else if lf.buckets.isEmpty {
                    Text(lf.loading ? "Loading the board…" : "No board yet").font(.system(size: 11)).foregroundColor(grey)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                        ForEach(lf.buckets.prefix(4)) { b in
                            HStack(spacing: 6) {
                                Circle().fill(columnColor(b, doneId: lf.doneBucketId)).frame(width: 6, height: 6)
                                Text(b.title).font(.system(size: 11.5)).foregroundColor(Color(hex: "#C5C8CD")).lineLimit(1)
                                Text("\(b.cards.count)").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                            }
                        }
                    }
                    if let event = lf.events.first {
                        Text("● \(event)").font(.system(size: 10.5)).foregroundColor(Color(hex: LoomifyService.colorHex)).lineLimit(1)
                    } else if let c = lf.current {
                        (Text("▸ ").foregroundColor(grey)
                         + Text(c.identifier).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundColor(Color(hex: LoomifyService.colorHex))
                         + Text(" \(c.title)").foregroundColor(Color(hex: "#8E939C")))
                            .font(.system(size: 10.5)).lineLimit(1)
                    }
                }
            }
            .padding(.leading, 108)
            .padding(.trailing, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .loomify }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .frame(width: 20, height: 20)
                    .background(Color(hex: "#1D1F23"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Open the board")
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
        .onAppear { lf.markSeen() }
    }
}

// MARK: - Detail (IslandView.loomify): kanban board

/// Mochi sits at the top of the 116pt left gutter (`.loomify` layout in IslandConst), project info below it.
struct LoomifyBoardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var lf = LoomifyService.shared
    @State private var newTitle = ""
    @State private var targeted: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            gutter
                .frame(width: 104, alignment: .leading)
                .padding(.leading, 14)
                .padding(.top, 80)
                .padding(.bottom, 12)
                .frame(maxHeight: .infinity, alignment: .top)
            board
                .padding(.leading, 116)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
        }
        .onChange(of: state.view) { _, v in if v == .loomify { lf.refresh(); lf.markSeen() } }
        .onAppear { lf.markSeen() }
    }

    private var gutter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Menu {
                ForEach(lf.projects) { p in Button(p.title) { lf.selectProject(p.id) } }
            } label: {
                Text("\(lf.projectTitle) ▾").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            let total = lf.buckets.reduce(0) { $0 + $1.cards.count }
            Text("Board · \(total) task").font(.system(size: 10)).foregroundColor(grey)
            if !lf.overdue.isEmpty {
                Text("\(lf.overdue.count) lewat due").font(.system(size: 10, weight: .semibold)).foregroundColor(red)
            }
            Button("Buka di Loomify ↗") { lf.open() }
                .font(.system(size: 10.5)).foregroundColor(Color(hex: LoomifyService.colorHex)).buttonStyle(.plain)
            Spacer(minLength: 0)
            Button(lf.loading ? "Loading…" : "Refresh") { lf.refresh() }
                .font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).buttonStyle(.plain)
        }
    }

    @ViewBuilder private var board: some View {
        if !lf.hasToken || (lf.buckets.isEmpty && lf.error != nil) {
            VStack(alignment: .leading, spacing: 6) {
                Text(lf.hasToken ? (lf.error ?? "") : "Add the Loomify URL and API token in Settings → Integrations.")
                    .font(.system(size: 11.5)).foregroundColor(lf.hasToken ? red : grey)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(lf.openBuckets.enumerated()), id: \.element.id) { i, b in
                    column(b, first: i == 0)
                }
                if let done = lf.doneBucket { doneColumn(done) }
            }
        }
    }

    private func header(_ b: Loomify.Bucket) -> some View {
        HStack(spacing: 5) {
            Circle().fill(columnColor(b, doneId: lf.doneBucketId)).frame(width: 6, height: 6)
            Text(b.title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.4).foregroundColor(grey).lineLimit(1)
            Spacer(minLength: 2)
            Text("\(b.cards.count)").font(.system(size: 9.5, weight: .semibold)).foregroundColor(Color(hex: "#8E939C"))
        }
    }

    private func column(_ b: Loomify.Bucket, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            header(b)
            if first {
                TextField("+ Tambah task", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: newTitle.isEmpty ? "#2A2D32" : LoomifyService.colorHex), style: StrokeStyle(lineWidth: 1, dash: newTitle.isEmpty ? [3] : [])))
                    .onSubmit { lf.create(newTitle); newTitle = "" }
                    .onExitCommand { newTitle = "" }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(b.cards) { CardView(card: $0, lf: lf) }
                    if targeted == b.id {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color(hex: LoomifyService.colorHex).opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3]))
                            .frame(height: 28)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in drop(items, into: b.id) } isTargeted: { targeted = $0 ? b.id : (targeted == b.id ? nil : targeted) }
    }

    private func doneColumn(_ b: Loomify.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            header(b)
            Text("Lepas kartu di sini untuk menandai selesai")
                .font(.system(size: 10)).foregroundColor(grey).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 9)
                    .stroke(targeted == b.id ? Color(hex: "#22C55E") : Color(hex: "#2A2D32"), style: StrokeStyle(lineWidth: 1, dash: [3])))
            Spacer(minLength: 0)
        }
        .frame(width: 64)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in drop(items, into: b.id) } isTargeted: { targeted = $0 ? b.id : (targeted == b.id ? nil : targeted) }
    }

    private func drop(_ items: [String], into bucketId: Int) -> Bool {
        targeted = nil
        guard let id = items.first.flatMap(Int.init),
              let card = lf.buckets.flatMap(\.cards).first(where: { $0.id == id }) else { return false }
        lf.move(card, to: bucketId)
        return true
    }
}

private struct CardView: View {
    let card: Loomify.Card
    @ObservedObject var lf: LoomifyService
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.title)
                .font(.system(size: 10.5)).foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(card.identifier).font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundColor(Color(hex: "#8E939C"))
                if let due = Loomify.dueLabel(card.due) {
                    Text(due).font(.system(size: 9.5)).foregroundColor(due.hasPrefix("telat") ? red : grey)
                }
                Spacer(minLength: 0)
                if hover {
                    arrow("chevron.left", step: -1)
                    arrow("chevron.right", step: 1)
                }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: hover ? "#201B28" : "#1B1D21")))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(hover ? Color(hex: LoomifyService.colorHex).opacity(0.55) : Color(hex: "#23262B")))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hover = $0 }
        .onTapGesture { lf.open(card) }
        .draggable("\(card.id)") {
            Text(card.title).font(.system(size: 10.5)).padding(6)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: "#201B28")))
        }
        .help("\(card.identifier) · klik untuk buka di Loomify")
    }

    @ViewBuilder private func arrow(_ icon: String, step: Int) -> some View {
        if let target = lf.neighbour(of: card, step: step) {
            Button { lf.move(card, to: target) } label: {
                Image(systemName: icon).font(.system(size: 7, weight: .bold)).foregroundColor(Color(hex: "#8E939C"))
                    .frame(width: 15, height: 15).background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: "#26292E")))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Settings (Integrations)

struct LoomifySettingsSection: View {
    @ObservedObject private var lf = LoomifyService.shared
    @State private var token = ""

    var body: some View {
        GroupBox("Loomify") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 8, height: 8)
                    Text(status).font(.system(size: 12))
                }
                TextField("Loomify URL (mis. http://localhost:4173)", text: $lf.baseURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    SecureField(lf.hasToken ? "API token tersimpan di Keychain" : "API token (tk_…)", text: $token)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { lf.setToken(token); token = "" }.disabled(token.isEmpty)
                }
                if !lf.projects.isEmpty {
                    Picker("Project", selection: Binding(get: { lf.projectId }, set: { lf.selectProject($0) })) {
                        ForEach(lf.projects) { Text($0.title).tag($0.id) }
                    }
                }
                Text("Coucou membaca board kanban project ini, memindahkan kartu dan membuat task atas klikmu. Token dibuat di Loomify → Settings → API Tokens.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Divider()
                Text("Webhook (update instan)").font(.system(size: 12, weight: .semibold))
                copyRow("Endpoint", lf.webhookURL)
                copyRow("Secret", lf.webhookSecret, masked: true)
                Text("Buka tunnel ke endpoint ini (mis. cloudflared tunnel --url \(lf.webhookURL.replacingOccurrences(of: "/loomify", with: ""))), lalu di Loomify → project → ⋯ → Webhooks isi Target URL https://<tunnel>/loomify, Secret di atas, dan centang semua event task. Tanpa webhook, Coucou tetap cek tiap 60 dtk.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                if let t = lf.lastWebhook {
                    Text("Event terakhir: \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(6)
        }
    }

    private func copyRow(_ label: String, _ value: String, masked: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
            Text(masked ? String(repeating: "•", count: 16) : value)
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
        }
    }

    private var dot: Color {
        switch lf.overall {
        case .ok, .news: return Color(hex: "#22C55E")
        case .failing:   return lf.error != nil ? Color(hex: "#F4505E") : Color(hex: "#F5A524")
        case .off:       return Color(hex: "#6B7079")
        }
    }

    private var status: String {
        if !lf.hasToken { return "Belum ada API token" }
        if !lf.isPillActive { return "Aktifkan pill Loomify di Active pills" }
        if let e = lf.error { return "Gagal: \(e)" }
        return lf.buckets.isEmpty ? "Menghubungkan…" : "Tersambung · \(lf.projectTitle)"
    }
}
#endif
