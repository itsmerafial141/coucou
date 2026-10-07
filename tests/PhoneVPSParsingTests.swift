import Foundation

@main
enum PhoneVPSParsingTests {
    static var failures = 0

    static func check(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        let svc = PhoneVPS.parseServices("sshd\thidup\tok\njenkins\tmati\ttutup\ncloudflared-watchdog\thidup\t-\ngarbage")
        check("three services, garbage line skipped", svc.count == 3)
        check("running + port ok is healthy", svc.first?.healthy == true)
        check("stopped service is unhealthy", svc.count > 1 && !svc[1].healthy)
        check("no port (-) still healthy", svc.count > 2 && svc[2].healthy)

        let st = PhoneVPS.parseStats("""
        jam HP: 2026-10-08 00:54:23 JST
         00:54:24 up 28 days,  8:24,  load average: 16.27, 16.20, 16.24
                       total        used        free      shared  buff/cache   available
        Mem:            5606        2861         252          17        2492        2441
        Swap:           2559        1093        1466
        /dev/block/platform/13520000.ufs/by-name/userdata 111G   14G   97G  13% /data/user/0
        """)
        check("stats parsed (\(st))",
              st == PhoneVPS.Stats(uptime: "28 days", load: "16.27", ram: "3.1 / 5.5 GB", disk: "13% of 111G"))

        check("403 answers", PhoneVPS.Site(name: "a", code: 403, ms: 1).healthy)
        check("530 = tunnel down", !PhoneVPS.Site(name: "a", code: 530, ms: 1).healthy)
        check("502 = app down", !PhoneVPS.Site(name: "a", code: 502, ms: 1).healthy)
        check("transport error", !PhoneVPS.Site(name: "a", code: nil, ms: 1).healthy)

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("phone-vps parsing: ok")
    }
}
