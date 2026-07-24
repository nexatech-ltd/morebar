import AppKit

/// The invisible "spacer": an NSStatusItem that, when expanded, stretches to
/// 10,000 pt and pushes every icon to its left off the screen edge (their
/// windows stay alive but become off-screen).
/// Trick from Hidden Bar/Ice: Ice ControlItem.Lengths.expanded == 10_000 (MIT),
/// still works on macOS 26.
@MainActor
final class SpacerItem {
    static nonisolated let autosaveName = "MoreBar.spacer"

    private enum Lengths {
        /// A thin probe length: the window exists and has a readable x,
        /// yet is visually unnoticeable.
        static let collapsed: CGFloat = 4
        static let expanded: CGFloat = 10_000
    }

    private var statusItem: NSStatusItem

    var isExpanded: Bool = false {
        didSet {
            statusItem.length = isExpanded ? Lengths.expanded : Lengths.collapsed
        }
    }

    init() {
        if StatusItemDefaults[.preferredPosition, Self.autosaveName] == nil {
            StatusItemDefaults[.preferredPosition, Self.autosaveName] = 1
        }
        StatusItemDefaults[.visible, Self.autosaveName] = true
        StatusItemDefaults[.visibleCC, Self.autosaveName] = true
        statusItem = Self.makeStatusItem()
    }

    /// Recreates the spacer with a new preferred position (larger value =
    /// further left). On macOS 26 the position is applied only at creation
    /// time, hence the recreation dance.
    func recreate(preferredPosition: CGFloat) {
        NSStatusBar.system.removeStatusItem(statusItem)
        // Removing a status item wipes its stored position — rewrite it
        // afterwards (trick from Ice ControlItem.removeStatusItem).
        StatusItemDefaults[.preferredPosition, Self.autosaveName] = preferredPosition
        StatusItemDefaults[.visible, Self.autosaveName] = true
        StatusItemDefaults[.visibleCC, Self.autosaveName] = true
        statusItem = Self.makeStatusItem()
        statusItem.length = isExpanded ? Lengths.expanded : Lengths.collapsed
    }

    var preferredPosition: CGFloat {
        StatusItemDefaults[.preferredPosition, Self.autosaveName] ?? 1
    }

    private static func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Lengths.collapsed)
        item.autosaveName = Self.autosaveName
        item.button?.isEnabled = false
        return item
    }
}
