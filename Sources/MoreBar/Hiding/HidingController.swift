import AppKit
import os

/// Управляет скрытием сторонних иконок распоркой.
///
/// На macOS 26 бар — единое пространство: системные иконки (кроме Clock и
/// Control Center) перемещаемы, и неверно поставленная распорка выталкивает
/// их за экран. Поэтому позиция подбирается динамически:
///
///  1. свёрнутая распорка ставится и пересоздаётся с растущей позицией,
///     пока её x не окажется левее самой левой ВИДИМОЙ системной иконки;
///  2. распорка разворачивается (10 000 pt), выталкивая всё левее себя;
///  3. проверка: ни одна системная иконка из базовой линии не пропала
///     с экрана; иначе — мгновенный откат и новая попытка.
@MainActor
final class HidingController {
    private static let log = Logger(subsystem: "com.nexatech.MoreBar", category: "hiding")

    private let spacer: SpacerItem
    private let lister: MenuBarItemLister
    private(set) var isEngaged = false

    init(spacer: SpacerItem, lister: MenuBarItemLister) {
        self.spacer = spacer
        self.lister = lister
    }

    /// Видимые системные иконки (базовая линия безопасности).
    private func visibleSystemItems() -> [MenuBarItem] {
        lister.currentItems().filter { $0.window.isOnScreen && $0.isSystem }
    }

    private func spacerWindow() -> WindowInfo? {
        WindowInfo.statusItemWindows().first { $0.name == SpacerItem.autosaveName }
    }

    /// Подбирает позицию и разворачивает распорку. Требует уже выданных
    /// прав (Screen Recording — для чтения имён окон).
    func engage() async {
        guard !isEngaged else { return }

        let baseline = visibleSystemItems()
        guard let leftmostSystemX = baseline.map(\.window.frame.minX).min() else {
            Self.log.warning("no visible system items found; refusing to engage")
            return
        }

        // Шаг 1: подгонка позиции свёрнутой распорки левее системного блока.
        var attempts = 0
        while attempts < 8 {
            guard let spacerFrame = spacerWindow()?.frame else {
                Self.log.error("spacer window not found")
                return
            }
            if spacerFrame.minX < leftmostSystemX { break }
            let overshoot = spacerFrame.minX - leftmostSystemX
            spacer.recreate(preferredPosition: spacer.preferredPosition + max(50, overshoot))
            attempts += 1
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let placed = spacerWindow(), placed.frame.minX < leftmostSystemX else {
            Self.log.error("failed to place spacer left of system block; giving up")
            return
        }

        // Шаг 2: разворот и проверка с автооткатом.
        for attempt in 1...3 {
            spacer.isExpanded = true
            try? await Task.sleep(for: .milliseconds(500))

            let fresh = WindowInfo.statusItemWindows()
            let lostSystem = baseline.filter { item in
                !(fresh.first { $0.windowID == item.window.windowID }?.isOnScreen ?? false)
            }
            if lostSystem.isEmpty {
                isEngaged = true
                Self.log.info("engaged: spacer expanded at position \(self.spacer.preferredPosition)")
                return
            }

            Self.log.error("attempt \(attempt): expansion displaced \(lostSystem.count) system item(s); rolling back")
            spacer.isExpanded = false
            try? await Task.sleep(for: .milliseconds(500))
        }
        Self.log.error("giving up: could not expand without displacing system items")
    }

    func disengage() {
        spacer.isExpanded = false
        isEngaged = false
    }
}
