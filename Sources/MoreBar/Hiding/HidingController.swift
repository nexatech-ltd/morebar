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
    private static let log = Logger(subsystem: "dev.nexatech.MoreBar", category: "hiding")

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

    /// UserDefaults key for the spacer order position that was proven safe on
    /// a previous run. Reusing it turns every launch after the first into a
    /// single clean expand — no calibration flicker.
    private static let verifiedPositionKey = "MoreBar.spacer.verifiedPosition"
    private var verifiedPosition: CGFloat? {
        get { UserDefaults.standard.object(forKey: Self.verifiedPositionKey) as? CGFloat }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.verifiedPositionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.verifiedPositionKey)
            }
        }
    }

    /// Places and expands the spacer at a proven-safe order position.
    ///
    /// The spacer stays expanded for the app's whole lifetime once engaged:
    /// on Tahoe, Control Centre DESTROYS the windows of naturally-overflowed
    /// items (they become impossible to capture or click), while items held
    /// off screen by an expanded spacer keep live windows. The expanded
    /// spacer is what keeps the hidden icons alive.
    ///
    /// Geometry cannot prove the spacer's ORDER: a parked spacer window sits
    /// under the notch with a meaningless x. So on the FIRST run the order is
    /// calibrated empirically (expand — if a system item is pushed, collapse
    /// to restore it, shift one notch left, retry). The winning position is
    /// cached, and later runs skip straight to a single expand — which is why
    /// the icon churn only ever happens once.
    private func expandSpacerSafely() async -> Bool {
        // Fast path: reuse the position proven safe on a previous run.
        if let verified = verifiedPosition {
            if spacer.preferredPosition != verified {
                let previousID = newestSpacerWindow()?.windowID
                spacer.recreate(preferredPosition: verified)
                if let previousID { _ = await waitForNewSpacerWindow(previousID: previousID) }
            }
            if await tryExpandOnce() {
                Self.log.info("engaged at cached position \(verified) (no calibration)")
                return true
            }
            // The bar changed enough that the cached position is no longer
            // safe — drop it and recalibrate.
            Self.log.info("cached position \(verified) no longer safe; recalibrating")
            verifiedPosition = nil
        }

        // Full calibration (first run, or after a layout change).
        for attempt in 1...6 {
            guard await placeSpacerLeftOfSystemBlock() else {
                Self.log.error("failed to place spacer left of system block; not expanding")
                return false
            }
            if await tryExpandOnce() {
                verifiedPosition = spacer.preferredPosition
                Self.log.info("engaged on attempt \(attempt) at position \(self.spacer.preferredPosition)")
                return true
            }
            Self.log.info("calibration attempt \(attempt) pushed a system item; moving one notch left")
            if let previousID = newestSpacerWindow()?.windowID {
                spacer.recreate(preferredPosition: spacer.preferredPosition + 150)
                _ = await waitForNewSpacerWindow(previousID: previousID)
            }
        }
        Self.log.error("calibration failed after 6 attempts; leaving the bar untouched")
        return false
    }

    /// Expands the spacer once and confirms no visible system item was pushed.
    ///
    /// Asymmetric timing to keep any mistake nearly invisible: SUCCESS needs
    /// the full settle window with no push seen, but a detected push COLLAPSES
    /// immediately (restoring the item), so a bad expand blinks for ~50 ms
    /// instead of the full window.
    private func tryExpandOnce() async -> Bool {
        // Baseline: only items visible BEFORE expansion can be harmed.
        let baseline = lister.currentItems()
            .filter { $0.window.isOnScreen && $0.isSystem }
        guard !baseline.isEmpty else { return false }

        spacer.isExpanded = true
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(50))
            let fresh = WindowInfo.statusItemWindows()
            // A system item counts as PUSHED only if its window travelled far
            // left — dynamic items like NowPlaying hide themselves in place.
            let pushed = baseline.filter { item in
                guard let now = fresh.first(where: { $0.windowID == item.window.windowID }) else {
                    return false // window gone entirely (app/state change), not a push
                }
                return !now.isOnScreen && now.frame.minX < item.window.frame.minX - 100
            }
            if !pushed.isEmpty {
                spacer.isExpanded = false
                await waitForRestore(of: pushed)
                return false
            }
        }
        isEngaged = true
        return true
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
        // Success = spacer strictly left of the leftmost visible system icon.
        // No extra buffer: on a compressed bar the spacer bottoms out at the
        // left edge of the right-of-notch region, only a few px left of the
        // leftmost icon, and any buffer would be physically unreachable.
        // tryExpandOnce() is the real safety net — it verifies nothing system
        // was actually pushed and collapses instantly if so.
        var previousSpacerX = CGFloat.greatestFiniteMagnitude
        for _ in 0..<10 {
            guard let target = visibleSystemMinX() else { return false }
            guard let spacerWindow = newestSpacerWindow() else { return false }
            let spacerX = spacerWindow.frame.minX
            if spacerX < target { return true }
            // The spacer stopped moving left (hit the menu bar's left edge):
            // growing the position further is pointless.
            if spacerX >= previousSpacerX - 1 {
                return false
            }
            previousSpacerX = spacerX

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
