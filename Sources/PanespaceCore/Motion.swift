import CoreGraphics
import Foundation

/// Pure math for layout animations: the spring windows move on, and which way a workspace switch slides.
public enum Motion {
    /// A critically damped spring: no overshoot, so a tile never crosses into its neighbour, and a window
    /// that's already moving keeps its velocity when its target changes mid-flight.
    public struct Spring {
        /// Angular frequency.
        public let omega: Double
        /// `duration`: about when the motion looks finished (99% of the way there).
        public init(duration: Double) { omega = 6.64 / max(duration, 0.01) }

        /// Where a value is, and how fast it moves, `t` seconds after leaving `x0` at `v0` for `target`.
        public func state(from x0: SIMD4<Double>, velocity v0: SIMD4<Double>, to target: SIMD4<Double>,
                          at t: Double) -> (position: SIMD4<Double>, velocity: SIMD4<Double>) {
            let c1 = x0 - target, c2 = v0 + omega * c1
            let e = exp(-omega * t)
            return (target + (c1 + c2 * t) * e, (c2 - omega * (c1 + c2 * t)) * e)
        }
    }

    /// A frame as (x, y, width, height), the four values a window animates.
    public static func vector(_ r: CGRect) -> SIMD4<Double> {
        SIMD4(Double(r.minX), Double(r.minY), Double(r.width), Double(r.height))
    }

    /// Back to a frame, on whole points so windows don't shimmer.
    public static func rect(_ v: SIMD4<Double>) -> CGRect {
        CGRect(x: v[0].rounded(), y: v[1].rounded(), width: v[2].rounded(), height: v[3].rounded())
    }

    /// The largest of the four values' sizes.
    public static func peak(_ v: SIMD4<Double>) -> Double { max(max(abs(v[0]), abs(v[1])), max(abs(v[2]), abs(v[3]))) }

    public struct Slide: Equatable {
        /// Added to a window's target to get where it starts when it slides in.
        public var enter: CGVector
        /// Added to a window's current frame to get where it slides out to.
        public var exit: CGVector
    }

    /// How windows travel when `monitor` switches workspace: sideways like Spaces when nothing sits beside it,
    /// up from below when a display is beside it, not at all when it's boxed in (they'd cross another display).
    public static func slide(on monitor: Monitor, among monitors: [Monitor], forward: Bool) -> Slide? {
        let f = monitor.frame
        let others = monitors.filter { $0.id != monitor.id }.map(\.frame)
        // Inset so displays that merely touch this one's edge don't count.
        func free(_ r: CGRect) -> Bool { !others.contains { $0.intersects(r.insetBy(dx: 1, dy: 1)) } }
        if free(f.offsetBy(dx: -f.width, dy: 0)) && free(f.offsetBy(dx: f.width, dy: 0)) {
            let d = forward ? f.width : -f.width
            return Slide(enter: CGVector(dx: d, dy: 0), exit: CGVector(dx: -d, dy: 0))
        }
        if free(f.offsetBy(dx: 0, dy: f.height)) {
            return Slide(enter: CGVector(dx: 0, dy: f.height), exit: CGVector(dx: 0, dy: f.height))
        }
        return nil
    }

    /// Whether going from workspace `a` to `b` moves forward: by number when both have one, else by `order`.
    public static func isForward(from a: String, to b: String, order: [String]) -> Bool {
        if let x = Int(a), let y = Int(b) { return y > x }
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return true }
        return j > i
    }
}
