import AppKit

/// The only visible MoreBar icon: "…" in the system menu bar.
/// Left click (mouseDown, matching system menus) toggles the second bar.
/// Right click shows a tiny menu with a single Quit entry.
@MainActor
final class StatusIconController {
    static nonisolated let autosaveName = "MoreBar.icon"

    private let statusItem: NSStatusItem
    var onToggle: (() -> Void)?

    /// Icon highlight while the second bar is open (like an active menu bar item).
    var isHighlighted: Bool = false {
        didSet { statusItem.button?.highlight(isHighlighted) }
    }

    init() {
        // Position 0: to the right of all third-party icons, adjacent to the
        // system section.
        if StatusItemDefaults[.preferredPosition, Self.autosaveName] == nil {
            StatusItemDefaults[.preferredPosition, Self.autosaveName] = 0
        }
        StatusItemDefaults[.visible, Self.autosaveName] = true
        StatusItemDefaults[.visibleCC, Self.autosaveName] = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "MoreBar")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(performAction)
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        }
    }

    @objc private func performAction() {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp:
            showQuitMenu()
        default:
            onToggle?()
        }
    }

    private func showQuitMenu() {
        let menu = NSMenu()
        let quit = NSMenuItem(
            title: "Quit MoreBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        }
    }

    /// Screen frame of our icon's window — used to anchor the panel.
    var screenFrame: NSRect? {
        statusItem.button?.window?.frame
    }
}
