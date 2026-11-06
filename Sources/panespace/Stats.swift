import Darwin
import Foundation
import QuartzCore

/// Running numbers for `panespace stats`: how fast keys turn into moving windows, how smooth animations are,
/// how long window scans take, and what Panespace itself costs. Written from main and `axQueue`.
final class Stats {
    private let lock = NSLock()
    private let started = CACurrentMediaTime()
    /// Key (or command) to the first frame on screen, ms. The last 200.
    private var latencies: [Double] = []
    private var commands = 0
    private var animations = 0
    private var frames = 0
    private var animatedSeconds = 0.0
    private var slowestFrame = 0.0
    private var syncs: [Double] = []
    private var syncCount = 0
    /// (time, CPU seconds) every 30 s, for the recent CPU use.
    private var cpuSamples: [(Double, Double)] = []

    func command() { lock.withLock { commands += 1 } }

    func latency(_ ms: Double) {
        lock.withLock {
            latencies.append(ms)
            if latencies.count > 200 { latencies.removeFirst() }
        }
    }

    func animation(frames n: Int, seconds: Double, slowest: Double) {
        lock.withLock {
            animations += 1
            frames += n
            animatedSeconds += seconds
            slowestFrame = max(slowestFrame, slowest)
        }
    }

    func sync(_ ms: Double) {
        lock.withLock {
            syncCount += 1
            syncs.append(ms)
            if syncs.count > 200 { syncs.removeFirst() }
        }
    }

    func sampleCPU() {
        let s = (CACurrentMediaTime(), Self.cpuSeconds())
        lock.withLock {
            cpuSamples.append(s)
            if cpuSamples.count > 10 { cpuSamples.removeFirst() }
        }
    }

    func json(windows: Int, workspaces: Int, displays: Int) -> [String: Any] {
        let now = CACurrentMediaTime(), cpu = Self.cpuSeconds()
        return lock.withLock {
            let up = now - started
            func summary(_ v: [Double]) -> [String: Any] {
                guard !v.isEmpty else { return [:] }
                let s = v.sorted()
                func r(_ x: Double) -> Double { (x * 10).rounded() / 10 }
                return ["last": r(v.last!), "median": r(s[s.count / 2]), "p95": r(s[min(s.count - 1, s.count * 95 / 100)]),
                        "max": r(s.last!), "samples": v.count]
            }
            var out: [String: Any] = [
                "uptime_s": Int(up),
                "cpu_avg_percent": up > 0 ? (cpu / up * 1000).rounded() / 10 : 0,
                "memory_mb": (Self.footprintMB() * 10).rounded() / 10,
                "threads": Self.threads(),
                "windows": windows, "workspaces": workspaces, "displays": displays,
                "commands": commands,
                "key_to_frame_ms": summary(latencies),
                "animations": animations,
                "fps_avg": animatedSeconds > 0 ? (Double(frames) / animatedSeconds).rounded() : 0,
                "slowest_frame_ms": (slowestFrame * 10000).rounded() / 10,
                "syncs": syncCount,
                "sync_ms": summary(syncs),
            ]
            if let first = cpuSamples.first, now - first.0 > 1 {
                out["cpu_recent_percent"] = ((cpu - first.1) / (now - first.0) * 1000).rounded() / 10
            }
            return out
        }
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    /// What Activity Monitor calls Memory.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func threads() -> Int {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }
}
