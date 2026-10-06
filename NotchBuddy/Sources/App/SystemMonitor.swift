import AppKit
import IOKit
import IOKit.ps
import ServiceManagement

/// Stats-like system readings for the island's System tab.
/// Samples every 2 s only while the tab is open; otherwise a 10 s temperature check drives the
/// "too hot" notch ear (`hot`). Fans are switched through CoucouFanHelper, Coucou's own root daemon.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    static let hotOn = 85.0, hotOff = 80.0

    typealias Fan = SMC.Fan
    enum FanMode { case auto, max, manual }

    @Published private(set) var cpuTemp: Double?
    @Published private(set) var gpuTemp: Double?
    @Published private(set) var fans: [Fan] = []
    @Published private(set) var cpu: Double = 0           // 0…1
    @Published private(set) var gpu: Double?              // 0…1
    @Published private(set) var memUsed: Double = 0       // bytes
    @Published private(set) var memPressure = 1           // 1 normal, 2 warning, 4 critical
    @Published private(set) var battery: (percent: Int, charging: Bool, plugged: Bool, minutes: Int?)?
    @Published private(set) var netIn: Double = 0         // bytes/s
    @Published private(set) var netOut: Double = 0
    private(set) var netPeak: Double = 1_000_000          // scale for the network bar (1 MB/s floor)
    @Published private(set) var diskFree: Int64 = 0
    @Published private(set) var diskTotal: Int64 = 0
    @Published private(set) var hot = false
    @Published private(set) var switchingFans = false
    @Published private(set) var fanError: String?

    let memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    let cores = ProcessInfo.processInfo.processorCount

    private let smc = SMC()
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var lastTicks: [UInt32] = []
    private var lastNet: (UInt64, UInt64, Date)?

    var fanMode: FanMode? {
        guard !fans.isEmpty else { return nil }
        if fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) { return .auto }
        if fans.allSatisfy({ $0.mode == 1 && $0.target >= $0.max - 1 }) { return .max }
        return .manual
    }

    /// Current forced speed as a fraction of the fans' range (for the Manual slider).
    var fanFraction: Double {
        guard let f = fans.first, f.max > f.min else { return 0.5 }
        return min(1, max(0, (f.target - f.min) / (f.max - f.min)))
    }

    func start() {
        guard slowTimer == nil else { return }
        readTemps()
        let t = Timer(timeInterval: 10, repeats: true) { _ in MainActor.assumeIsolated { SystemMonitor.shared.readTemps() } }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        slowTimer = t
    }

    /// Fast sampling while the System tab is on screen.
    func setVisible(_ visible: Bool) {
        if visible, fastTimer == nil {
            sample()
            let t = Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { SystemMonitor.shared.sample() } }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            fastTimer = t
        } else if !visible {
            fastTimer?.invalidate()
            fastTimer = nil
            lastTicks = []
            lastNet = nil
        }
    }

    // MARK: - Sampling

    private func readTemps() {
        cpuTemp = smc.average(prefix: "Tp")
        gpuTemp = smc.average(prefix: "Tg")
        if let t = cpuTemp { hot = hot ? t >= Self.hotOff : t >= Self.hotOn }
    }

    private func sample() {
        readTemps()
        fans = smc.fans()
        cpu = readCPU() ?? cpu
        gpu = Self.readGPU()
        readMemory()
        battery = Self.readBattery()
        readNetwork()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        }
    }

    private func readCPU() -> Double? {
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let ticks = (0..<Int(count)).map { UInt32(bitPattern: info[$0]) }
        defer { lastTicks = ticks }
        guard lastTicks.count == ticks.count else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(cpus) {
            let b = c * Int(CPU_STATE_MAX)
            let d = (0..<Int(CPU_STATE_MAX)).map { UInt64(ticks[b + $0] &- lastTicks[b + $0]) }
            busy += d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
            total += d.reduce(0, +)
        }
        return total > 0 ? Double(busy) / Double(total) : nil
    }

    private static func readGPU() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            if let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let u = stats["Device Utilization %"] as? Int {
                best = max(best ?? 0, Double(u) / 100)
            }
        }
        return best
    }

    private func readMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return }
        let page = Double(getpagesize())
        // Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        memUsed = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { memPressure = Int(level) }
    }

    private static func readBattery() -> (percent: Int, charging: Bool, plugged: Bool, minutes: Int?)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let maxCap = d[kIOPSMaxCapacityKey] as? Int, maxCap > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let mins = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            return (cur * 100 / maxCap, charging, plugged, (mins ?? -1) > 0 ? mins : nil)
        }
        return nil
    }

    private func readNetwork() {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return }
        defer { freeifaddrs(ifap) }
        var inB: UInt64 = 0, outB: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard ifa.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), String(cString: ifa.ifa_name).hasPrefix("en"),
                  let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            inB += UInt64(data.pointee.ifi_ibytes)
            outB += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date()
        if let (i, o, t) = lastNet, now > t {
            let dt = now.timeIntervalSince(t)
            netIn = Double(inB &- i) / dt   // ifi counters are 32-bit and wrap; &- keeps the delta right
            netOut = Double(outB &- o) / dt
            if netIn > 1e10 || netOut > 1e10 { netIn = 0; netOut = 0 }
            netPeak = max(netPeak, netIn)
        }
        lastNet = (inB, outB, now)
    }

    // MARK: - Fans (CoucouFanHelper)

    /// Kept open while Coucou runs: when it closes (quit, crash) the helper hands the fans back to macOS.
    private var helper: NSXPCConnection?

    func setFans(_ mode: FanMode, fraction: Double = 0.5) {
        guard let proxy = helperProxy() else { return }
        fanError = nil
        switchingFans = true
        let done: @Sendable (String?) -> Void = { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let m = SystemMonitor.shared
                    m.fanError = error
                    m.switchingFans = false
                    m.fans = m.smc.fans()
                }
            }
        }
        switch mode {
        case .auto: proxy.setAuto(reply: done)
        case .max: proxy.setFans(fraction: 1, reply: done)
        case .manual: proxy.setFans(fraction: fraction, reply: done)
        }
    }

    private func helperProxy() -> FanHelperProtocol? {
        let service = SMAppService.daemon(plistName: FanHelperInfo.plistName)
        if service.status != .enabled {
            try? service.register()
            if service.status == .requiresApproval {
                fanError = "Approve Coucou in Login Items"
                SMAppService.openSystemSettingsLoginItems()
                return nil
            }
            guard service.status == .enabled else { fanError = "Fan helper could not be installed"; return nil }
        }
        if helper == nil {
            let c = NSXPCConnection(machServiceName: FanHelperInfo.label, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            c.invalidationHandler = {
                DispatchQueue.main.async { MainActor.assumeIsolated { SystemMonitor.shared.helper = nil } }
            }
            c.resume()
            helper = c
        }
        return helper?.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SystemMonitor.shared.fanError = "Fan helper: \(error.localizedDescription)"
                    SystemMonitor.shared.switchingFans = false
                }
            }
        } as? FanHelperProtocol
    }
}
