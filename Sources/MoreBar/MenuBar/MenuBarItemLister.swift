import AppKit

/// Builds the current roster of menu bar icons.
@MainActor
final class MenuBarItemLister {
    private let resolver = SourcePIDResolver()

    /// All real icons (excluding ours and the Tahoe clones), left to right.
    func currentItems() -> [MenuBarItem] {
        let ccPID = SourcePIDResolver.controlCenterPID()
        return WindowInfo.statusItemWindows()
            .map { window in
                MenuBarItem(
                    window: window,
                    sourcePID: resolver.resolveSourcePID(for: window, controlCenterPID: ccPID)
                )
            }
            .filter { !$0.isOwnItem && !$0.isSystemClone }
            .sorted { $0.window.frame.minX < $1.window.frame.minX }
    }

    /// Icons for the second bar: non-system ones that ended up off screen
    /// (parked by macOS or pushed by the expanded spacer) or under the notch.
    func hiddenItems() -> [MenuBarItem] {
        currentItems().filter { item in
            guard !item.isSystem else { return false }
            if !item.window.isOnScreen { return true }
            if let notch = NSScreen.main?.notchRect {
                return item.window.frame.intersects(notch)
            }
            return false
        }
    }
}
