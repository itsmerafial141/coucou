#if !APPSTORE
import SwiftUI

// MARK: - Shared bits

private let green = Color(hex: "#22C55E"), red = Color(hex: "#F4505E"), grey = Color(hex: "#6B7079")

private func label(_ service: String) -> String {
    switch service {
    case "sshd": return "SSH"
    case "cloudflared": return "Tunnel"
    case "cloudflared-watchdog": return "Watchdog"
    case "jenkins": return "Jenkins"
    case "health-api": return "Health API"
    case "postgres": return "Postgres"
    case "space-mcp": return "Space MCP"
    default: return service
    }
}

private struct Dot: View {
    let text: String
    let ok: Bool?   // nil = unknown
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok.map { $0 ? green : red } ?? grey).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5)).foregroundColor(Color(hex: "#C5C8CD")).lineLimit(1)
        }
    }
}

// MARK: - Home card (focus on the Phone VPS pill): service dots + expand

struct PhoneVPSCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var vps = PhoneVPSMonitor.shared
    private let columns = [GridItem(.flexible(), spacing: 12, alignment: .leading),
                           GridItem(.flexible(), spacing: 12, alignment: .leading)]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if vps.reachable == .failing {
                    VStack(alignment: .leading, spacing: 4) {
                        Dot(text: "Phone unreachable", ok: false)
                        let sitesUp = vps.siteResults.filter(\.healthy).count
                        Text("Sites \(sitesUp)/\(vps.siteResults.count) answer · open for diagnosis")
                            .font(.system(size: 10.5)).foregroundColor(grey).lineLimit(1)
                    }
                } else if vps.services.isEmpty {
                    Dot(text: vps.checking ? "Checking…" : "Not checked yet", ok: nil)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                        ForEach(vps.services) { Dot(text: label($0.name), ok: $0.healthy) }
                    }
                }
            }
            .padding(.leading, 108)
            .padding(.trailing, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .phonevps }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .frame(width: 20, height: 20)
                    .background(Color(hex: "#1D1F23"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Troubleshoot")
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
    }
}

// MARK: - Detail (IslandView.phonevps): troubleshooting

/// Mochi sits in the left gutter: the `.phonevps` layout in IslandConst matches the 116pt inset.
struct PhoneVPSDetailView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var vps = PhoneVPSMonitor.shared
    /// Restart needs a second click within 3 s.
    @State private var confirming: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            Group {
                if let out = vps.output { OutputPanel(out: out, vps: vps) } else { overview }
            }
            .padding(.leading, 116)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: vps.output == nil)
        .onChange(of: state.view) { _, v in if v == .phonevps { vps.refresh() } }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 16) {
                servicesColumn.frame(maxWidth: .infinity, alignment: .leading)
                sitesColumn.frame(width: 150, alignment: .leading)
            }
            Spacer(minLength: 0)
            Text(statsLine).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
            HStack(spacing: 14) {
                link("Diagnose", primary: true) { vps.diagnose() }
                link("nginx errors") { vps.nginxErrors() }
                link("Reload nginx") { vps.nginxReload() }
                link(vps.checking ? "Checking…" : "Refresh") { vps.refresh() }
                link("Terminal") { vps.openTerminal() }
            }
        }
    }

    private var statsLine: String {
        if vps.reachable == .failing { return vps.lastError.map { "SSH: \($0)" } ?? "SSH failed" }
        let s = vps.stats
        guard !s.load.isEmpty else { return vps.checking ? "Reading the phone…" : "" }
        return "Load \(s.load) · RAM \(s.ram) · Disk \(s.disk) · up \(s.uptime)"
    }

    private var servicesColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            section("Services")
            if vps.reachable == .failing {
                Dot(text: "Unreachable over SSH", ok: false)
                Text("Run Diagnose to see whether the tunnel or the phone is down.")
                    .font(.system(size: 10.5)).foregroundColor(grey).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(vps.services) { s in
                HStack(spacing: 8) {
                    Dot(text: label(s.name), ok: s.healthy)
                    if !s.alive || s.port == "tutup" {
                        Text(s.alive ? "port closed" : "stopped").font(.system(size: 10)).foregroundColor(red)
                    }
                    Spacer(minLength: 4)
                    if PhoneVPSMonitor.withLog.contains(s.name) {
                        small("Log") { vps.showLog(s.name) }
                    }
                    if PhoneVPSMonitor.restartable.contains(s.name) {
                        let sure = confirming == s.name
                        small(sure ? "Sure?" : "Restart", color: sure ? red : nil) {
                            if sure { confirming = nil; vps.restart(s.name) } else { confirm(s.name) }
                        }
                    }
                }
            }
        }
    }

    private var sitesColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            section("Sites")
            ForEach(vps.siteResults) { site in
                HStack(spacing: 6) {
                    Dot(text: site.name, ok: site.healthy)
                    Spacer(minLength: 2)
                    Text(site.code.map(String.init) ?? "err")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(site.healthy ? grey : red)
                }
            }
        }
    }

    private func confirm(_ name: String) {
        confirming = name
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if confirming == name { confirming = nil } }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold)).tracking(0.4).foregroundColor(grey)
            .padding(.bottom, 2)
    }

    private func small(_ title: String, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color ?? Color(hex: "#8E939C"))
            .buttonStyle(.plain)
            .disabled(vps.output?.running == true)
    }

    private func link(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: primary ? .medium : .regular))
            .foregroundColor(primary ? Color(hex: PhoneVPSMonitor.colorHex) : Color(hex: "#8E939C"))
            .buttonStyle(.plain)
    }
}

// MARK: - Output of a troubleshooting action

private struct OutputPanel: View {
    let out: PhoneVPSMonitor.Output
    @ObservedObject var vps: PhoneVPSMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if out.running {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                } else {
                    Image(systemName: out.ok ? "checkmark" : "xmark")
                        .font(.system(size: 9, weight: .bold)).foregroundColor(out.ok ? green : red)
                }
                Text(out.title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold)).tracking(0.4).foregroundColor(grey)
            }
            ScrollView {
                Text(out.running ? "Running on the phone…" : out.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 14) {
                Button(out.running ? "Hide" : "Close") { vps.dismissOutput() }
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).buttonStyle(.plain)
                if !out.running && !out.text.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(out.text, forType: .string)
                    }
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).buttonStyle(.plain)
                }
            }
        }
    }
}
#endif
