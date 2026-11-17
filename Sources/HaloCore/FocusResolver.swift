import CoreGraphics

/// One on-screen window as the resolve sees it. The app builds these from
/// the layer-0 rows of `CGWindowListCopyWindowInfo`, preserving its
/// front-to-back order — the order IS the focus signal.
public struct WindowSnapshot: Sendable, Equatable {
    public var id: UInt32
    public var ownerPID: Int32
    /// CG coordinates (y-down, origin top-left of the main display).
    public var bounds: CGRect

    public init(id: UInt32, ownerPID: Int32, bounds: CGRect) {
        self.id = id
        self.ownerPID = ownerPID
        self.bounds = bounds
    }
}

/// Picks which window the ring should be on. WindowServer z-order resolves
/// windows within an app; the active app PID wins when that order lags a
/// switch between applications.
public enum FocusResolver {
    /// Frontmost eligible window in the active app when present; otherwise
    /// the first eligible window in `windows`. Returns nil when none.
    /// `isExcluded` is consulted per candidate (the app resolves the pid's
    /// bundle id lazily, so the common no-exclusion case costs nothing).
    public static func focused(in windows: [WindowSnapshot], selfPID: Int32,
                               minSize: CGFloat, preferredPID: Int32? = nil,
                               isExcluded: (Int32) -> Bool) -> WindowSnapshot? {
        func eligible(_ w: WindowSnapshot) -> Bool {
            w.ownerPID != selfPID
                && w.bounds.width >= minSize && w.bounds.height >= minSize
                && !isExcluded(w.ownerPID)
        }
        if let preferredPID,
           let active = windows.first(where: { $0.ownerPID == preferredPID && eligible($0) }) {
            return active
        }
        return windows.first(where: eligible)
    }
}
