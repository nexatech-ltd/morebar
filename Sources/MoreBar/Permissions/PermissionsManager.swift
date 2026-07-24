import AppKit
import ScreenCaptureKit

/// Два права, без которых менеджер меню-бара не работает:
///  • Универсальный доступ (Accessibility) — синтетические клики/перемещения
///    чужих иконок и AX-резолвинг их источников;
///  • Запись экрана (Screen Recording) — снимки спрятанных иконок и чтение
///    имён чужих окон.
///
/// Особенности macOS 26: CGRequestScreenCaptureAccess() не показывает промпт
/// (сломан с macOS 15) — вместо него дёргаем SCShareableContent; грант Записи
/// экрана вступает в силу только после перезапуска приложения.
@MainActor
final class PermissionsManager {
    enum Status {
        case granted
        case missingAccessibility
        case missingScreenRecording
        case missingBoth
    }

    /// Вызывается, когда оба права на месте. `freshlyGranted` — права выданы
    /// только что (в этой сессии, через поллинг), а не были с прошлого запуска.
    var onGranted: ((_ freshlyGranted: Bool) -> Void)?

    private var pollTimer: Timer?

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static var status: Status {
        switch (accessibilityGranted, screenRecordingGranted) {
        case (true, true): .granted
        case (false, true): .missingAccessibility
        case (true, false): .missingScreenRecording
        case (false, false): .missingBoth
        }
    }

    /// Запрашивает недостающие права (системные промпты) и начинает поллинг.
    /// Когда оба права выданы, зовёт onGranted (один раз).
    func requestIfNeeded() {
        guard Self.status != .granted else {
            onGranted?(false)
            return
        }
        if !Self.accessibilityGranted {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        if !Self.screenRecordingGranted {
            // Триггерит системный промпт «Запись экрана» и появление
            // приложения в списке System Settings.
            SCShareableContent.getWithCompletionHandler { _, _ in }
        }
        startPolling()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, Self.status == .granted else { return }
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.onGranted?(true)
            }
        }
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Запись экрана применяется только после перезапуска — этим и пользуемся:
    /// право есть в TCC, но окна ещё «не читаются» → нужен relaunch.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    /// Право «Запись экрана» выдано, но ещё не действует в этом процессе
    /// (типичное состояние сразу после гранта) — признак: preflight true,
    /// а имена чужих окон не читаются.
    static var screenRecordingNeedsRelaunch: Bool {
        guard screenRecordingGranted else { return false }
        let readable = WindowInfo.statusItemWindows()
            .contains { $0.ownerPID != ProcessInfo.processInfo.processIdentifier && $0.name != nil }
        return !readable
    }
}
