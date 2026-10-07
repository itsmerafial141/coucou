#if !APPSTORE
import SwiftUI

// MARK: - Shared bits

private let grey = Color(hex: "#6B7079"), red = Color(hex: "#F4505E")

private func statusColor(_ s: Superset.Status?) -> Color {
    switch s {
    case .needsYou: return Color(hex: "#F5A524")
    case .working:  return Color(hex: "#3B82F6")
    case .idle:     return Color(hex: "#22C55E")
    case nil:       return Color(hex: "#3A3D43")
    }
}

private func statusLabel(_ s: Superset.Status?) -> String {
    switch s {
    case .needsYou: return "Needs you"
    case .working:  return "Working"
    case .idle:     return "Done"
    case nil:       return "No agent"
    }
}

// MARK: - Home card (focus on the Superset pill): agent counts + latest event + expand

struct SupersetCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var ss = SupersetService.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: SupersetService.colorHex)).frame(width: 7, height: 7)
                    Text("Superset").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                    Text("\(ss.workspaces.count) workspaces").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                }
                if !ss.isInstalled {
                    Text("Superset not found (~/.superset)").font(.system(size: 11)).foregroundColor(grey)
                } else if let err = ss.error {
                    Text(err).font(.system(size: 11)).foregroundColor(red).lineLimit(2)
                } else {
                    let c = ss.counts
                    HStack(spacing: 12) {
                        count(.working, c.working)
                        count(.needsYou, c.needsYou)
                        count(.idle, c.idle)
                    }
                    if let event = ss.events.first {
                        Text("● \(event)").font(.system(size: 10.5)).foregroundColor(Color(hex: SupersetService.colorHex)).lineLimit(1)
                    } else if let w = ss.workspaces.first(where: { $0.status != nil }) {
                        (Text("▸ ").foregroundColor(grey)
                         + Text(w.title).foregroundColor(Color(hex: "#C5C8CD"))
                         + Text(" · \(statusLabel(w.status).lowercased()) · \(Superset.ago(w.active))").foregroundColor(Color(hex: "#8E939C")))
                            .font(.system(size: 10.5)).lineLimit(1)
                    }
                }
            }
            .padding(.leading, 108)
            .padding(.trailing, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .superset }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .frame(width: 20, height: 20)
                    .background(Color(hex: "#1D1F23"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Show the workspaces")
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
        .onAppear { ss.markSeen() }
    }

    private func count(_ s: Superset.Status, _ n: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor(s)).frame(width: 6, height: 6)
            Text(statusLabel(s)).font(.system(size: 11.5)).foregroundColor(Color(hex: "#C5C8CD")).lineLimit(1)
            Text("\(n)").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
        }
    }
}

// MARK: - Detail (IslandView.superset): workspace list

/// Mochi sits at the top of the 116pt left gutter (`.superset` layout in IslandConst), totals below it.
struct SupersetListView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var ss = SupersetService.shared
    @State private var filter: Superset.Status?

    private var shown: [Superset.Workspace] {
        guard let filter else { return ss.workspaces }
        return ss.workspaces.filter { $0.status == filter }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            gutter
                .frame(width: 104, alignment: .leading)
                .padding(.leading, 14)
                .padding(.top, 80)
                .padding(.bottom, 12)
                .frame(maxHeight: .infinity, alignment: .top)
            list
                .padding(.leading, 116)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
        }
        .onChange(of: state.view) { _, v in if v == .superset { ss.refresh(force: true); ss.markSeen() } }
        .onAppear { ss.markSeen() }
    }

    private var gutter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Superset").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
            let c = ss.counts
            Text("\(ss.workspaces.count) workspaces · \(c.working + c.needsYou + c.idle) agents")
                .font(.system(size: 10)).foregroundColor(grey).fixedSize(horizontal: false, vertical: true)
            if c.needsYou > 0 {
                Text("\(c.needsYou) need you").font(.system(size: 10, weight: .semibold)).foregroundColor(statusColor(.needsYou))
            }
            Button("Open Superset ↗") { ss.open() }
                .font(.system(size: 10.5)).foregroundColor(Color(hex: SupersetService.colorHex)).buttonStyle(.plain)
            Spacer(minLength: 0)
            Button("Refresh") { ss.refresh(force: true) }
                .font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).buttonStyle(.plain)
        }
    }

    @ViewBuilder private var list: some View {
        if !ss.isInstalled || ss.error != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(ss.error ?? "Superset isn't installed, or hasn't started its host service yet (~/.superset/host).")
                    .font(.system(size: 11.5)).foregroundColor(ss.error != nil ? red : grey)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    chip("All", nil, ss.workspaces.count)
                    chip("Needs you", .needsYou, ss.counts.needsYou)
                    chip("Working", .working, ss.counts.working)
                    Spacer(minLength: 0)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(shown) { WorkspaceRow(workspace: $0, ss: ss) }
                        if shown.isEmpty {
                            Text(filter == nil ? "No workspaces" : "Nothing here right now")
                                .font(.system(size: 10.5)).foregroundColor(grey)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func chip(_ title: String, _ s: Superset.Status?, _ n: Int) -> some View {
        let on = filter == s
        return Button { filter = s } label: {
            HStack(spacing: 4) {
                if let s { Circle().fill(statusColor(s)).frame(width: 5, height: 5) }
                Text(title).font(.system(size: 10, weight: on ? .semibold : .regular))
                Text("\(n)").font(.system(size: 10, weight: .semibold)).foregroundColor(on ? Color(hex: "#F5F6F8") : grey)
            }
            .foregroundColor(on ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Color(hex: on ? "#26292E" : "#1B1D21")))
            .overlay(Capsule().stroke(on ? Color(hex: SupersetService.colorHex).opacity(0.5) : Color(hex: "#23262B")))
        }
        .buttonStyle(.plain)
    }
}

private struct WorkspaceRow: View {
    let workspace: Superset.Workspace
    @ObservedObject var ss: SupersetService
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor(workspace.status)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.title)
                    .font(.system(size: 10.5, weight: .medium)).foregroundColor(Color(hex: "#C5C8CD")).lineLimit(1)
                HStack(spacing: 5) {
                    Text(workspace.branch).font(.system(size: 9.5, design: .monospaced)).foregroundColor(grey).lineLimit(1)
                    if !workspace.agents.isEmpty {
                        Text(agentsLabel).font(.system(size: 9.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if let pr = workspace.pr { prBadge(pr) }
            Text(Superset.ago(workspace.active)).font(.system(size: 9.5)).foregroundColor(grey)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: hover ? "#24201C" : "#1B1D21")))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(hover ? Color(hex: SupersetService.colorHex).opacity(0.55) : Color(hex: "#23262B")))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hover = $0 }
        .onTapGesture { ss.open(workspace) }
        .help("\(workspace.project) · \(statusLabel(workspace.status)) · click to open in Superset")
    }

    /// "claude · needs you", or "claude ×2 · working" with several agents.
    private var agentsLabel: String {
        let kinds = Set(workspace.agents.map(\.agentId)).sorted().joined(separator: ", ")
        let n = workspace.agents.count
        return "· \(kinds)\(n > 1 ? " ×\(n)" : "") · \(statusLabel(workspace.status).lowercased())"
    }

    private func prBadge(_ pr: Superset.PullRequest) -> some View {
        let (icon, color): (String, String) = switch pr.state == "merged" ? "merged" : pr.checks {
        case "merged":  ("arrow.triangle.merge", "#A855F7")
        case "success": ("checkmark", "#22C55E")
        case "failure": ("xmark", "#F4505E")
        case "pending": ("circle.dotted", "#F5A524")
        default:        ("arrow.triangle.pull", "#8E939C")
        }
        return Button { ss.openPR(pr) } label: {
            HStack(spacing: 3) {
                Text("#\(pr.number)").font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                Image(systemName: icon).font(.system(size: 7.5, weight: .bold))
            }
            .foregroundColor(Color(hex: color))
            .padding(.horizontal, 5).frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: color).opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("PR #\(pr.number): \(pr.title) · checks \(pr.checks)")
    }
}
#endif
