import AppKit
import ApplicationServices
import SwiftUI

#if !APPSTORE  // ponytail: posting HID events isn't allowed in the sandboxed App Store build

/// Mouse jiggler: while on, glides the cursor to a random spot on screen whenever the user has been idle for
/// `interval`, so chat apps keep showing "Active" and the Mac doesn't sleep. Real HID events
/// (needs Accessibility); nothing runs while it's off. Not persisted on purpose: it never
/// starts by itself after a relaunch.
@MainActor
final class MouseJiggler: ObservableObject {
    static let shared = MouseJiggler()

    static let intervals: [TimeInterval] = [30, 60, 120, 300]
    static let autoOffs: [TimeInterval] = [0, 1800, 3600, 7200, 14400, 28800]  // 0 = never

    @Published private(set) var isOn = false
    @Published private(set) var stopsAt: Date? = nil
    @Published var interval: TimeInterval = UserDefaults.standard.object(forKey: "jigglerInterval") as? TimeInterval ?? 60 {
        didSet {
            UserDefaults.standard.set(interval, forKey: "jigglerInterval")
            if isOn { schedule() }
        }
    }
    @Published var autoOff: TimeInterval = UserDefaults.standard.double(forKey: "jigglerAutoOff") {
        didSet {
            UserDefaults.standard.set(autoOff, forKey: "jigglerAutoOff")
            if isOn { stopsAt = autoOff > 0 ? Date().addingTimeInterval(autoOff) : nil }
        }
    }

    /// Also brings another app forward on idle ticks, and in a browser goes to the next tab.
    @Published var switchApps = UserDefaults.standard.bool(forKey: "jigglerSwitchApps") {
        didSet { UserDefaults.standard.set(switchApps, forKey: "jigglerSwitchApps") }
    }

    private var timer: Timer?
    private var idleTicks = 0

    var canPostEvents: Bool { AXIsProcessTrusted() }

    func requestAccess() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        if on && !canPostEvents { requestAccess(); return }
        isOn = on
        stopsAt = on && autoOff > 0 ? Date().addingTimeInterval(autoOff) : nil
        on ? schedule() : timer?.invalidate()
    }

    private func schedule() {
        timer?.invalidate()
        // ponytail: ticks at a third of the interval so an idle stretch is caught within ~1/3 of it.
        timer = Timer.scheduledTimer(withTimeInterval: max(10, interval / 3), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 2
    }

    private func tick() {
        if let stopsAt, Date() >= stopsAt { setOn(false); return }
        guard Self.idleSeconds() >= interval - 1 else { return }
        Task { await Self.nudge() }
        guard switchApps else { return }
        idleTicks += 1
        // Alternate: a tab in the frontmost browser, then another app.
        if idleTicks.isMultiple(of: 2), Self.frontmostIsBrowser { Self.nextTab() } else { Self.nextApp() }
    }

    /// Seconds since the last mouse or keyboard input from anyone (the user or our own nudge).
    nonisolated static func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    static var frontmostIsBrowser: Bool {
        browsers.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }

    /// Brings forward the next app that has a window on screen (Coucou excluded). Through Launch
    /// Services like the Dock: a background app's `activate()` and AX frontmost are both refused.
    static func nextApp() {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let withWindows = Set(info.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
                                  .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && withWindows.contains($0.processIdentifier) }
            .sorted { $0.processIdentifier < $1.processIdentifier }
        guard apps.count > 1 else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let i = apps.firstIndex { $0.processIdentifier == front } ?? -1
        guard let url = apps[(i + 1) % apps.count].bundleURL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    /// Ctrl+Tab: next tab in every listed browser. Only sent when a browser is frontmost.
    nonisolated static func nextTab() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 48, keyDown: down)  // 48 = Tab
            e?.flags = .maskControl
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Glides the cursor to a random spot on the display it's on (~0.6 s) and leaves it there.
    /// Keeps 80 pt off the edges: no hot corners, Dock, menu bar or the notch (which opens the island).
    nonisolated static func nudge() async {
        guard let start = CGEvent(source: nil)?.location else { return }
        var display = CGMainDisplayID(), count: UInt32 = 0
        CGGetDisplaysWithPoint(start, 1, &display, &count)
        let b = CGDisplayBounds(display).insetBy(dx: 80, dy: 80)
        let target = CGPoint(x: .random(in: b.minX...b.maxX), y: .random(in: b.minY...b.maxY))
        let src = CGEventSource(stateID: .hidSystemState)
        var last = start
        for step in 1...30 {
            // The user took the mouse back: stop, never drag the cursor away from them.
            guard let now = CGEvent(source: nil)?.location, abs(now.x - last.x) < 1, abs(now.y - last.y) < 1 else { return }
            let t = Double(step) / 30, e = t * t * (3 - 2 * t)  // smoothstep
            let p = CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e)
            // Warp moves the cursor at once (a posted event lags, which read as the user moving it).
            CGWarpMouseCursorPosition(p)
            last = p
            try? await Task.sleep(for: .milliseconds(20))
        }
        // A warp isn't input: one real event at the end resets the system idle timer.
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}

// MARK: - Island tab

struct MouseJigglerView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var jiggler = MouseJiggler.shared
    @State private var trusted = AXIsProcessTrusted()
    private let accessChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.accessibility.api"))

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Mouse Jiggler")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Spacer(minLength: 4)
                    if jiggler.isOn {
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                    }
                    Toggle("", isOn: Binding(get: { jiggler.isOn }, set: { jiggler.setOn($0); trusted = AXIsProcessTrusted() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.7)
                        .frame(width: 40)
                }
                if trusted {
                    HStack(spacing: 8) {
                        menu("Every", value: Self.duration(jiggler.interval)) {
                            ForEach(MouseJiggler.intervals, id: \.self) { s in
                                Button(Self.duration(s)) { jiggler.interval = s }
                            }
                        }
                        menu("Turn off", value: jiggler.autoOff == 0 ? "Never" : "after \(Self.duration(jiggler.autoOff))") {
                            ForEach(MouseJiggler.autoOffs, id: \.self) { s in
                                Button(s == 0 ? "Never" : "after \(Self.duration(s))") { jiggler.autoOff = s }
                            }
                        }
                    }
                    Toggle("Also switch apps and browser tabs", isOn: $jiggler.switchApps)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                    hint("Only while you're idle: moves the cursor to a random spot so you stay “Active” and the Mac stays awake.")
                } else {
                    HStack(spacing: 8) {
                        hint("Allow Accessibility so Coucou can nudge the cursor while you're away.")
                        smallButton("Allow…") { jiggler.requestAccess() }
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
        }
        .onAppear { trusted = AXIsProcessTrusted() }
        .onReceive(accessChanged) { _ in
            // The trust flag flips a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { trusted = AXIsProcessTrusted() }
        }
    }

    private var statusText: String {
        guard let stopsAt = jiggler.stopsAt else { return "Active" }
        return "Active · until \(stopsAt.formatted(date: .omitted, time: .shortened))"
    }

    static func duration(_ s: TimeInterval) -> String {
        s < 60 ? "\(Int(s)) s" : s < 3600 ? "\(Int(s / 60)) min" : "\(Int(s / 3600)) h"
    }

    private func menu<C: View>(_ label: String, value: String, @ViewBuilder content: () -> C) -> some View {
        Menu { content() } label: {
            Text("\(label) ").foregroundColor(Color(hex: "#8E939C")) + Text(value).foregroundColor(Color(hex: "#C5C8CD"))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(.system(size: 11))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color(hex: "#252830"))
        .clipShape(Capsule())
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(Color(hex: "#8E939C"))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity)
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color(hex: "#252830"))
            .foregroundColor(Color(hex: "#C5C8CD"))
            .clipShape(Capsule())
            .buttonStyle(.plain)
    }
}
#endif
