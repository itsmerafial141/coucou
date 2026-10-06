import SwiftUI

/// Island tab listing the menu bar icons hidden by `MenuBarTray`.
struct MenuBarTrayView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var tray = MenuBarTray.shared
    @State private var hovered: String? = nil
    // macOS posts this whenever an app's Accessibility permission changes (no polling).
    private let accessChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.accessibility.api"))

    private let rows = Array(repeating: GridItem(.fixed(36), spacing: 2), count: 2)

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Menu Bar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Spacer(minLength: 4)
                    if tray.enabled {
                        Text(tray.canListItems ? "\(tray.items.count) icons" : "")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                        smallButton(tray.revealed ? "Hide" : "Show in menu bar") {
                            tray.revealed ? tray.hide() : tray.reveal()
                        }
                    }
                    Toggle("", isOn: $tray.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.7)
                        .frame(width: 40)
                }
                content
            }
            .padding(.leading, 84)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
        }
        .onAppear { tray.refresh() }
        .onChange(of: state.view) { _, v in if v == .menuBar { tray.refresh() } }
        .onChange(of: tray.enabled) { _, _ in tray.refresh() }
        .onReceive(accessChanged) { _ in
            // The trust flag flips a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tray.refresh() }
        }
    }

    @ViewBuilder private var content: some View {
        if !tray.enabled {
            hint("Hide every menu bar icon so none end up behind the notch, and open them from here.")
        } else if !tray.canListItems {
            #if APPSTORE
            hint("Icons are hidden. Use “Show in menu bar” to reach them for a moment.")
            #else
            HStack(spacing: 8) {
                hint("Allow Accessibility to list the icons here and open them with a click.")
                smallButton("Allow…") { tray.requestAccess() }
            }
            #endif
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: rows, spacing: 4) {
                    ForEach(tray.items) { item in
                        Button { tray.press(item) } label: {
                            Image(nsImage: item.icon)
                                .resizable()
                                .frame(width: 26, height: 26)
                                .frame(width: 36, height: 36)
                            .background(hovered == item.id ? Color.white.opacity(0.07) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .help(item.name)
                        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                    }
                }
            }
        }
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
