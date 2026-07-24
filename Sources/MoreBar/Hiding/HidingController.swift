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
    /// Moves stray visible items behind the spacer (Ice-style drag events).
    private let forwarder: ItemClickForwarder
    /// Skip enforcement while the panel is open so user clicks always win.
    var isPanelVisible: () -> Bool = { false }
    /// The spacer is expanded from a proven-safe position.
    private(set) var isEngaged = false
    private var inProgress = false

    init(spacer: SpacerItem, lister: MenuBarItemLister, forwarder: ItemClickForwarder) {
        self.spacer = spacer
        self.lister = lister
        self.forwarder = forwarder
    }

    /// Idempotent reconcile pass: safe to call every few seconds.
    ///
    /// Two mechanisms combine to hide everything non-system:
    ///  - the expanded spacer keeps pushing whatever sits to its left;
    ///  - on macOS 26 third-party icons can interleave with system ones and
    ///    end up to the spacer's RIGHT, out of its reach — those are dragged
    ///    behind the spacer one by one with synthetic move events.
    func engage() async {
        guard !inProgress else { return }
        inProgress = true
        defer { inProgress = false }

        let items = lister.currentItems()
        let visibleHideable = items.filter { $0.window.isOnScreen && !$0.isSystem }
        guard !visibleHideable.isEmpty else {
            // No visible third-party icons: either macOS already parked them
            // all, or there is simply nothing to hide. No spacer needed.
            return
        }

        if !isEngaged {
            guard await expandSpacerSafely() else { return }
        }
        guard isEngaged else { return }

        // Enforcement: drag visible non-system items behind the spacer.
        guard !forwarder.isBusy, !isPanelVisible() else { return }
        guard let spacerItem = newestSpacerWindow().map({
            MenuBarItem(window: $0, sourcePID: ProcessInfo.processInfo.processIdentifier)
        }) else { return }

        for item in visibleHideable {
            guard !forwarder.isBusy, !isPanelVisible() else { return }
            do {
                try await forwarder.move(item: item, to: .leftOfItem(spacerItem))
                Self.log.info("tucked away visible item \(item.window.windowID) (\(item.sourceApp?.localizedName ?? "?", privacy: .public))")
            } catch {
                Self.log.error("failed to tuck item \(item.window.windowID): \(error, privacy: .public)")
            }
        }
    }

    /// Places and expands the spacer, CALIBRATING its order position.
    ///
    /// The spacer stays expanded for the app's whole lifetime once engaged:
    /// on Tahoe, Control Centre DESTROYS the windows of naturally-overflowed
    /// items (they become impossible to capture or click), while items held
    /// off screen by an expanded spacer keep live windows. The expanded
    /// spacer is what keeps the hidden icons alive.
    ///
    /// Geometry cannot prove the spacer's ORDER: a parked spacer window sits
    /// under the notch with a meaningless x. So the order is calibrated
    /// empirically: expand — if any visible system item gets pushed, collapse
    /// (which restores it), bump the position one notch left, retry. The
    /// converged position persists in UserDefaults, so calibration is a
    /// one-time cost with a sub-second icon blink per attempt.
    private func expandSpacerSafely() async -> Bool {
        for attempt in 1...6 {
            guard await placeSpacerLeftOfSystemBlock() else {
                Self.log.error("failed to place spacer left of system block; not expanding")
                return false
            }

            // Baseline: only items visible BEFORE expansion can be harmed.
            let baseline = lister.currentItems()
                .filter { $0.window.isOnScreen && $0.isSystem }
            guard !baseline.isEmpty else { return false }

            spacer.isExpanded = true
            try? await Task.sleep(for: .milliseconds(600))

            // A system item counts as PUSHED only if its window travelled
            // far left — dynamic items like NowPlaying hide by themselves
            // in place, which is not our doing.
            let fresh = WindowInfo.statusItemWindows()
            let pushed = baseline.filter { item in
                guard let now = fresh.first(where: { $0.windowID == item.window.windowID }) else {
                    return false // window gone entirely (app/state change), not a push
                }
                return !now.isOnScreen && now.frame.minX < item.window.frame.minX - 100
            }

            if pushed.isEmpty {
                isEngaged = true
                Self.log.info("engaged on attempt \(attempt) at position \(self.spacer.preferredPosition)")
                return true
            }

            Self.log.info("calibration attempt \(attempt): \(pushed.count) system item(s) pushed — collapsing and moving one notch left")
            spacer.isExpanded = false
            await waitForRestore(of: pushed)
            if let previousID = newestSpacerWindow()?.windowID {
                spacer.recreate(preferredPosition: spacer.preferredPosition + 150)
                _ = await waitForNewSpacerWindow(previousID: previousID)
            }
        }
        Self.log.error("calibration failed after 6 attempts; leaving the bar untouched")
        return false
    }

    /// Waits until the given items are back on screen after a collapse.
    private func waitForRestore(of items: [MenuBarItem]) async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            let fresh = WindowInfo.statusItemWindows()
            let allBack = items.allSatisfy { item in
                fresh.first { $0.windowID == item.window.windowID }?.isOnScreen ?? true
            }
            if allBack { return }
        }
        Self.log.error("some pushed items did not come back within 2 s")
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
