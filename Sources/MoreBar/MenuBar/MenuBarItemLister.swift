import AppKit

/// Собирает актуальный ростер иконок меню-бара.
@MainActor
final class MenuBarItemLister {
    private let resolver = SourcePIDResolver()

    /// Все настоящие иконки (без наших и без клонов), слева направо.
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

    /// Иконки для второго бара: несистемные и (после разворота распорки)
    /// оказавшиеся вне экрана либо под чёлкой.
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
