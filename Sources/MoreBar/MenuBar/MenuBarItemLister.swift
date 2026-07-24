import AppKit

/// Builds the current roster of menu bar icons.
@MainActor
final class MenuBarItemLister {
    private let resolver = SourcePIDResolver()

    /// All real icons (excluding ours and the Tahoe clones), left to right.
    ///
    /// Apps sometimes park auxiliary windows on the status layer too (e.g.
    /// Monosnap keeps 57–90 pt tall panels there) — a real menu bar icon
    /// window is always as tall as the bar itself, so filter by geometry.
    func currentItems() -> [MenuBarItem] {
        let ccPID = SourcePIDResolver.controlCenterPID()
        return WindowInfo.statusItemWindows()
            .filter { $0.frame.height <= 40 && $0.frame.width >= 8 }
            .map { window in
                MenuBarItem(
                    window: window,
                    sourcePID: resolver.resolveSourcePID(for: window, controlCenterPID: ccPID)
                )
            }
            .filter { !$0.isOwnItem && !$0.isSystemClone }
            .sorted { $0.window.frame.minX < $1.window.frame.minX }
    }

    /// Icons for the second bar.
    ///
    /// Everything inside the spacer's push zone (far left of every screen)
    /// is there because WE hid it — show it unconditionally. Classification
    /// matters only for items we did not hide ourselves: source resolution
    /// often fails for off-screen windows (AX reports no frames for them),
    /// and gating the push zone on `isSystem` would make hidden icons
    /// invisible both in the bar and in the panel.
    func hiddenItems() -> [MenuBarItem] {
        let hiddenZoneBoundary = (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 500
        return currentItems().filter { item in
            if item.window.frame.minX < hiddenZoneBoundary { return true }
            guard !item.isSystem else { return false }
            if !item.window.isOnScreen { return true }
            if let notch = NSScreen.main?.notchRect {
                return item.window.frame.intersects(notch)
            }
            return false
        }
    }
}
