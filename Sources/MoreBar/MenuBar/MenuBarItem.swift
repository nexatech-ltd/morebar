import AppKit

/// Модель иконки меню-бара: окно + разрешённый процесс-источник.
struct MenuBarItem {
    let window: WindowInfo
    /// PID приложения, создавшего итем (см. SourcePIDResolver); nil — не определён.
    let sourcePID: pid_t?

    /// Приложение-источник.
    var sourceApp: NSRunningApplication? {
        sourcePID.flatMap(NSRunningApplication.init(processIdentifier:))
    }

    /// Наши собственные итемы (иконка «⋯» и распорка).
    var isOwnItem: Bool {
        window.name == StatusIconController.autosaveName
            || window.name == SpacerItem.autosaveName
            || sourcePID == ProcessInfo.processInfo.processIdentifier
    }

    /// Окна-клоны, создаваемые Tahoe для системного управления итемами, —
    /// не настоящие иконки, в панели не участвуют.
    var isSystemClone: Bool {
        window.name == "System Status Item Clone"
    }

    /// Системная ли это иконка (остаётся в верхнем баре) или сторонняя
    /// (прячется во второй бар MoreBar).
    ///
    /// TODO(user): правило классификации — ваше решение (5–10 строк).
    /// Договорённость: НИКАКОГО хардкода имён приложений; универсальный
    /// критерий — где живёт бандл приложения-источника (`sourceApp?.bundleURL`).
    /// Подумайте о граничных случаях:
    ///   • sourcePID == nil (AX не смог определить источник) — прятать или нет?
    ///   • bundleURL == nil (агенты без бандла);
    ///   • /System/Library/… против /System/Applications/… (Apple-приложения
    ///     вроде Weather тоже ставят иконки — они «системные» или нет?)
    /// Безопасный дефолт: не уверены — считаем системной (не прячем).
    var isSystem: Bool {
        // ЗАГЛУШКА до вашего правила: всё считается системным, ничего не прячется.
        return true
    }
}
