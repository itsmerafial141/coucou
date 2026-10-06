import AppKit
import ApplicationServices
import os

/// Menu bar tray: a Coucou divider sits at the right end of the menu bar and stretches to push
/// every other icon off screen (so none end up behind the notch); the island's Menu Bar tab lists
/// them and clicking one shows the icons for a moment and presses it.
/// Clock and Control Center are pinned right of everything by macOS, so they stay visible.
@MainActor
final class MenuBarTray: ObservableObject {
    static let shared = MenuBarTray()

    struct Item: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
        let pid: pid_t
        let element: AXUIElement
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var revealed = false
    @Published var enabled = UserDefaults.standard.bool(forKey: "menuBarTrayEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "menuBarTrayEnabled")
            enabled ? install() : uninstall()
        }
    }

    private var divider: NSStatusItem?
    private var rehideTimer: Timer?
    private static let autosaveName = "CoucouTrayDivider"
    private static let hiddenLength: CGFloat = 10_000

    func start() {
        if enabled { install() }
        #if DEBUG
        // Test hook: `notifyutil`-style trigger from the terminal presses an icon by name.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("coucou.debug.trayPress"), object: nil, queue: .main
        ) { n in
            let name = n.object as? String ?? ""
            Task { @MainActor in
                let tray = MenuBarTray.shared
                tray.refresh()
                if let item = tray.items.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    trayLog("debug press \(item.name)")
                    tray.press(item)
                } else { trayLog("debug: no item named \(name): \(tray.items.map(\.name))") }
            }
        }
        #endif
    }

    // MARK: - Divider

    private func install() {
        guard divider == nil else { return }
        // Preferred position counts from the right edge: 0 puts the divider right of every
        // other movable icon on first launch. After that the user's ⌘-drag position is kept.
        let key = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(0, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: Self.hiddenLength)
        item.autosaveName = Self.autosaveName
        item.button?.setAccessibilityLabel("Coucou menu bar divider")
        item.button?.target = self
        item.button?.action = #selector(dividerClicked)
        divider = item
        hide()
    }

    private func uninstall() {
        rehideTimer?.invalidate()
        if let divider { NSStatusBar.system.removeStatusItem(divider) }
        divider = nil
        revealed = false
    }

    @objc private func dividerClicked() { hide() }

    func hide() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        divider?.length = Self.hiddenLength
        divider?.button?.image = nil
        revealed = false
    }

    /// Shows every icon again for a moment. Coucou becomes the active app first: an agent app
    /// has no menus, so the menu bar has the most room left of the notch.
    func reveal(watching pid: pid_t? = nil) {
        guard let divider else { return }
        NSApp.activate(ignoringOtherApps: true)
        divider.length = NSStatusItem.variableLength
        divider.button?.image = NSImage(systemSymbolName: "chevron.compact.right",
                                        accessibilityDescription: "Hide menu bar icons")
        revealed = true
        scheduleRehide(watching: pid)
    }

    /// While shown, hides again once the pressed app has no menu or popover open (checked twice a
    /// second, only while shown), or after 10 s when nothing was pressed.
    private func scheduleRehide(watching pid: pid_t?) {
        rehideTimer?.invalidate()
        let start = Date()
        rehideTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let age = Date().timeIntervalSince(start)
                if let pid {
                    if age > 1.5 && !Self.hasFloatingWindow(pid: pid) { self.hide() }
                } else if age > 10 {
                    self.hide()
                }
            }
        }
    }

    /// Menus and popovers live above the normal window layer.
    private static func hasFloatingWindow(pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 0) > 0
        }
    }

    // MARK: - Items (Accessibility)

    var canListItems: Bool {
        #if APPSTORE
        return false   // the sandbox has no Accessibility access
        #else
        return AXIsProcessTrusted()
        #endif
    }

    func requestAccess() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// Reads every app's menu bar icons. Runs only when the Menu Bar tab opens, never in the background.
    func refresh() {
        guard canListItems else { items = []; return }
        // ponytail: shows the app icon, not the exact menu bar glyph (that needs Screen Recording).
        let alwaysVisible: Set<String> = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"]
        var found: [(x: CGFloat, item: Item)] = []
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != getpid() {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.2)   // a hung app must not freeze the island
            guard let bar = Self.attr(ax, kAXExtrasMenuBarAttribute),
                  let kids = Self.attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]
            else { continue }
            let appName = app.localizedName ?? app.bundleIdentifier ?? "?"
            for (i, kid) in kids.enumerated() {
                AXUIElementSetMessagingTimeout(kid, 0.3)   // some apps block AXPress while their menu is open
                var pos = CGPoint.zero, size = CGSize.zero
                if let v = Self.attr(kid, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &pos) }
                if let v = Self.attr(kid, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
                // Skip placeholders (0 wide) and other apps' stretched dividers.
                guard size.width > 0, size.width < 200 else { continue }
                let ident = Self.attr(kid, kAXIdentifierAttribute) as? String ?? ""
                guard !alwaysVisible.contains(ident) else { continue }
                let label = [kAXDescriptionAttribute, kAXTitleAttribute]
                    .compactMap { Self.attr(kid, $0) as? String }.first { !$0.isEmpty }
                let name = label.map { $0.components(separatedBy: ",")[0] }
                    ?? (kids.count > 1 ? "\(appName) \(i + 1)" : appName)
                found.append((pos.x, Item(id: "\(app.processIdentifier)#\(i)", name: name,
                                          icon: app.icon ?? NSImage(), pid: app.processIdentifier,
                                          element: kid)))
            }
        }
        items = found.sorted { $0.x < $1.x }.map(\.item)
    }

    // MARK: - Opening an icon under the island

    /// Presses the hidden icon, then brings what opens under the island:
    /// - a plain menu is read, closed, and shown again as Coucou's own copy (picking an entry
    ///   presses the real one);
    /// - a new window (panel) is moved there.
    /// Popovers stay pinned to their icon, so for those the icons are shown in the menu bar and the
    /// icon is pressed there (remembered per icon, so the next click goes straight there).
    func press(_ item: Item) {
        trayLog("press \(item.name) anchored=\(anchoredItems.contains(item.id))")
        if anchoredItems.contains(item.id) { pressInMenuBar(item); return }
        guard let anchor = IslandWindowController.current?.islandBottomCenter() else { return }
        let before = Self.onscreenWindowIDs(item.pid)
        AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        // Some apps take well over a second to open (Electron/Tauri), hence the long deadline.
        waitForPopup(item, before: before, anchor: anchor, deadline: Date() + 2.5)
    }

    private var anchoredItems: Set<String> = []

    private func pressInMenuBar(_ item: Item) {
        reveal(watching: item.pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        }
    }

    private func waitForPopup(_ item: Item, before: Set<CGWindowID>, anchor: NSPoint, deadline: Date) {
        if let menu = Self.openMenu(of: item.element) {
            let entries = Self.readMenu(menu, path: [])
            trayLog("menu \(item.name): \(entries.count) entries")
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            showCopy(entries, of: item, at: anchor)
            return
        }
        if let frame = Self.newWindowFrame(pid: item.pid, excluding: before) {
            let axApp = AXUIElementCreateApplication(item.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.3)
            // Match by size: CG and AX origins can differ (e.g. by the menu bar height).
            let window = (Self.attr(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? [])
                .filter { let f = Self.frame(of: $0).size
                          return abs(f.width - frame.width) < 4 && abs(f.height - frame.height) < 4 }
                .min { Self.frame(of: $0).origin.distance(to: frame.origin)
                     < Self.frame(of: $1).origin.distance(to: frame.origin) }
            // No AX window to move (system panels), or a full-screen overlay (Claude): leave it be.
            let screenSize = NSScreen.screens.first { $0.frame.width >= frame.width * 0.98 }?.frame.size
            guard let window, screenSize == nil || frame.width < screenSize!.width * 0.8 else {
                trayLog("window \(item.name) left as is cg=\(frame) ax=\(window != nil)")
                return
            }
            let target = Self.move(window, under: anchor)
            trayLog("window \(item.name) cg=\(frame) ax=\(Self.frame(of: window)) target=\(target)")
            // Check a beat later: AppKit snaps popovers back to their (off-screen) icon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                if Self.frame(of: window).origin.distance(to: target) < 4 { return }
                trayLog("anchored \(item.name) now=\(Self.frame(of: window))")
                self.anchoredItems.insert(item.id)
                AXUIElementPerformAction(item.element, kAXPressAction as CFString)   // close it
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.pressInMenuBar(item) }
            }
            return
        }
        guard Date() < deadline else {
            // Nothing showed up: show the icons so the real one can be clicked (pressing again
            // could close something that opened late).
            trayLog("timeout \(item.name)")
            reveal(watching: nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForPopup(item, before: before, anchor: anchor, deadline: deadline)
        }
    }

    /// On-screen windows of the app, menu bar icons excluded (layer 25).
    private static func onscreenWindows(_ pid: pid_t) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && ($0[kCGWindowLayer as String] as? Int) != 25 }
    }

    private static func onscreenWindowIDs(_ pid: pid_t) -> Set<CGWindowID> {
        Set(onscreenWindows(pid).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    /// Frame (top-left global, like AX) of a window that appeared since `before`.
    private static func newWindowFrame(pid: pid_t, excluding before: Set<CGWindowID>) -> CGRect? {
        onscreenWindows(pid)
            .first { !before.contains(($0[kCGWindowNumber as String] as? CGWindowID) ?? 0) }
            .flatMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = attr(element, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = attr(element, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    private static func openMenu(of element: AXUIElement) -> AXUIElement? {
        (attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .first { attr($0, kAXRoleAttribute) as? String == kAXMenuRole }
    }

    /// Centres the window horizontally under the island (AX uses top-left global coordinates).
    @discardableResult
    private static func move(_ window: AXUIElement, under anchor: NSPoint) -> CGPoint {
        let size = frame(of: window).size
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        var origin = CGPoint(x: anchor.x - size.width / 2, y: primaryMaxY - anchor.y + 6)
        if let v = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
        return origin
    }

    // MARK: - Menu copy

    struct MenuEntry {
        let title: String
        let enabled: Bool
        let checked: Bool
        let path: [Int]
        let children: [MenuEntry]
        var isSeparator: Bool { title.isEmpty && children.isEmpty }
    }

    private static func readMenu(_ menu: AXUIElement, path: [Int]) -> [MenuEntry] {
        let kids = attr(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return kids.enumerated().map { i, el in
            let sub = path.count < 3 ? openMenu(of: el).map { readMenu($0, path: path + [i]) } ?? [] : []
            return MenuEntry(title: attr(el, kAXTitleAttribute) as? String ?? "",
                             enabled: attr(el, kAXEnabledAttribute) as? Bool ?? false,
                             checked: !((attr(el, kAXMenuItemMarkCharAttribute) as? String) ?? "").isEmpty,
                             path: path + [i], children: sub)
        }
    }

    private var pendingItem: Item?

    private func showCopy(_ entries: [MenuEntry], of item: Item, at anchor: NSPoint) {
        pendingItem = item
        let menu = buildMenu(entries)
        // Run after the real menu has finished closing.
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.x - menu.size.width / 2, y: anchor.y - 4), in: nil)
        }
    }

    private func buildMenu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for e in entries {
            if e.isSeparator { menu.addItem(.separator()); continue }
            let mi = NSMenuItem(title: e.title, action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.isEnabled = e.enabled
            mi.state = e.checked ? .on : .off
            mi.representedObject = e
            if !e.children.isEmpty { mi.submenu = buildMenu(e.children) }
            menu.addItem(mi)
        }
        return menu
    }

    /// Re-opens the real menu out of sight and presses the matching entry (title first, index as fallback).
    @objc private func pick(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MenuEntry, let item = pendingItem else { return }
        AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        pressEntry(entry, in: item, deadline: Date() + 1)
    }

    private func pressEntry(_ entry: MenuEntry, in item: Item, deadline: Date) {
        guard var menu = Self.openMenu(of: item.element) else {
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.pressEntry(entry, in: item, deadline: deadline)
                }
            }
            return
        }
        var target: AXUIElement?
        for (depth, index) in entry.path.enumerated() {
            let kids = Self.attr(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let wanted = depth == entry.path.count - 1 ? entry.title : nil
            let el = kids.first { wanted != nil && Self.attr($0, kAXTitleAttribute) as? String == wanted }
                ?? (index < kids.count ? kids[index] : nil)
            guard let el else { break }
            if depth == entry.path.count - 1 { target = el } else if let sub = Self.openMenu(of: el) { menu = sub } else { break }
        }
        if let target {
            AXUIElementPerformAction(target, kAXPressAction as CFString)
        } else {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
}

private extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}

func trayLog(_ s: String) {
    #if DEBUG
    Logger(subsystem: "fr.louisraille.NotchBuddy", category: "tray").notice("\(s, privacy: .public)")
    #endif
}
