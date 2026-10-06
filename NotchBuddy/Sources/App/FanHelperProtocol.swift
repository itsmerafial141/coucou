import Foundation

/// XPC contract between Coucou and its root fan daemon (CoucouFanHelper).
/// Replies carry an error message, or nil on success.
@objc protocol FanHelperProtocol {
    /// Forces every fan to `fraction` of its range (0 = minimum, 1 = maximum).
    func setFans(fraction: Double, reply: @escaping @Sendable (String?) -> Void)
    /// Hands the fans back to macOS.
    func setAuto(reply: @escaping @Sendable (String?) -> Void)
}

enum FanHelperInfo {
    static let label = "fr.louisraille.NotchBuddy.FanHelper"
    static let plistName = "\(label).plist"
}
