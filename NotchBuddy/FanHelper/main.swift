import Foundation
import Security

// CoucouFanHelper: root launchd daemon (registered by Coucou with SMAppService) that writes
// the SMC fan keys. It only accepts connections from Coucou signed by the same team, and
// hands the fans back to macOS whenever Coucou disconnects (quit, crash) or the CPU gets too hot.

final class FanService: NSObject, FanHelperProtocol, @unchecked Sendable {
    private let smc = SMC()
    private let queue = DispatchQueue(label: "fan")
    private(set) var forced = false

    func setFans(fraction: Double, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { reply(self.force(fraction: min(1, max(0, fraction)))) }
    }

    func setAuto(reply: @escaping @Sendable (String?) -> Void) {
        queue.async { reply(self.release() ? nil : "Could not hand the fans back to macOS") }
    }

    private func force(fraction: Double) -> String? {
        let fans = smc.fans()
        guard !fans.isEmpty else { return "No fans found" }
        // Apple Silicon: "Ftst" = 1 asks thermalmonitord to let go; the mode key accepts
        // writes a moment later, so retry for up to ~4 s.
        smc.write("Ftst", [1])
        for i in fans.indices {
            var ok = false
            for _ in 0..<40 where !ok {
                ok = smc.write("F\(i)Md", [1])
                if !ok { Thread.sleep(forTimeInterval: 0.1) }
            }
            guard ok else { release(); return "The SMC refused manual fan mode" }
            let f = fans[i]
            smc.write("F\(i)Tg", float: Float(f.min + (f.max - f.min) * fraction))
        }
        forced = true
        return nil
    }

    @discardableResult
    func release() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        var ok = true
        for i in smc.fans().indices { ok = smc.write("F\(i)Md", [0]) && ok }
        smc.write("Ftst", [0])
        forced = false
        return ok
    }

    func releaseAsync() { queue.async { if self.forced { self.release() } } }

    /// Safety net: a forced fan never stays slow on a hot Mac.
    func checkHeat() {
        queue.async {
            guard self.forced, let t = self.smc.average(prefix: "Tp"), t >= 95 else { return }
            self.release()
        }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    let service = FanService()
    private let requirement: String?

    override init() {
        // Accept only Coucou signed with this helper's own team (whoever signed the build).
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        SecCodeCopySelf([], &code)
        if let code { SecCodeCopyStaticCode(code, [], &staticCode) }
        if let staticCode { SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) }
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        requirement = team.map {
            "identifier \"fr.louisraille.NotchBuddy\" and anchor apple generic and certificate leaf[subject.OU] = \"\($0)\""
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        c.setCodeSigningRequirement(requirement)
        c.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        c.exportedObject = service
        let service = self.service
        c.invalidationHandler = { service.releaseAsync() }
        c.interruptionHandler = { service.releaseAsync() }
        c.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener(machServiceName: FanHelperInfo.label)
listener.delegate = delegate
listener.resume()
let heat = DispatchSource.makeTimerSource()
heat.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
heat.setEventHandler { delegate.service.checkHeat() }
heat.resume()
dispatchMain()
