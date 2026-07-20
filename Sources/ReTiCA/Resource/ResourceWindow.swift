import Foundation

/// Adaptive send-window sizing for a Reticulum resource transfer (receiver side).
/// Pure value type mirroring the Python-RNS 1.3.8 window arithmetic. `windowMax` is the
/// SLOW cap; rate-based escalation to the fast cap is deferred to a later slice.
public struct ResourceWindow: Equatable, Sendable {
    public var window: Int
    public var windowMin: Int
    public var windowMax: Int
    public var flexibility: Int

    public static let initialWindow = 4
    public static let minWindow = 2
    public static let maxWindowSlow = 10
    public static let defaultFlexibility = 4

    public init(window: Int = initialWindow, windowMin: Int = minWindow,
                windowMax: Int = maxWindowSlow, flexibility: Int = defaultFlexibility) {
        self.window = window
        self.windowMin = windowMin
        self.windowMax = windowMax
        self.flexibility = flexibility
    }

    /// One completed round: grow the window, raising the floor once the spread is wide enough.
    public func grown() -> ResourceWindow {
        var w = self
        if w.window < w.windowMax {
            w.window += 1
            if (w.window - w.windowMin) > (w.flexibility - 1) {
                w.windowMin += 1
            }
        }
        return w
    }

    /// One timeout: shrink the window and ceiling, tightening the ceiling again on a wide spread.
    public func shrunk() -> ResourceWindow {
        var w = self
        if w.window > w.windowMin {
            w.window -= 1
            if w.windowMax > w.windowMin {
                w.windowMax -= 1
                if (w.windowMax - w.window) > (w.flexibility - 1) {
                    w.windowMax -= 1
                }
            }
        }
        return w
    }
}
