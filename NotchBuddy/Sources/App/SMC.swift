import Foundation
import IOKit

/// AppleSMC client. Reads work as any user; writes (fan control) need root, so only
/// the CoucouFanHelper daemon calls `write`. Shared by the app and the helper target.

final class SMC: @unchecked Sendable {
    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        // C pads this to 12 bytes; Swift would place the next field at 9 without the explicit pad.
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0
    private lazy var tempKeys: [String: [String]] = enumerateTemps()

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if svc != 0 { IOServiceOpen(svc, mach_task_self_, 0, &conn); IOObjectRelease(svc) }
    }

    /// Mean of the sane readings of every SMC temperature key starting with `prefix`
    /// ("Tp" = CPU cores, "Tg" = GPU on Apple Silicon).
    func average(prefix: String) -> Double? {
        let keys = tempKeys[prefix] ?? []
        let v = keys.compactMap { value($0) }.filter { $0 > 10 && $0 < 130 }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    struct Fan: Equatable, Sendable { var name: String; var rpm: Double; var min: Double; var max: Double; var mode: Int; var target: Double }

    func fans() -> [Fan] {
        let n = Int(value("FNum") ?? 0)
        let names = n == 2 ? ["Left", "Right"] : (0..<n).map { "Fan \($0 + 1)" }
        return (0..<n).map { i in
            Fan(name: names[i], rpm: value("F\(i)Ac") ?? 0, min: value("F\(i)Mn") ?? 0, max: value("F\(i)Mx") ?? 0,
                mode: Int(value("F\(i)Md") ?? 0), target: value("F\(i)Tg") ?? 0)
        }
    }

    /// Writes raw bytes to a key whose size matches. Root only.
    @discardableResult
    func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        var info = KeyData(); info.key = Self.code(key); info.data8 = 9
        guard let i = call(&info), Int(i.keyInfo.dataSize) == bytes.count else { return false }
        var w = KeyData(); w.key = info.key; w.keyInfo.dataSize = i.keyInfo.dataSize; w.data8 = 6
        withUnsafeMutableBytes(of: &w.bytes) { buf in for (n, b) in bytes.enumerated() { buf[n] = b } }
        return call(&w) != nil
    }

    @discardableResult
    func write(_ key: String, float: Float) -> Bool {
        write(key, withUnsafeBytes(of: float.bitPattern.littleEndian) { Array($0) })
    }

    private func enumerateTemps() -> [String: [String]] {
        var out: [String: [String]] = [:]
        let count = Int(value("#KEY") ?? 0)
        for i in 0..<UInt32(min(count, 4000)) {
            var input = KeyData(); input.data8 = 8; input.data32 = i
            guard let o = call(&input) else { break }
            let name = Self.string(o.key)
            for p in ["Tp", "Tg"] where name.hasPrefix(p) { out[p, default: []].append(name) }
        }
        return out
    }

    func value(_ key: String) -> Double? {
        var info = KeyData(); info.key = Self.code(key); info.data8 = 9
        guard let i = call(&info) else { return nil }
        var read = KeyData(); read.key = info.key; read.keyInfo.dataSize = i.keyInfo.dataSize; read.data8 = 5
        guard let o = call(&read) else { return nil }
        let b = withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(i.keyInfo.dataSize))) }
        switch Self.string(i.keyInfo.dataType) {
        case "flt " where b.count == 4: return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 ": return b.first.map(Double.init)
        case "ui16" where b.count == 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count == 4: return Double(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "fpe2" where b.count == 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "sp78" where b.count == 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        default: return nil
        }
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        guard conn != 0 else { return nil }
        var out = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &out, &size)
        return r == kIOReturnSuccess && out.result == 0 ? out : nil
    }

    static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    static func string(_ c: UInt32) -> String {
        String(bytes: [UInt8(c >> 24), UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)], encoding: .ascii) ?? ""
    }
}
