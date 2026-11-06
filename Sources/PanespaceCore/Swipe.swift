import CoreGraphics
import Foundation

/// Turns raw trackpad frames (how many fingers touch, and where their center is) into swipes.
///
/// A swipe starts when exactly `fingers` touch and their center travels far enough one way: sideways becomes
/// a live horizontal swipe that reports its offset every frame until a finger lifts; up or down fires once.
/// Any other finger count (say, Three-Finger Drag with a 4-finger swipe set) is ignored until all lift.
public struct SwipeRecognizer {
    public enum Event: Equatable {
        case horizontalBegan
        /// Sideways travel since the swipe began, as a fraction of the trackpad's width (+ = right).
        case horizontal(Double)
        /// The fingers lifted: final travel, and speed in trackpad widths per second (+ = right).
        case horizontalEnded(Double, velocity: Double)
        case up, down
    }

    public let fingers: Int
    private enum Phase { case idle, undecided, horizontal, done }
    private var phase = Phase.idle
    private var origin = (x: 0.0, y: 0.0)
    private var samples: [(t: Double, x: Double)] = []
    private var travel = 0.0

    /// How far the center must move before it's a swipe (fraction of the trackpad).
    static let sideways = 0.03, vertical = 0.06

    public init(fingers: Int) { self.fingers = fingers }

    /// One trackpad frame: `count` fingers touching, their center at (`x`, `y`) in 0…1 (y up), at time `t` (s).
    public mutating func frame(count: Int, x: Double, y: Double, t: Double) -> [Event] {
        guard count == fingers else {
            defer { phase = count == 0 ? .idle : (phase == .idle ? .idle : .done) }
            return phase == .horizontal ? [.horizontalEnded(travel, velocity: velocity())] : []
        }
        switch phase {
        case .idle:
            origin = (x, y)
            phase = .undecided
            return []
        case .undecided:
            let (dx, dy) = (x - origin.x, y - origin.y)
            if abs(dx) > Self.sideways, abs(dx) > 1.2 * abs(dy) {
                phase = .horizontal
                origin.x = x  // start from here, so the content doesn't jump by the threshold
                travel = 0
                samples = [(t, x)]
                return [.horizontalBegan, .horizontal(0)]
            }
            if abs(dy) > Self.vertical, abs(dy) > 1.2 * abs(dx) {
                phase = .done
                return [dy > 0 ? .up : .down]
            }
            return []
        case .horizontal:
            travel = x - origin.x
            samples.append((t, x))
            samples.removeAll { t - $0.t > 0.08 }
            return [.horizontal(travel)]
        case .done:
            return []
        }
    }

    /// Recent speed, from the last ~80 ms of samples.
    private func velocity() -> Double {
        guard let a = samples.first, let b = samples.last, b.t - a.t > 0.005 else { return 0 }
        return (b.x - a.x) / (b.t - a.t)
    }
}

extension Motion {
    /// Dragging past the last workspace: the content follows less and less the further it goes (iOS-style).
    public static func rubberBand(_ offset: Double, dimension d: Double) -> Double {
        let x = abs(offset)
        return (1 - 1 / (x * 0.55 / d + 1)) * d * (offset < 0 ? -1 : 1)
    }

    /// On lift: switch when dragged about a third of the way, or flicked toward the neighbour fast enough;
    /// a flick back cancels. `progress` 0…1 and `velocity` in screens per second, both + toward the neighbour.
    public static func commits(progress: Double, velocity: Double) -> Bool {
        velocity > 0.6 || (progress > 0.33 && velocity > -0.3)
    }
}

extension Model {
    /// The workspace beside the focused one on its monitor, in order. No wrapping, like Spaces.
    public func adjacentWorkspace(forward: Bool) -> Workspace? {
        let list = sortedWorkspaces.filter { $0.monitorID == focusedWorkspace.monitorID }
        guard let i = list.firstIndex(where: { $0 === focusedWorkspace }) else { return nil }
        let j = i + (forward ? 1 : -1)
        return list.indices.contains(j) ? list[j] : nil
    }

    /// Where `ws`'s windows would be if it were shown on `monitor`: its tiles and floating frames.
    public func frames(of ws: Workspace, on monitor: Monitor) -> [WindowID: CGRect] {
        var out = LayoutEngine.layout(ws, on: monitor, config: config)
        for w in ws.floating { if let f = w.floatingFrame { out[w.id] = f } }
        return out
    }
}
