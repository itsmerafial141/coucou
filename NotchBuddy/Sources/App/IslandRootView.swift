import SwiftUI

/// Top-level SwiftUI view rendered inside the 720×320 transparent panel.
/// The island is drawn at the top-center; everything else is transparent and click-through.
/// Note: drag-drop is handled at the AppKit level in IslandWindowController (FileDropNSView),
/// not in SwiftUI, to avoid interfering with SwiftUI hit-testing.
struct IslandRootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            IslandContainer(state: state)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Island container

struct IslandContainer: View {
    @ObservedObject var state: AppState
    @State private var islandWidth:  CGFloat = IslandConst.notchWidth
    @State private var islandHeight: CGFloat = IslandConst.notchHeight
    @State private var cornerRadius: CGFloat = IslandConst.roundedCorner
    // topRadius > 0 → convex expanded corners; < 0 → concave ear cutouts
    @State private var islandTopRadius: CGFloat = 0
    /// Compact notice: the island grows this much to the right of the notch (left edge stays put).
    @State private var noticeExtra: CGFloat = 0
    #if !APPSTORE
    @ObservedObject private var loomify = LoomifyService.shared
    /// Loomify event waiting for a hover while its pill is focused: glow, hop and bell on the status dot.
    private var loomifyPending: Bool {
        loomify.pendingNotice && state.mode == .compact && state.focusId == LoomifyService.pillId
    }
    #endif

    private let openSpring = Animation.spring(response: 0.5, dampingFraction: 0.72)
    private let closeEase  = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.34)

    private var chatPromptHeight: CGFloat {
        let base: CGFloat = 240
        let perMsg: CGFloat = 40
        return min(300, base + CGFloat(state.chatHistory.count) * perMsg)
    }

    /// Pixels the content must be pushed down to clear the concave ear transparent area.
    /// = 0 in expanded mode (no ears), = earRadius in compact/notch mode.
    private var earOffset: CGFloat { max(0, -islandTopRadius) }

    var body: some View {
        return ZStack(alignment: .topLeading) {
            // Black island shape
            IslandShape(width: islandWidth + noticeExtra, height: islandHeight,
                        cornerRadius: cornerRadius, topRadius: islandTopRadius)
                .fill(Color.black)

            // Content
            if state.mode == .expanded {
                IslandContentView(state: state)
                    .frame(width: islandWidth, height: islandHeight - earOffset)
                    .offset(y: earOffset)
                    .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                          cornerRadius: cornerRadius, topRadius: islandTopRadius))
                    .transition(.opacity)
            }

            #if !APPSTORE
            if loomifyPending {
                LoomifyNoticeGlow(islandHeight: islandHeight).transition(.opacity)
            }
            #endif

            // Status dot where Mochi used to sit — always alive so it springs between views.
            BotPlacement(state: state, islandW: islandWidth, islandH: islandHeight)
                #if !APPSTORE
                .modifier(LoomifyHop(active: loomifyPending))
                #endif

            CountdownBar(state: state, islandW: islandWidth)

            Group {
                #if !APPSTORE
                if state.mode == .compact {
                    if let notice = state.compactNotice {
                        CompactNoticeLine(notice: notice, notchWidth: state.notchWidth,
                                          islandWidth: islandWidth + noticeExtra, islandHeight: islandHeight)
                            .transition(.opacity)
                    } else {
                        CompactRightEar(state: state, islandWidth: islandWidth, islandHeight: islandHeight)
                            .transition(.opacity)
                    }
                }
                if loomifyPending {
                    LoomifyNoticeBell(islandHeight: islandHeight).transition(.scale.combined(with: .opacity))
                }
                #else
                if state.mode == .compact {
                    CompactMiniGrid(state: state)
                        .scaleEffect(IslandRestingLayout(width: islandWidth, height: islandHeight).miniGridScale)
                        .position(x: islandWidth - 40, y: islandHeight / 2)
                        .transition(.opacity)
                }
                #endif
            }
            .animation(.easeInOut(duration: 0.25), value: state.mode == .compact)
            .animation(.easeInOut(duration: 0.25), value: state.compactNotice)
            #if !APPSTORE
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: loomifyPending)
            #endif
        }
        .frame(width: islandWidth + noticeExtra, height: islandHeight, alignment: .topLeading)
        // Centered by the parent: shift by half the extra so only the right side grows.
        .offset(x: noticeExtra / 2)
        .onChange(of: state.compactNotice != nil && state.mode == .compact) { _, on in
            withAnimation(on ? openSpring : closeEase) {
                noticeExtra = on ? compactNoticeExtra(nw: state.notchWidth) : 0
            }
        }
        .onChange(of: state.mode) { oldMode, newMode in
            let shrinking = modeOrder(newMode) < modeOrder(oldMode)
            let anim = shrinking ? closeEase : openSpring
            let (w, h) = islandSize(mode: newMode, view: state.view,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            let cr  = newMode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            let tr: CGFloat = 0
            withAnimation(anim) {
                islandWidth      = w
                islandHeight     = (newMode == .expanded && state.view == .prompt) ? chatPromptHeight : h
                cornerRadius     = cr
                islandTopRadius  = tr
            }
        }
        .onChange(of: state.view) { _, newView in
            guard state.mode == .expanded else { return }
            let (w, h) = islandSize(mode: .expanded, view: newView,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(openSpring) {
                islandWidth  = w
                islandHeight = newView == .prompt ? chatPromptHeight : h
            }
        }
        .onChange(of: state.notchWidth + state.notchHeight) { _, _ in
            // Island moved to another screen: morph notch ↔ resting bar (expanded size doesn't depend on it).
            guard state.mode != .expanded else { return }
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(openSpring) {
                islandWidth  = w
                islandHeight = h
            }
        }
        .onChange(of: state.chatHistory.count) { _, _ in
            guard state.mode == .expanded, state.view == .prompt else { return }
            withAnimation(openSpring) { islandHeight = chatPromptHeight }
        }
        .onAppear {
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            islandWidth      = w
            islandHeight     = state.view == .prompt ? chatPromptHeight : h
            cornerRadius     = state.mode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            islandTopRadius  = 0
        }
    }

    private func modeOrder(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }
}

// MARK: - Island shape
//
// topRadius > 0  → convex rounded top corners (expanded mode)
// topRadius < 0  → concave ear cutouts, |topRadius| = ear radius (compact/notch mode)
// topRadius = 0  → sharp top corners (transient during animation)

struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat   // bottom corners
    var topRadius: CGFloat      // see above

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>, CGFloat> {
        get { .init(.init(.init(width, height), cornerRadius), topRadius) }
        set {
            width        = newValue.first.first.first
            height       = newValue.first.first.second
            cornerRadius = newValue.first.second
            topRadius    = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cr = max(0, cornerRadius)
        var p  = Path()

        if topRadius >= 0 {
            // ── Convex rounded top corners (expanded) ──────────────────────────
            let tr = min(topRadius, min(width / 2, height / 2))
            p.move(to: CGPoint(x: tr, y: 0))
            p.addLine(to: CGPoint(x: width - tr, y: 0))
            // Top-right convex corner
            p.addArc(center: CGPoint(x: width - tr, y: tr), radius: tr,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge
            p.addLine(to: CGPoint(x: 0, y: tr))
            // Top-left convex corner
            p.addArc(center: CGPoint(x: tr, y: tr), radius: tr,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            // ── Concave ear cutouts (compact / notch) ─────────────────────────
            let er = -topRadius   // positive ear radius
            p.move(to: CGPoint(x: 0, y: 0))
            // Top-left ear
            p.addArc(center: CGPoint(x: 0, y: er), radius: er,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Top edge
            p.addLine(to: CGPoint(x: width - er, y: er))
            // Top-right ear
            p.addArc(center: CGPoint(x: width, y: er), radius: er,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge back to top-left corner
            p.addLine(to: CGPoint(x: 0, y: 0))
        }

        p.closeSubpath()
        return p
    }
}

// MARK: - Status dot (replaces Mochi)

/// Colour of a session state, shared by the main dot and the mini dots.
func statusColor(_ s: BotState) -> Color {
    switch s {
    case .working:   return Color(hex: "#3B9EFF")
    case .thinking:  return Color(hex: "#A78BFA")
    case .searching: return Color(hex: "#6366F1")
    case .approval:  return Color(hex: "#F5A524")
    case .question:  return Color(hex: "#22D3EE")
    case .error:     return Color(hex: "#F4505E")
    case .finished:  return Color(hex: "#34D399")
    case .ratelimit: return Color(hex: "#F59E0B")
    case .sleeping:  return Color(hex: "#94A2B8")
    case .dizzy:     return Color(hex: "#F472B6")
    case .idle:      return Color(hex: "#E6E9EE")
    }
}

/// Static dot: no per-frame drawing, so it costs nothing between state changes.
struct StatusDot: View {
    let color: Color
    var glow: Bool = true

    var body: some View {
        Circle()
            .fill(color)
            .shadow(color: color.opacity(glow ? 0.7 : 0), radius: 4)
    }
}

/// Another session: its own colour, ringed with its state while it is busy or needs you.
struct MiniStatusDot: View {
    let task: AgentTask

    var body: some View {
        let ring = task.state != .idle && task.state != .sleeping
        Circle()
            .fill(Color(hex: task.color))
            .overlay(Circle().stroke(statusColor(task.state), lineWidth: 1.5).opacity(ring ? 1 : 0))
    }
}

struct BotPlacement: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat
    /// Mac too hot (System tab threshold): red dot.
    @State private var hot = false

    /// Integration pills keep their brand colour; agent sessions show their state.
    private var color: Color {
        #if !APPSTORE
        if hot { return Color(hex: "#F4505E") }
        if state.showingPlanDetail {
            return Color(hex: ClaudePlanGauge.color(for: state.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) }))
        }
        #endif
        if let task = state.focusTask, task.isIntegration, state.stateOverride == nil {
            return Color(hex: task.color)
        }
        return statusColor(state.effectiveState)
    }

    var body: some View {
        let (cx, cy, diameter, opacity) = botPosition(mode: state.mode, view: state.view, islandW: islandW, islandH: islandH, uploadProgress: state.uploadProgress, hasNotch: state.hasNotch)
        // Expanded views keep Mochi's gutter; a small dot sits in its centre.
        let size = state.mode == .expanded ? max(10, diameter * 0.26) : max(6, diameter * 0.5)
        StatusDot(color: color, glow: state.effectiveState != .idle)
            .frame(width: size, height: size)
            // The uploading view draws its own progress bar.
            .opacity(state.view == .uploading && state.mode == .expanded ? 0 : opacity)
            .position(x: cx, y: cy)
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cx)
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cy)
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: size)
            .animation(.easeInOut(duration: 0.3), value: state.effectiveState)
            .allowsHitTesting(false)
            #if !APPSTORE
            .onReceive(SystemMonitor.shared.$hot.removeDuplicates()) { hot = $0 }
            #endif
    }
}

func botPosition(mode: IslandMode, view: IslandView, islandW: CGFloat, islandH: CGFloat, uploadProgress: Double, hasNotch: Bool = true) -> (CGFloat, CGFloat, CGFloat, Double) {
    let resting = IslandRestingLayout(width: islandW, height: islandH)
    switch mode {
    case .hidden:
        return hasNotch ? (46, 16, 6, 0)
            : (islandW / 2, resting.botCenterY, resting.botDiameter, 1)
    case .compact: return (40, resting.botCenterY, resting.botDiameter, 1)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        let diameter = layout.botDiameter
        // Uploading: Mochi dot rides the leading edge of the progress fill.
        // Bar in island coords: left=36, width=526. cx = 36 + progress*526 (dot center at fill right edge).
        // cy comes from ViewLayout.botY (bar center in island coords).
        if view == .uploading {
            let cx = 36 + CGFloat(uploadProgress) * 526
            return (cx, layout.botY ?? 103, diameter, 1)
        }
        let cx = layout.botX
        let cy: CGFloat
        if let fixedY = layout.botY {
            cy = fixedY
        } else {
            // Center of the fixed 84pt card (VStack top=8, header=34 → content starts at y=42)
            let headerBottom: CGFloat = 42
            let cardH: CGFloat = 84
            cy = headerBottom + (islandH - headerBottom - cardH) / 2 + cardH / 2
        }
        return (cx, cy, diameter, 1)
    }
}

// MARK: - Countdown bar

struct CountdownBar: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    @State private var barWidth: CGFloat = 0
    @State private var timer: Timer? = nil

    var body: some View {
        GeometryReader { _ in
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: barWidth, height: 2)
                .cornerRadius(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        // Ticks only while expanded: a folded or hidden island runs no timer at all.
        .onAppear { if state.mode == .expanded { startTimer() } }
        .onChange(of: state.mode) { _, mode in
            if mode == .expanded { startTimer() } else { stopTimer(); barWidth = 0 }
        }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { updateBar() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateBar() {
        guard state.mode == .expanded && !state.isPinned else {
            barWidth = 0
            return
        }
        let autoClose = state.autoCloseInterval
        let window = min(10.0, autoClose * 0.6)
        let elapsed = Date.now.timeIntervalSince(state.lastActivity)
        let remaining = autoClose - elapsed
        if remaining < window {
            barWidth = max(0, CGFloat(remaining / window) * 160)
        } else {
            barWidth = 0
        }
    }
}

// MARK: - Island content (header + views, only in expanded mode)

struct IslandContentView: View {
    @ObservedObject var state: AppState
    /// Tabs shown since the island opened. Only these are built: building all ~25 tabs on every
    /// open (each laid out on every frame of the open spring, every onAppear firing) made opening
    /// heavy. Visited tabs stay alive so drafts survive tab switches, as before; this view is torn
    /// down when the island folds, which resets the set.
    @State private var visited: Set<IslandView> = []

    var body: some View {
        VStack(spacing: 0) {
            IslandHeader(state: state)
                .frame(height: 34)
                .opacity(state.view == .confused ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: state.view == .confused)

            ZStack {
                ForEach(IslandView.allCases.filter { $0 == state.view || visited.contains($0) }, id: \.self) { v in
                    let active = state.view == v
                    // Views that fill available height instead of the fixed 98pt content frame:
                    // chat (prompt) is always flexible; mail is flexible only when active so
                    // it doesn't push the ZStack taller when inactive.
                    let isTall = v == .prompt || v == .clipboard || v == .system || v == .jiggler || ((v == .mail || v == .spotify || v == .venturo || v == .discord || v == .phonevps || v == .loomify || v == .superset) && active)
                    let anim: Animation = active
                        ? .spring(response: 0.4, dampingFraction: 0.8).delay(0.16)
                        : .easeIn(duration: 0.16)
                    IslandViewContent(view: v, state: state)
                        .frame(maxWidth: .infinity)
                        .frame(height: isTall ? nil : 98)
                        .frame(minHeight: (isTall && !active) ? 0 : nil, maxHeight: isTall ? .infinity : nil)
                        .opacity(active ? 1 : 0)
                        .scaleEffect(active ? 1 : 0.97)
                        .allowsHitTesting(active)
                        .animation(anim, value: state.view)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .foregroundColor(Color(hex: "#F5F6F8"))
        .onAppear { visited.insert(state.view) }
        .onChange(of: state.view) { old, _ in visited.insert(old) }
    }
}

// MARK: - Island header (tabs + icons)

struct IslandHeader: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Left: tab capsules
            HStack(spacing: 5) {
                TabButton(icon: "house.fill", view: .overview, state: state)
                TabButton(icon: "bubble.left.fill", view: .prompt, state: state, preAction: {
                    #if !APPSTORE
                    if state.promptContext == nil {
                        state.promptContext = WindowContextCapture.captureActive(from: state.lastExternalApp)
                    }
                    #endif
                })
                TabButton(icon: "plus", view: .upload, state: state)
                TabButton(icon: "menubar.rectangle", view: .menuBar, state: state)
                TabButton(icon: "doc.on.clipboard", view: .clipboard, state: state)
                #if !APPSTORE
                TabButton(icon: "waveform.path.ecg", view: .system, state: state)
                #endif
            }
            .padding(.leading, 14)

            Spacer()

            // Right: plan pill (GitHub build, home view only) + action icons
            HStack(spacing: 8) {
                #if !APPSTORE
                if state.view == .overview && state.showPlanInNotch && state.planRelayInstalled {
                    ClaudePlanHeaderPill(state: state)
                }
                #endif
                HStack(spacing: 14) {
                    #if !APPSTORE
                    // Right group: a seventh tab on the left would sit under the camera notch.
                    TabButton(icon: "cursorarrow.motionlines", view: .jiggler, state: state)
                    #endif
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            state.view = .settings
                        }
                    }) {
                        Image(systemName: state.view == .settings ? "gearshape.fill" : "gearshape")
                            .font(.system(size: 14))
                            .foregroundColor(state.view == .settings ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)

                    Button(action: { state.soundEnabled.toggle() }) {
                        Image(systemName: state.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 16)
        }
        .frame(maxHeight: .infinity)
    }
}

struct TabButton: View {
    let icon: String
    let view: IslandView
    @ObservedObject var state: AppState
    var preAction: (() -> Void)? = nil
    @State private var isHovered = false

    private var isOn: Bool {
        if view == .overview { return state.view == .overview || state.view == .empty }
        return state.view == view
    }

    var body: some View {
        Button(action: {
            preAction?()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                state.view = view
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(isOn ? Color(hex: "#F5F6F8") : (isHovered ? Color(hex: "#B0B5BE") : Color(hex: "#8E939C")))
                .frame(width: 30, height: 22)
                .background(
                    isOn ? Color(hex: "#1D1F23") :
                    isHovered ? Color.white.opacity(0.07) : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Claude Plan header pill (GitHub build only)

#if !APPSTORE
struct ClaudePlanHeaderPill: View {
    @ObservedObject var state: AppState
    @State private var isHovered = false

    private var effectiveColor: String {
        ClaudePlanGauge.color(for: state.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) })
    }

    private var label: String {
        guard let usage = state.claudePlanUsage,
              let pct = ClaudePlanGauge.dominantPct(usage) else { return "Claude —" }
        return "Claude \(Int(pct.rounded()))%"
    }

    private var isActive: Bool { state.showingPlanDetail || isHovered }

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                state.showingPlanDetail.toggle()
            }
        }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: effectiveColor))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isActive
                                     ? Color(hex: effectiveColor).lighter(by: 0.3)
                                     : Color(hex: "#6B7079"))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isActive
                          ? Color(hex: effectiveColor).opacity(0.18)
                          : Color(hex: "#0E0F11"))
            )
            .overlay(
                Capsule()
                    .stroke(Color(hex: effectiveColor).opacity(isActive ? 0.55 : 0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = h }
        }
    }
}
#endif

// MARK: - Compact mini mochi grid (2×2 to the right of the notch)

struct CompactMiniGrid: View {
    @ObservedObject var state: AppState

    private var others: [AgentTask] {
        state.tasks.filter { $0.id != state.focusId }
    }

    var body: some View {
        let cols = [GridItem(.fixed(12), spacing: 4), GridItem(.fixed(12), spacing: 4)]
        // 2×2 holds 4 faces; with more, the 4th slot becomes "+N".
        let more = others.count > 4
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(more ? Array(others.prefix(3)) : others) { task in
                MiniStatusDot(task: task)
                    .frame(width: 8, height: 8)
                    .frame(width: 12, height: 12, alignment: .center)
            }
            if more { MorePill(count: others.count - 3, size: 12) }
        }
        .frame(width: 28, height: 28)
    }
}
