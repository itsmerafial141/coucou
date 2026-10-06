#if !APPSTORE
import SwiftUI

// MARK: - Shared bits

private func healthColor(_ h: VenturoBotMonitor.Health) -> Color {
    switch h {
    case .ok:      return Color(hex: "#22C55E")
    case .busy:    return Color(hex: "#F5A524")
    case .failing: return Color(hex: "#F4505E")
    case .off:     return Color(hex: "#6B7079")
    }
}

private func shortDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM HH:mm"
    return f.string(from: d)
}

private struct StatusRow: View {
    let label: String
    let health: VenturoBotMonitor.Health
    var note: String? = nil
    var onFix: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(healthColor(health)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11.5)).foregroundColor(Color(hex: "#C5C8CD")).lineLimit(1)
            if health == .failing, let onFix {
                Spacer(minLength: 4)
                Button(action: onFix) {
                    Text("Perbaiki")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Color(hex: "#F4505E").opacity(0.22))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#F4505E").opacity(0.5)))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else if let note {
                Spacer(minLength: 4)
                Text(note).font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079")).lineLimit(1)
            }
        }
    }
}

// MARK: - Home card (focus on the Venturo Bot pill): connection dots + expand

struct VenturoCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var bot = VenturoBotMonitor.shared
    private let columns = [GridItem(.flexible(), spacing: 12, alignment: .leading),
                           GridItem(.flexible(), spacing: 12, alignment: .leading)]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                StatusRow(label: "Discord", health: bot.discord)
                StatusRow(label: "MCP", health: bot.mcp)
                StatusRow(label: "Claude", health: bot.claude)
                StatusRow(label: "Harian", health: bot.daily)
                StatusRow(label: "Weekly", health: bot.weekly)
                StatusRow(label: "Listener", health: bot.listener)
            }
            .padding(.leading, 108)
            .padding(.trailing, 36)
            .frame(maxHeight: .infinity)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .venturo }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .frame(width: 20, height: 20)
                    .background(Color(hex: "#1D1F23"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Details")
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
    }
}

// MARK: - Detail (IslandView.venturo)

/// Mochi sits in the left gutter: the `.venturo` layout in IslandConst matches the 116pt inset.
struct VenturoDetailView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var bot = VenturoBotMonitor.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            if let fix = bot.fix {
                FixPanel(fix: fix, bot: bot)
                    .padding(.leading, 116)
                    .padding(.trailing, 14)
                    .padding(.vertical, 12)
                    .transition(.opacity)
                if fix.outcome == nil { RepairOverlay() }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 16) {
                        connections.frame(maxWidth: .infinity, alignment: .leading)
                        activity.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 14) {
                        link("Open Venturo Bot", primary: true) { bot.openApp() }
                        link("Last thread") { bot.openLastThread() }
                        link("Open log") { bot.openLog() }
                    }
                }
                .padding(.leading, 116)
                .padding(.trailing, 14)
                .padding(.vertical, 12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: bot.fix == nil)
        .onChange(of: state.view) { _, v in if v == .venturo { bot.reload() } }
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 4) {
            section("Connection")
            StatusRow(label: "Discord", health: bot.discord,
                      note: bot.currentVerb.map { "\($0)…" } ?? bot.since.map { "since \(shortDate($0))" },
                      onFix: { bot.troubleshoot(.discord) })
            StatusRow(label: "MCP Space", health: bot.mcp, onFix: { bot.troubleshoot(.mcp) })
            StatusRow(label: "Claude", health: bot.claude, onFix: { bot.troubleshoot(.claude) })
            StatusRow(label: "Harian", health: bot.daily, note: bot.dailyTime, onFix: { bot.troubleshoot(.daily) })
            StatusRow(label: "Weekly", health: bot.weekly, onFix: { bot.troubleshoot(.weekly) })
            StatusRow(label: "Listener", health: bot.listener, onFix: { bot.troubleshoot(.listener) })
            if let err = bot.lastError {
                Text("\(shortDate(err.date)) · \(err.text)")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#F4505E"))
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 4) {
            section("Recent tasks")
            if bot.runs.isEmpty {
                Text("No runs yet").font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079"))
            }
            ForEach(bot.runs.prefix(3)) { run in
                Button { bot.openThread(of: run) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: run.created ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5))
                            .foregroundColor(Color(hex: run.created ? "#22C55E" : "#F5A524"))
                        if let code = run.code {
                            Text(code).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(hex: "#9BD15F"))
                        }
                        Text(run.title).font(.system(size: 10.5))
                            .foregroundColor(Color(hex: run.created ? "#8E939C" : "#F4505E"))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            section("Usage report").padding(.top, 6)
            Text(bot.lastDaily.map { "Daily sent \(shortDate($0))" } ?? "Daily not sent yet")
                .font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
            Text(bot.lastWeekly.map { "Weekly alert \($0.text) · \(shortDate($0.date))" } ?? "No weekly alert")
                .font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.4)
            .foregroundColor(Color(hex: "#6B7079"))
    }

    private func link(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: primary ? .medium : .regular))
            .foregroundColor(primary ? Color(hex: "#0E9BAD") : Color(hex: "#8E939C"))
            .buttonStyle(.plain)
    }
}
// MARK: - Troubleshooting panel

private struct FixPanel: View {
    let fix: VenturoBotMonitor.FixState
    @ObservedObject var bot: VenturoBotMonitor

    private var title: String {
        switch fix.target {
        case .discord: return "Memperbaiki Discord"
        case .listener: return "Memperbaiki listener"
        case .mcp: return "Memeriksa MCP Space"
        case .claude: return "Memeriksa Claude"
        case .daily: return "Memeriksa laporan harian"
        case .weekly: return "Memeriksa peringatan weekly"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let o = fix.outcome {
                let color = Color(hex: o.kind == .fixed ? "#22C55E" : o.kind == .needsYou ? "#F5A524" : "#F4505E")
                Text((o.kind == .fixed ? "✓ " : o.kind == .needsYou ? "⚠︎ " : "✕ ") + o.title)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(color)
                if !o.detail.isEmpty {
                    Text(o.detail).font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                steps.padding(.top, 2)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if let action = o.action {
                        Button(action.label) { bot.runFixAction(action.run) }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Color(hex: "#0E9BAD"))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .buttonStyle(.plain)
                    }
                    Button(o.action == nil ? "Selesai" : "Tutup") { bot.dismissFix() }
                        .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).buttonStyle(.plain)
                }
            } else {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold)).tracking(0.4).foregroundColor(Color(hex: "#6B7079"))
                steps
                Spacer(minLength: 0)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: "#2A2D32"))
                        Capsule()
                            .fill(LinearGradient(colors: [Color(hex: "#0E9BAD"), Color(hex: "#9BD15F")], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(fix.step) / CGFloat(max(1, fix.steps.count)))
                            .animation(.easeInOut(duration: 0.6), value: fix.step)
                    }
                }
                .frame(height: 3)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(fix.steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 7) {
                    if i < fix.step {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(Color(hex: "#22C55E"))
                    } else if i == fix.step && fix.outcome == nil {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                    } else {
                        Circle().stroke(Color(hex: "#4A4E55")).frame(width: 8, height: 8)
                    }
                    Text(i == fix.step && fix.outcome == nil ? s + "…" : s)
                        .font(.system(size: 11.5, weight: i == fix.step && fix.outcome == nil ? .semibold : .regular))
                        .foregroundColor(Color(hex: i <= fix.step ? "#C5C8CD" : "#6B7079"))
                }
            }
        }
    }
}

/// Wrench, spinning gear and sparks around Mochi while a repair runs.
/// Positions follow the `.venturo` bot position (64, 126 in island coords → 54, 84 here).
private struct RepairOverlay: View {
    @State private var swing = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15)).foregroundColor(Color(hex: "#8E939C"))
                    .rotationEffect(.degrees(t * 220))
                    .position(x: 22, y: 52)
                Image(systemName: "wrench.adjustable.fill")
                    .font(.system(size: 19)).foregroundColor(Color(hex: "#C5C8CD"))
                    .rotationEffect(.degrees(-30 + 50 * (0.5 + 0.5 * sin(t * 12))), anchor: .bottomLeading)
                    .position(x: 92, y: 98)
                ForEach(0..<4, id: \.self) { i in
                    let phase = (t * 1.4 + Double(i) * 0.25).truncatingRemainder(dividingBy: 1)
                    let angle = Double(i) * 1.6 + 0.4
                    Circle().fill(Color(hex: "#FFD166"))
                        .frame(width: 4, height: 4)
                        .shadow(color: Color(hex: "#FFD166"), radius: 3)
                        .opacity(1 - phase)
                        .position(x: 100 + cos(angle) * 18 * phase, y: 104 + sin(angle) * 18 * phase)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
#endif
