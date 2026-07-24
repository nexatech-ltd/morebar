import AppKit

/// Единственная видимая иконка MoreBar: «⋯» в системном баре.
/// ЛКМ (mouseDown, как у системных меню) — тумблер панели второго бара.
/// ПКМ — маленькое меню с единственным пунктом Quit.
@MainActor
final class StatusIconController {
    static nonisolated let autosaveName = "MoreBar.icon"

    private let statusItem: NSStatusItem
    var onToggle: (() -> Void)?

    /// Подсветка иконки, пока открыт второй бар (как у активного пункта меню-бара).
    var isHighlighted: Bool = false {
        didSet { statusItem.button?.highlight(isHighlighted) }
    }

    init() {
        // Позиция 0 — правее всех сторонних иконок, вплотную к системной секции.
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
            title: NSLocalizedString("Quit MoreBar", comment: ""),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        }
    }

    /// Экранный фрейм окна нашей иконки — для позиционирования панели под ней.
    var screenFrame: NSRect? {
        statusItem.button?.window?.frame
    }
}
