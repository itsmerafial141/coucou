import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandWindowController: NSWindowController {

    private var islandPanel: IslandPanel!
    /// NSApp.delegate is SwiftUI's adaptor, not AppDelegate, so reach the island through this.
    private(set) static weak var current: IslandWindowController?
    private var state: AppState { AppState.shared }

    // State machine (replaces all hover/absence/auto-close timers)
    let fsm = IslandStateMachine()

    private var wasInIsland = false
    private var leaveDeferredByDrag = false
    private var frameTimer: Timer?
    private var keyMonitor: Any?
    private var viewSubscription: AnyCancellable?

    // Finished-pin timer
    private var finishedPinTimer: DispatchWorkItem?

    private var pendingIslandClick = false   // any island click → expand on mouseUp

    // Notch real dimensions (set on init)
    private var notchW: CGFloat = IslandConst.notchWidth
    private var notchH: CGFloat = IslandConst.notchHeight
    private var hasNotch = true
    private var isMovingScreen = false

    // Island-local key monitor (active only when island is key window)
    private var localKeyMonitor: Any?

    convenience init() {
        let screen = Self.notchScreen() ?? NSScreen.main!
        let geometry = Self.screenGeometry(for: screen)
        let nW = geometry.width
        let nH = geometry.height

        let panelW: CGFloat = 720
        let panelH: CGFloat = 320
        let sf = screen.frame
        let panel = IslandPanel(
            contentRect: NSRect(x: sf.midX - panelW/2, y: sf.maxY - panelH,
                                width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.notchWidth  = nW
        panel.notchHeight = nH

        self.init(window: panel)
        self.islandPanel = panel
        Self.current = self
        self.notchW = nW
        self.notchH = nH
        self.hasNotch = geometry.hasNotch
        setupPanel(screen: screen)
    }

    private func setupPanel(screen: NSScreen) {
        guard let panel = window as? IslandPanel else { return }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        // Propagate real notch dimensions to AppState
        AppState.shared.notchWidth  = notchW
        AppState.shared.notchHeight = notchH
        AppState.shared.hasNotch = hasNotch

        let contentSize = panel.contentRect(forFrameRect: panel.frame).size

        // Apple-recommended pattern: put NSHostingView and drag destination as siblings
        // inside a common superview, rather than embedding one inside the other.
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: IslandRootView().environmentObject(AppState.shared))
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]

        // FileDropNSView sits below the hosting view (hitTest returns nil → no mouse interference).
        // AppKit routes NSDraggingDestination events to registered views independently of hitTest.
        let dropView = FileDropNSView(frame: NSRect(origin: .zero, size: contentSize))
        dropView.autoresizingMask = [.width, .height]
        dropView.onDragEntered = { _ in
            Task { @MainActor in
                AppState.shared.fileDragOver = true
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.upload)
            }
        }
        dropView.onDragExited = {
            Task { @MainActor in
                // Do NOT collapse — drag session still active; island stays open.
                AppState.shared.fileDragOver = false
            }
        }
        dropView.onFilesDropped = { urls in
            Task { @MainActor in
                await FileDropHandler.handle(urls: urls, state: AppState.shared)
            }
        }

        container.addSubview(hosting)    // z-bottom: SwiftUI + mouse events
        container.addSubview(dropView)   // z-top: drag only (hitTest→nil, transparent to mouse)
        panel.contentView = container

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.moveToMouseScreen(force: true) }
        }

        startPolling()
        startKeyMonitor()
        startClickOutsideMonitor()
        startLocalKeyMonitor()
        startHotKeys()
        wireFSM()

        // Make panel key whenever the prompt/chat view becomes active
        // (nonactivatingPanel never auto-becomes key, but TextField needs it)
        viewSubscription = state.$view
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newView in
                guard let self else { return }
                if newView == .prompt {
                    self.islandPanel.makeKey()
                }
            }
    }

    // MARK: - FSM wiring

    private func wireFSM() {
        fsm.onTransition = { [weak self] from, to in
            guard let self else { return }
            switch to {
            case .hidden:
                self.setMode(.hidden)

            case .petit:
                // No peek sound: the compact island stays invisible unless it carries a notice.
                // setMode BEFORE changing view: onChange(of: state.view) guards on .expanded,
                // so setting view while already compact won't trigger a spurious open animation.
                self.setMode(.compact)
                // Start 60s hide timer if mouse is not currently over the island
                if !self.wasInIsland { self.fsm.mouseLeft() }

            case .home:
                self.expand(to: self.defaultView())
                // Start collapse timer if mouse not currently hovering
                if !self.wasInIsland {
                    self.fsm.mouseLeft()
                }
            }
        }

        #if !APPSTORE
        fsm.isHeldOpen = { AppState.shared.pendingApproval != nil || LoomifyService.shared.pendingNotice }
        #else
        fsm.isHeldOpen = { AppState.shared.pendingApproval != nil }
        #endif
    }

    // MARK: - 30 Hz polling loop

    private func startPolling() {
        // Hover detection only (no character tracking the cursor any more): 30 Hz is plenty.
        // Fires on the main run loop, so run synchronously instead of spawning a Task per tick.
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFrame() }
        }
        frameTimer?.tolerance = 1.0/60.0
        RunLoop.main.add(frameTimer!, forMode: .common)
    }

    /// Inputs of the last pollFrame(); an identical tick has nothing to update.
    private struct PollInputs: Equatable {
        var mouse: CGPoint, panelFrame: CGRect, islandRect: CGRect, buttons: Int
    }
    private var lastPollInputs: PollInputs?

    private func pollFrame() {
        guard let panel = window as? IslandPanel else { return }

        let mouse = NSEvent.mouseLocation

        // AppState can hide the island by itself (last task ended): keep the FSM in step.
        if state.mode == .hidden && fsm.state == .petit { fsm.hiddenExternally() }

        // Idle skip: mouse still, panel/island unchanged, no drag in flight → nothing to do.
        // ponytail: still a 30 Hz wakeup; swap for mouseMoved monitors if idle CPU still matters.
        let inputs = PollInputs(mouse: mouse, panelFrame: panel.frame,
                                islandRect: panel.currentIslandFrame(nw: notchW, nh: notchH),
                                buttons: NSEvent.pressedMouseButtons)
        if inputs == lastPollInputs && !leaveDeferredByDrag { return }
        lastPollInputs = inputs

        moveToMouseScreen()

        // Convert mouse to panel-local coords (macOS: origin bottom-left)
        let pf = panel.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)

        // Island rect in panel coords
        let islandRect = panel.currentIslandFrame(nw: notchW, nh: notchH)
        // On a screen without a notch, the resting bar must not intercept clicks
        // in the app window immediately below the menu bar.
        let hoverRect = !hasNotch && state.mode != .expanded
            ? islandRect : islandRect.insetBy(dx: -6, dy: -6)
        let inIsland = hoverRect.contains(local)

        // Toggle click-through
        let shouldAcceptMouse = inIsland
        if panel.ignoresMouseEvents == shouldAcceptMouse {
            panel.ignoresMouseEvents = !shouldAcceptMouse
            if shouldAcceptMouse, let cv = panel.contentView {
                panel.invalidateCursorRects(for: cv)
            }
        }

        // Feed FSM hover enter/leave
        if inIsland && !wasInIsland {
            #if !APPSTORE
            LoomifyService.shared.hovered()   // before the FSM: no longer held open, hover opens as usual
            #endif
            fsm.mouseEntered()
        }
        if !inIsland && wasInIsland {
            if NSEvent.pressedMouseButtons != 0 {
                // A drag left the island (e.g. a file pulled off the shelf): folding now would
                // drop the drag source, so wait until the button is released.
                leaveDeferredByDrag = true
            } else {
                // Fold right away on leave, except when pinned or typing in the chat.
                fsm.mouseLeft(quick: !state.isPinned && state.view != .prompt)
            }
        }
        if leaveDeferredByDrag && NSEvent.pressedMouseButtons == 0 {
            leaveDeferredByDrag = false
            if !inIsland { fsm.mouseLeft(quick: !state.isPinned && state.view != .prompt) }
        }
        wasInIsland = inIsland
    }

    // MARK: - Mode transitions

    private func modeLevel(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }

    func setMode(_ mode: IslandMode) {
        let prev = state.mode
        guard mode != prev else { return }
        let shrinking = modeLevel(mode) < modeLevel(prev)
        let anim: Animation = shrinking
            ? .timingCurve(0.45, 0, 0.2, 1, duration: 0.34)
            : .spring(response: 0.5, dampingFraction: 0.72)
        withAnimation(anim) { state.mode = mode }
        if mode == .expanded { SoundEngine.shared.play("open") }
        if prev == .expanded {
            SoundEngine.shared.play("close")
            if fsm.isHeldOpen?() != true { state.isPinned = false }
        }
    }

    func expand(to view: IslandView) {
        state.view = view
        if state.mode == .expanded {
            // Already expanded — just switch view
        } else {
            setMode(.expanded)
        }
        state.lastActivity = .now
    }

    /// Opened by a shortcut (or an alert) rather than by the mouse: keep the FSM in step so
    /// hover timers can't fold it or switch its view, and don't fold just because the mouse
    /// is elsewhere. It closes on the shortcut again, Esc, a click outside, or the 15 s timer.
    func openExplicitly(to view: IslandView) {
        fsm.openedExternally()
        expand(to: view)
        if wasInIsland {
            fsm.mouseEntered()                  // mouse is already on it → normal hover rules
        } else if ![.prompt, .approval, .question].contains(view) {
            fsm.mouseLeft()                     // 15 s fallback, never while chatting or answering
        }
    }

    func collapse() {
        guard fsm.isHeldOpen?() != true else { return }
        state.isPinned = false
        finishedPinTimer?.cancel()
        // Keep the FSM in step with what is on screen (home → petit now).
        fsm.collapse()
        setMode(.compact)
        window?.resignKey()
    }

    // MARK: - Global hot keys (Carbon)

    private func startHotKeys() {
        HotKeyCenter.shared.start { [weak self] action in
            self?.handleHotKey(action)
        }
    }

    func handleHotKey(_ action: ShortcutAction) {
        switch action {
        case .toggleIsland:
            if state.mode == .expanded {
                collapse()
            } else {
                islandPanel.makeKey()
                openExplicitly(to: defaultView())
            }

        case .openChat:
            islandPanel.makeKey()
            openExplicitly(to: .prompt)

        case .goToAlert:
            if state.pendingApproval != nil {
                islandPanel.makeKey()
                openExplicitly(to: .approval)
            } else if state.pendingQuestion != nil {
                islandPanel.makeKey()
                openExplicitly(to: .question)
            } else {
                SoundEngine.shared.play("error")
            }

        case .jumpToTerminal:
            #if !APPSTORE
            performJumpToTerminal()
            #endif

        case .attachFrontWindow:
            #if !APPSTORE
            performAttachFrontWindow()
            #endif

        case .nextPill:
            cyclePill(by: +1)

        case .prevPill:
            cyclePill(by: -1)

        case .muteToggle:
            state.soundEnabled.toggle()
            if state.soundEnabled { SoundEngine.shared.play("tick") }

        case .openClipboard:
            if state.mode == .expanded && state.view == .clipboard {
                collapse()
            } else {
                islandPanel.makeKey()
                openExplicitly(to: .clipboard)
            }
        }
    }

    // MARK: - Island-local shortcuts

    private func startLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.islandPanel.isKeyWindow else { return event }
            return self.handleIslandKey(event) ? nil : event
        }
    }

    @discardableResult
    private func handleIslandKey(_ event: NSEvent) -> Bool {
        let raw = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let cmd = raw == .command

        // 1–9 in the Clipboard tab — copy the nth card (unless typing in the search field)
        if raw.isEmpty && state.view == .clipboard && !(islandPanel.firstResponder is NSText),
           let n = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(n) {
            NotificationCenter.default.post(name: .clipboardPick, object: n)
            return true
        }

        // ⌘→ — next pill
        if cmd && event.keyCode == 124 { cyclePill(by: +1); return true }
        // ⌘← — previous pill
        if cmd && event.keyCode == 123 { cyclePill(by: -1); return true }
        // ⌘↓ — navigate list down
        if cmd && event.keyCode == 125 { navigateCard(by: +1); return true }
        // ⌘↑ — navigate list up
        if cmd && event.keyCode == 126 { navigateCard(by: -1); return true }
        // ⌘O — open selected card item
        if cmd && event.keyCode == 31  { openCardSelection(); return true }
        // ⌘E — toggle diff
        if cmd && event.keyCode == 14 && state.view == .overview {
            NotificationCenter.default.post(name: .islandToggleDiff, object: nil)
            return true
        }
        // ⌘↩ — send chat message
        if cmd && event.keyCode == 36 && state.view == .prompt {
            NotificationCenter.default.post(name: .islandSendMessage, object: nil)
            return true
        }
        // ⌘K — new conversation
        if cmd && event.keyCode == 40 && state.view == .prompt {
            NotificationCenter.default.post(name: .islandNewConversation, object: nil)
            return true
        }
        // ⌘, — open Settings
        if cmd && event.keyCode == 43 {
            NotificationCenter.default.post(name: .openFullSettings, object: nil)
            return true
        }
        // ⌘P — pin / unpin
        if cmd && event.keyCode == 35 {
            state.isPinned.toggle()
            return true
        }
        // ⌘1–⌘9 — switch to pill by number
        let digitCodes: [UInt16: Int] = [18:1,19:2,20:3,21:4,23:5,22:6,26:7,28:8,25:9]
        if cmd, let n = digitCodes[event.keyCode] {
            switchToPill(number: n); return true
        }
        // ⎋ Escape — focused views (.onExitCommand) have first crack; fall back to collapse
        if event.keyCode == 53 && raw.isEmpty {
            // The chat box's text field always "accepts" cancelOperation: (and does nothing),
            // which used to swallow Esc in the chat. The chat has no Esc action of its own.
            let consumed = state.view != .prompt
                && NSApp.sendAction(Selector(("cancelOperation:")), to: nil, from: nil)
            if !consumed && state.mode == .expanded && !state.isPinned {
                collapse()
            }
            return true
        }
        return false
    }

    // MARK: - Pill cycling helpers

    private func cyclePill(by delta: Int) {
        guard !state.tasks.isEmpty else { return }
        let ids = state.tasks.map { $0.id }
        let cur = ids.firstIndex(of: state.focusId ?? "") ?? 0
        state.setFocus(ids[(cur + delta + ids.count) % ids.count])
        state.cardSelection = nil
        expand(to: .overview)
    }

    private func switchToPill(number: Int) {
        guard number >= 1, number <= state.tasks.count else { return }
        state.setFocus(state.tasks[number - 1].id)
        state.cardSelection = nil
        expand(to: .overview)
    }

    private func navigateCard(by delta: Int) {
        guard state.cardItemCount > 0 else { return }
        state.cardSelection = ShortcutLogic.navigate(
            selection: state.cardSelection, delta: delta, itemCount: state.cardItemCount)
    }

    private func openCardSelection() {
        guard state.cardSelection != nil else { return }
        NotificationCenter.default.post(name: .islandActivateCardSelection, object: nil)
    }

    // MARK: - Terminal jump

    #if !APPSTORE
    private func performJumpToTerminal() {
        guard state.focusTask != nil else {
            SoundEngine.shared.play("error")
            return
        }
        let terminalBundleIds = ["com.apple.Terminal", "com.googlecode.iterm2",
                                 "net.kovidgoyal.kitty", "com.mitchellh.ghostty"]
        let activated = terminalBundleIds.compactMap { id in
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
        }.first.map { $0.activate(options: .activateIgnoringOtherApps) }
        if activated == nil {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
        collapse()
    }

    private func performAttachFrontWindow() {
        guard let app = state.lastExternalApp else {
            SoundEngine.shared.play("error"); return
        }
        guard let ctx = WindowContextCapture.captureActive(from: app) else {
            SoundEngine.shared.play("error"); return
        }
        state.promptContext = ctx
        SoundEngine.shared.play("approve")
        islandPanel.makeKey()
        expand(to: .prompt)
    }
    #endif

    // MARK: - Keyboard (Escape closes)

    private func startClickOutsideMonitor() {
        // Global monitors only see clicks in other apps, i.e. outside the island.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.mode == .expanded, !self.state.isPinned else { return }
                self.collapse()   // no-op while an approval holds it open
            }
        }
    }

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                if event.keyCode == 53 { // Escape
                    if self.state.mode == .expanded && !self.state.isPinned {
                        self.collapse()
                    }
                }
            }
        }

        // Hook server expand requests (alerts only)
        NotificationCenter.default.addObserver(forName: .hookExpand, object: nil, queue: .main) { [weak self] note in
            guard let self, let view = note.object as? IslandView else { return }
            self.openExplicitly(to: view)
        }

        // Hook server compact reveal (non-alert work events: session start, tool use, etc.)
        NotificationCenter.default.addObserver(forName: .hookReveal, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.fsm.reveal()
        }

        // Music started playing: reveal silently (no peek sound)
        NotificationCenter.default.addObserver(forName: .musicReveal, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.fsm.reveal()
        }

        // Collapse requests from views (OK button, etc.)
        NotificationCenter.default.addObserver(forName: .islandCollapse, object: nil, queue: .main) { [weak self] _ in
            self?.collapse()
        }

        // Any click on the island → expand on mouseUp.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                if self.wasInIsland { self.pendingIslandClick = true }
            }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                let hadPendingClick = self.pendingIslandClick
                self.pendingIslandClick = false
                if hadPendingClick && self.state.mode != .expanded {
                    if self.fsm.state == .home {
                        // FSM already thinks it's open (e.g. the view folded it): just reopen.
                        self.expand(to: self.defaultView())
                    } else {
                        self.fsm.click()   // FSM petit/hidden→home; onTransition calls expand(to:)
                    }
                }
            }
            return event
        }

        // Track last external app for window context capture
        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != ourBundle {
                self.state.lastExternalApp = app
            }
        }
    }

    // MARK: - Helpers

    func defaultView() -> IslandView {
        if state.pendingApproval != nil { return .approval }
        return state.tasks.isEmpty ? .empty : .overview
    }

    func baseMode() -> IslandMode {
        guard state.isPresent else { return .hidden }
        return state.tasks.isEmpty ? .hidden : .compact
    }

    // MARK: - Activity reset (call on any user interaction in island)

    func resetActivity() {
        state.lastActivity = .now
    }

    // MARK: - Finished task pin (5.2s)

    func pinForFinished(taskId: String) {
        state.isPinned = true
        finishedPinTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.removeTask(id: taskId)
            self.state.isPinned = false
            self.collapse()
        }
        finishedPinTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2, execute: item)
    }

    // MARK: - Multi-screen: the island follows the screen under the cursor

    private func moveToMouseScreen(force: Bool = false) {
        guard let panel = islandPanel, !isMovingScreen else { return }
        let mouse = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        else { return }
        let current = NSScreen.screens.first { $0.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.maxY - 1)) }
        if !force {
            // Never pull the island away while it is open or the user is dragging something.
            guard target != current, state.mode != .expanded,
                  NSEvent.pressedMouseButtons == 0 else { return }
        }

        let geometry = Self.screenGeometry(for: target)
        notchW = geometry.width
        notchH = geometry.height
        hasNotch = geometry.hasNotch
        panel.notchWidth = notchW
        panel.notchHeight = notchH
        AppState.shared.notchWidth = notchW
        AppState.shared.notchHeight = notchH
        AppState.shared.hasNotch = hasNotch

        let sf = target.frame
        let dest = NSRect(origin: NSPoint(x: sf.midX - panel.frame.width / 2,
                                          y: sf.maxY - panel.frame.height),
                          size: panel.frame.size)
        guard current != nil, target != current else {   // same screen re-laid out, or panel off-screen
            panel.setFrame(dest, display: true)
            return
        }

        // Hero move: glide along the top edge to the new screen, dipping the opacity so the
        // hop across the display boundary reads as one motion. The shape morphs meanwhile
        // (notch ↔ resting bar) through IslandRootView's onChange of the notch size.
        isMovingScreen = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.25
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            })
        })
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(dest, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                panel.alphaValue = 1
                self?.isMovingScreen = false
            }
        })
    }

    /// Bottom-centre of the island in screen coordinates (Menu Bar tab menus open here).
    func islandBottomCenter() -> NSPoint? {
        guard let panel = islandPanel else { return nil }
        let f = panel.currentIslandFrame(nw: notchW, nh: notchH)
        return NSPoint(x: panel.frame.minX + f.midX, y: panel.frame.minY + f.minY)
    }

    /// The screen the island currently sits on (falls back to the notch screen, then main).
    static func islandScreen() -> NSScreen? {
        current?.window?.screen
            ?? notchScreen() ?? NSScreen.main
    }

    // MARK: - Notch detection (static)

    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    static func screenGeometry(for screen: NSScreen) -> IslandScreenGeometry {
        let visibleMenuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        // visibleFrame includes the menu bar only while it is visible. Keep a
        // small resting bar when menus auto-hide or the app is in full screen.
        let menuBarHeight = visibleMenuBarHeight > 0
            ? visibleMenuBarHeight : NSStatusBar.system.thickness
        return IslandScreenGeometry(
            screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: menuBarHeight
        )
    }

    nonisolated func cleanup() {
        // Called explicitly before release if needed
    }
}

// MARK: - IslandPanel

final class IslandPanel: NSPanel {
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    /// Allow panel to sit in the menu bar / notch area — don't let macOS push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    func currentIslandFrame(nw: CGFloat, nh: CGFloat) -> CGRect {
        let s = AppState.shared
        let (w, fixedH) = islandSize(mode: s.mode, view: s.view,
                                      progress: s.uploadProgress, nw: nw, nh: nh)
        let h: CGFloat
        if s.mode == .expanded && s.view == .prompt {
            let base: CGFloat = 240
            let perMsg: CGFloat = 40
            h = min(300, base + CGFloat(s.chatHistory.count) * perMsg)
        } else {
            h = fixedH
        }
        // The compact notice grows the island to the right only: same left edge, wider.
        let extra = s.mode == .compact && s.compactNotice != nil ? compactNoticeExtra(nw: nw) : 0
        return CGRect(x: (frame.width - w) / 2, y: frame.height - h, width: w + extra, height: h)
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let clipboardPick    = Notification.Name("notchBuddy.clipboardPick")
    static let islandAction     = Notification.Name("notchBuddy.islandAction")
    static let islandCollapse      = Notification.Name("notchBuddy.islandCollapse")
    static let islandSendMessage   = Notification.Name("notchBuddy.islandSendMessage")
    static let islandNewConversation = Notification.Name("notchBuddy.islandNewConversation")
    static let islandToggleDiff           = Notification.Name("notchBuddy.islandToggleDiff")
    static let islandActivateCardSelection = Notification.Name("notchBuddy.islandActivateCardSelection")
    static let openFullSettings    = Notification.Name("notchBuddy.openFullSettings")
    static let hookReveal       = Notification.Name("notchBuddy.hookReveal")
    static let musicReveal      = Notification.Name("notchBuddy.musicReveal")
}

// MARK: - islandSize (takes real notch dimensions)

/// Extra width of the compact island while it shows a notice, all of it right of the notch:
/// up to 180 pt, never past the 720 pt panel (8 pt margin).
func compactNoticeExtra(nw: CGFloat) -> CGFloat {
    max(0, min(180, 720 / 2 - nw / 2 - 80 - 8))
}

@MainActor
func islandSize(mode: IslandMode, view: IslandView,
                progress: Double = 0,
                nw: CGFloat = IslandConst.notchWidth,
                nh: CGFloat = IslandConst.notchHeight) -> (CGFloat, CGFloat) {
    switch mode {
    case .hidden:   return (nw, nh)
    // No character in the ears any more: compact looks like hidden unless a notice needs the room.
    case .compact:  return AppState.shared.compactNotice == nil ? (nw, nh) : (nw + 160, nh)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        return (IslandConst.expandedWidth, layout.height)
    }
}
