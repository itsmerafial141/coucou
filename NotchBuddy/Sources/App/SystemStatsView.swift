import SwiftUI
import ServiceManagement

/// Island "System" tab: temperatures, fans (Auto / Max through Stats), CPU, memory,
/// battery, network, disk and GPU, as a 4 × 2 grid of tiles.
struct SystemStatsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var mon = SystemMonitor.shared

    private var visible: Bool { state.mode == .expanded && state.view == .system }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 7), count: 4)

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 7) {
                header
                LazyVGrid(columns: cols, spacing: 7) {
                    tempTile
                    fanTile
                    cpuTile
                    memTile
                    batteryTile
                    netTile
                    diskTile
                    gpuTile
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .onAppear { mon.setVisible(visible) }
        .onChange(of: visible) { _, v in mon.setVisible(v) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("System")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            if mon.fanMode == .manual && mon.fanError == nil && !mon.switchingFans {
                manualSlider.transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: mon.fanError != nil || mon.hot ? "#FCA5A5" : mon.fanMode == .max ? "#8EC5FF" : "#6B7079"))
                    .lineLimit(1)
                    .onTapGesture { if mon.fanError?.contains("Login Items") == true { SMAppService.openSystemSettingsLoginItems() } }
            }
            Spacer(minLength: 4)
            if !mon.fans.isEmpty {
                Text("Fans").font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079"))
                HStack(spacing: 2) {
                    segment("Auto", on: mon.fanMode == .auto, accent: false) { mon.setFans(.auto) }
                    segment("Manual", on: mon.fanMode == .manual, accent: false) { mon.setFans(.manual, fraction: 0.5) }
                    segment("Max", on: mon.fanMode == .max, accent: true) { mon.setFans(.max) }
                }
                .padding(2)
                .background(Color(hex: "#0E0F11"))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(hex: "#2A2C31")))
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .opacity(mon.switchingFans ? 0.5 : 1)
                .disabled(mon.switchingFans)
            }
        }
        .animation(.easeOut(duration: 0.2), value: mon.fanMode)
        .onChange(of: mon.fanFraction) { _, f in if !dragging { sliderValue = f } }
        .onAppear { sliderValue = mon.fanFraction }
    }

    @State private var sliderValue = 0.5
    @State private var dragging = false

    /// Manual fan speed: applied when the drag ends, so the helper is not flooded.
    private var manualSlider: some View {
        HStack(spacing: 6) {
            Slider(value: $sliderValue, in: 0...1) { editing in
                dragging = editing
                if !editing { mon.setFans(.manual, fraction: sliderValue) }
            }
            .controlSize(.mini)
            .tint(Color(hex: "#8EC5FF"))
            .frame(width: 120)
            Text(rpmLabel)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundColor(Color(hex: "#8EC5FF"))
                .frame(width: 58, alignment: .leading)
        }
    }

    private var rpmLabel: String {
        guard let f = mon.fans.first else { return "" }
        return "\(Int((f.min + (f.max - f.min) * sliderValue) / 100) * 100) rpm"
    }

    private var statusText: String {
        if let e = mon.fanError { return e }
        if mon.switchingFans { return "Switching fans…" }
        if mon.hot { return "Hot, fans working hard" }
        switch mon.fanMode {
        case .max: return "Fans at max"
        case .manual: return "Fans manual"
        default: return "Normal"
        }
    }

    private func segment(_ title: String, on: Bool, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(hex: on ? (accent ? "#8EC5FF" : "#F5F6F8") : "#8E939C"))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(on ? (accent ? Color(hex: "#0A84FF").opacity(0.22) : Color(hex: "#2A2D33")) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .animation(.easeOut(duration: 0.2), value: on)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tiles

    private var tempTile: some View {
        let t = mon.cpuTemp ?? 0
        return Tile(label: "CPU temp", icon: "thermometer.medium",
                    value: mon.cpuTemp.map { "\(Int($0.rounded()))" } ?? "–", unit: "°C",
                    foot: mon.gpuTemp.map { "GPU \(Int($0.rounded()))°C" } ?? "",
                    valueColor: mon.hot ? "#FCA5A5" : nil,
                    bar: (min(1, max(0, (t - 30) / 75)), Self.heatColor(t)))
    }

    private var fanTile: some View {
        let fastest = mon.fans.map(\.rpm).max() ?? 0
        let maxRpm = mon.fans.map(\.max).max() ?? 1
        return Tile(label: "Fans", icon: "fan",
                    value: mon.fans.isEmpty ? "–" : fastest < 1 ? "Off" : String(format: "%.1fk", fastest / 1000),
                    unit: fastest < 1 ? "" : "rpm",
                    foot: mon.fans.map { "\($0.name) \(Int($0.rpm))" }.joined(separator: " · "),
                    spin: visible ? fastest : 0,   // no animation clock while the tab is hidden
                    bar: (min(1, fastest / max(maxRpm, 1)), "#8EC5FF"))
    }

    private var cpuTile: some View {
        Tile(label: "CPU", icon: "cpu", value: "\(Int((mon.cpu * 100).rounded()))", unit: "%",
             foot: "\(mon.cores) cores", bar: (mon.cpu, "#0A84FF"))
    }

    private var memTile: some View {
        Tile(label: "Memory", icon: "memorychip",
             value: String(format: "%.1f", mon.memUsed / 1_073_741_824),
             unit: "/ \(Int((mon.memTotal / 1_073_741_824).rounded())) GB",
             foot: mon.memPressure >= 4 ? "Pressure critical" : mon.memPressure >= 2 ? "Pressure high" : "Pressure normal",
             bar: (mon.memUsed / mon.memTotal, mon.memPressure >= 2 ? "#F5B83D" : "#BF5AF2"))
    }

    private var batteryTile: some View {
        let b = mon.battery
        let foot: String = {
            guard let b else { return "No battery" }
            let time = b.minutes.map { " · \($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? ""
            return b.charging ? "Charging\(time)" : b.plugged ? "On power" : "Battery\(time) left"
        }()
        return Tile(label: "Battery", icon: b?.charging == true ? "battery.100.bolt" : "battery.75",
                    value: b.map { "\($0.percent)" } ?? "–", unit: b == nil ? "" : "%", foot: foot,
                    bar: (Double(b?.percent ?? 0) / 100, (b?.percent ?? 100) <= 20 ? "#F4505E" : "#22C55E"))
    }

    private var netTile: some View {
        let down = Self.rate(mon.netIn)
        return Tile(label: "Network", icon: "arrow.up.arrow.down",
                    value: down.0, unit: down.1 + " ↓", foot: "↑ " + Self.rate(mon.netOut).0 + " " + Self.rate(mon.netOut).1,
                    bar: (min(1, mon.netIn / max(mon.netPeak, 1)), "#30D5C8"))
    }

    private var diskTile: some View {
        let used = mon.diskTotal > 0 ? 1 - Double(mon.diskFree) / Double(mon.diskTotal) : 0
        return Tile(label: "Disk", icon: "internaldrive",
                    value: "\(mon.diskFree / 1_000_000_000)", unit: "GB free",
                    foot: "of \(mon.diskTotal / 1_000_000_000) GB",
                    bar: (used, used > 0.9 ? "#F4505E" : "#64D2FF"))
    }

    private var gpuTile: some View {
        Tile(label: "GPU", icon: "cube.transparent",
             value: mon.gpu.map { "\(Int(($0 * 100).rounded()))" } ?? "–", unit: mon.gpu == nil ? "" : "%",
             foot: mon.gpuTemp.map { "\(Int($0.rounded()))°C" } ?? "",
             bar: (mon.gpu ?? 0, "#FF9F0A"))
    }

    // MARK: - Helpers

    static func heatColor(_ t: Double) -> String { t >= 85 ? "#F4505E" : t >= 70 ? "#F5B83D" : "#22C55E" }

    private static func rate(_ bps: Double) -> (String, String) {
        if bps >= 1_000_000 { return (String(format: "%.1f", bps / 1_000_000), "MB/s") }
        if bps >= 1_000 { return ("\(Int(bps / 1_000))", "KB/s") }
        return ("\(Int(bps))", "B/s")
    }
}

/// One stat tile: label, big value, footnote and a bar pinned to the bottom (same shape for every tile).
private struct Tile: View {
    let label: String
    let icon: String
    let value: String
    let unit: String
    let foot: String
    var valueColor: String? = nil
    var spin: Double = 0
    let bar: (Double, String)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if spin > 0 {
                    TimelineView(.animation) { ctx in
                        Image(systemName: icon)
                            .rotationEffect(.degrees((ctx.date.timeIntervalSinceReferenceDate * spin / 10)
                                .truncatingRemainder(dividingBy: 360)))
                    }
                } else {
                    Image(systemName: icon)
                }
                Text(label.uppercased()).kerning(0.4)
            }
            .font(.system(size: 8.5, weight: .bold))
            .foregroundColor(Color(hex: "#6B7079"))
            .frame(height: 11)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundColor(Color(hex: valueColor ?? "#F5F6F8"))
                    .contentTransition(.numericText())
                Text(unit).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .animation(.easeOut(duration: 0.4), value: value)
            Text(foot)
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(Color(hex: "#6B7079"))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            GeometryReader { g in
                Capsule().fill(Color(hex: "#26282D"))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color(hex: bar.1)).frame(width: max(4, g.size.width * max(0, min(1, bar.0))))
                    }
            }
            .frame(height: 4)
            .animation(.spring(response: 0.7, dampingFraction: 0.85), value: bar.0)
        }
        .padding(.horizontal, 9).padding(.top, 7).padding(.bottom, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 62)
        .background(Color(hex: "#0E0F11"))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#2A2C31")))
    }
}

/// Compact island's right ear: the mini pill grid, or the CPU temperature while the Mac is hot.
struct CompactRightEar: View {
    @ObservedObject var state: AppState
    @ObservedObject private var mon = SystemMonitor.shared
    let islandWidth: CGFloat
    let islandHeight: CGFloat

    var body: some View {
        Group {
            if mon.hot, let t = mon.cpuTemp {
                HStack(spacing: 3) {
                    Circle().fill(Color(hex: "#F4505E")).frame(width: 5, height: 5)
                    Text("\(Int(t.rounded()))°")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color(hex: "#FCA5A5"))
                }
                .help("Mac is hot: \(Int(t.rounded()))°C")
                .transition(.scale.combined(with: .opacity))
            } else {
                CompactMiniGrid(state: state)
                    .scaleEffect(IslandRestingLayout(width: islandWidth, height: islandHeight).miniGridScale)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: mon.hot)
        .position(x: islandWidth - 40, y: islandHeight / 2)
    }
}
