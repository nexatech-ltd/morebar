import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusIcon: StatusIconController?
    private var spacer: SpacerItem?
    private var lister: MenuBarItemLister?
    private var hiding: HidingController?
    private var panel: PanelController?
    private let permissions = PermissionsManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerLoginItemIfNeeded()

        let spacer = SpacerItem()
        let statusIcon = StatusIconController()
        let lister = MenuBarItemLister()
        let hiding = HidingController(spacer: spacer, lister: lister)
        let panel = PanelController(lister: lister)
        self.spacer = spacer
        self.statusIcon = statusIcon
        self.lister = lister
        self.hiding = hiding
        self.panel = panel

        statusIcon.onToggle = { [weak self] in
            guard let self else { return }
            self.panel?.toggle(iconFrame: self.iconFrameCG())
        }
        panel.onVisibilityChange = { [weak self] visible in
            self?.statusIcon?.isHighlighted = visible
        }
        panel.onItemClick = { windowID, rightClick in
            // Клик-прокси подключается в M6.
            _ = windowID
            _ = rightClick
        }

        permissions.onGranted = { [weak self] freshlyGranted in
            guard let self else { return }
            if PermissionsManager.screenRecordingNeedsRelaunch {
                // Запись экрана применяется только с перезапуска процесса.
                // Свежий грант — перезапускаемся сами; иначе кнопка в панели.
                if freshlyGranted {
                    PermissionsManager.relaunch()
                }
                return
            }
            Task { await self.hiding?.engage() }
        }
        permissions.requestIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hiding?.disengage()
    }

    /// Фрейм окна нашей иконки в CG-координатах — якорь для панели.
    /// На macOS 26 окно хостит Control Centre, поэтому ищем его по имени
    /// в CGWindowList (доступно после гранта «Записи экрана»), с фолбэком
    /// на локальное окно кнопки.
    private func iconFrameCG() -> CGRect? {
        if let window = WindowInfo.statusItemWindows()
            .first(where: { $0.name == StatusIconController.autosaveName }) {
            return window.frame
        }
        return statusIcon?.screenFrame
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
