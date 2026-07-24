import AppKit
import os

/// Drives hiding of third-party icons with the spacer.
///
/// On macOS 26 the menu bar is a single unified space: system icons (except
/// the Clock and Control Center) are movable, and a spacer expanded from the
/// wrong slot shoves them off the screen. Worse, "rolling back" (collapsing)
/// does NOT bring parked icons back. The only safe strategy is:
///
///  1. if there are no visible non-system icons, do nothing (nothing to hide);
///  2. recreate the collapsed spacer with a growing position until its x is
///     to the left of the leftmost VISIBLE system icon;
///  3. re-check the invariant against fresh geometry, and only then expand:
///     expansion grows leftwards from the spacer's slot and cannot touch
///     anything to its right.
@MainActor
final class HidingController {
    private static let log = Logger(subsystem: "com.nexatech.MoreBar", category: "hiding")

    private let spacer: SpacerItem
    private let lister: MenuBarItemLister
    /// The spacer is expanded from a proven-safe position.
    private(set) var isEngaged = false
    private var inProgress = false

    init(spacer: SpacerItem, lister: MenuBarItemLister) {
        self.spacer = spacer
        self.lister = lister
    }

    /// Idempotent: safe to call every few seconds. Expands the spacer when
    /// there is something to hide and doing so is provably safe.
    func engage() async {
        guard !isEngaged, !inProgress else { return }
        inProgress = true
        defer { inProgress = false }

        let items = lister.currentItems()
        let visibleHideable = items.filter { $0.window.isOnScreen && !$0.isSystem }
        guard !visibleHideable.isEmpty else {
            // No visible third-party icons: either macOS already parked them
            // all, or there is simply nothing to hide. No spacer needed.
            return
        }

        guard await placeSpacerLeftOfSystemBlock() else {
            Self.log.error("failed to place spacer left of system block; not expanding")
            return
        }

        // Fresh invariant re-check right before expanding.
        guard
            let spacerX = newestSpacerWindow()?.frame.minX,
            let minSystemX = visibleSystemMinX(),
            spacerX < minSystemX
        else {
            Self.log.error("invariant re-check failed; not expanding")
            return
        }

        spacer.isExpanded = true
        isEngaged = true
        Self.log.info("engaged: spacer expanded from x=\(spacerX), leftmost system x=\(minSystemX)")

        // Post-expand sanity check (the invariant should make harm impossible).
        try? await Task.sleep(for: .milliseconds(600))
        let fresh = WindowInfo.statusItemWindows()
        let lost = lister.currentItems().filter { item in
            item.isSystem && !(fresh.first { $0.windowID == item.window.windowID }?.isOnScreen ?? true)
        }
        if !lost.isEmpty {
            Self.log.fault("post-expand check: \(lost.count) system item(s) went offscreen — collapsing")
            spacer.isExpanded = false
            isEngaged = false
        }
    }

    func disengage() {
        spacer.isExpanded = false
        isEngaged = false
    }

    // MARK: - Placement

    /// The leftmost visible system icon.
    private func visibleSystemMinX() -> CGFloat? {
        lister.currentItems()
            .filter { $0.window.isOnScreen && $0.isSystem }
            .map(\.window.frame.minX)
            .min()
    }

    /// The spacer's window: after recreation the old item's window may linger
    /// in the list under the same name for a moment — take the newest one
    /// (window IDs grow monotonically).
    private func newestSpacerWindow() -> WindowInfo? {
        WindowInfo.statusItemWindows()
            .filter { $0.name == SpacerItem.autosaveName }
            .max { $0.windowID < $1.windowID }
    }

    /// Recreates the collapsed spacer with a growing position until it sits
    /// left of the system block. A collapsed (4 pt) spacer pushes nothing,
    /// so the attempts themselves are harmless.
    private func placeSpacerLeftOfSystemBlock() async -> Bool {
        let margin: CGFloat = 20
        for _ in 0..<10 {
            guard let target = visibleSystemMinX() else { return false }
            guard let spacerWindow = newestSpacerWindow() else { return false }
            let spacerX = spacerWindow.frame.minX
            if spacerX < target - margin { return true }

            let overshoot = spacerX - target
            spacer.recreate(preferredPosition: spacer.preferredPosition + max(100, overshoot + 120))
            _ = await waitForNewSpacerWindow(previousID: spacerWindow.windowID)
        }
        return false
    }

    /// Waits for the recreated spacer's window to appear (up to ~1.2 s).
    private func waitForNewSpacerWindow(previousID: CGWindowID) async -> WindowInfo? {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(150))
            if let window = newestSpacerWindow(), window.windowID != previousID {
                return window
            }
        }
        return newestSpacerWindow()
    }
}
