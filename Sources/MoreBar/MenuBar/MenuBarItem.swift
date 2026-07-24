import AppKit

/// A menu bar item: its window plus the resolved source process.
struct MenuBarItem {
    let window: WindowInfo
    /// PID of the app that created the item (see SourcePIDResolver); nil if unresolved.
    let sourcePID: pid_t?

    /// The application that created the item.
    var sourceApp: NSRunningApplication? {
        sourcePID.flatMap(NSRunningApplication.init(processIdentifier:))
    }

    /// Our own items (the "…" icon and the spacer).
    var isOwnItem: Bool {
        window.name == StatusIconController.autosaveName
            || window.name == SpacerItem.autosaveName
            || sourcePID == ProcessInfo.processInfo.processIdentifier
    }

    /// Clone windows that Tahoe creates for system-managed item handling —
    /// not real icons, excluded from the second bar.
    var isSystemClone: Bool {
        window.name == "System Status Item Clone"
    }

    /// Whether this is a system icon (stays in the top bar) or a third-party
    /// one (gets tucked into the MoreBar second bar).
    ///
    /// No app-name hardcoding by design. The rule is purely structural:
    ///  - unresolved source (AX could not find the creator) -> treat as system;
    ///    never hide what we don't understand;
    ///  - no bundle URL (bare agents/daemons) -> system;
    ///  - bundle lives in /System/Library/... (Control Center, system agents)
    ///    -> system;
    ///  - everything else -> third-party and hideable. Note that Apple's own
    ///    user-facing apps under /System/Applications (Weather, Podcasts...)
    ///    behave like regular utilities, so they are intentionally hideable.
    var isSystem: Bool {
        guard sourcePID != nil else { return true }
        guard let bundlePath = sourceApp?.bundleURL?.path else { return true }
        return bundlePath.hasPrefix("/System/Library/")
    }
}
