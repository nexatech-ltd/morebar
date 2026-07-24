import AppKit

/// Невидимая «распорка»: NSStatusItem, который в развёрнутом состоянии
/// растягивается до 10 000 pt и выталкивает все иконки левее себя за край
/// экрана (окна остаются живыми, но становятся off-screen).
/// Приём из Hidden Bar/Ice: Ice ControlItem.Lengths.expanded == 10_000 (MIT),
/// работает на macOS 26.
@MainActor
final class SpacerItem {
    static nonisolated let autosaveName = "MoreBar.spacer"

    private enum Lengths {
        /// Тонкая «прощупываемая» длина: окно существует и имеет читаемый x,
        /// но визуально незаметно.
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

    /// Пересоздаёт распорку с новой предпочитаемой позицией
    /// (большее значение — левее). На macOS 26 позиция итема применяется
    /// только при создании, поэтому итем приходится пересоздавать.
    func recreate(preferredPosition: CGFloat) {
        NSStatusBar.system.removeStatusItem(statusItem)
        // Удаление статус-итема стирает сохранённую позицию — перезаписываем
        // после него (приём из Ice ControlItem.removeStatusItem).
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
