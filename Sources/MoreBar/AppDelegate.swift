import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusIcon: StatusIconController?
    private var spacer: SpacerItem?
    private var lister: MenuBarItemLister?
    private var hiding: HidingController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerLoginItemIfNeeded()

        let spacer = SpacerItem()
        let statusIcon = StatusIconController()
        let lister = MenuBarItemLister()
        let hiding = HidingController(spacer: spacer, lister: lister)
        self.spacer = spacer
        self.statusIcon = statusIcon
        self.lister = lister
        self.hiding = hiding

        statusIcon.onToggle = { [weak self] in
            // Панель второго бара подключается в M5; пока — переключение подсветки.
            guard let self, let statusIcon = self.statusIcon else { return }
            statusIcon.isHighlighted.toggle()
        }

        // Скрытие включается только при выданных правах: без «Записи экрана»
        // панель не сможет показать спрятанные иконки — прятать их нечестно.
        if AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() {
            Task { await hiding.engage() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hiding?.disengage()
    }

    /// Автозагрузка при входе: только для копии, установленной в /Applications,
    /// чтобы dev-сборки из каталога проекта не прописывались в Login Items.
    private func registerLoginItemIfNeeded() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}
