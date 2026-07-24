import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusIcon: StatusIconController?
    private var spacer: SpacerItem?
    private var lister: MenuBarItemLister?
    private var hiding: HidingController?
    private var panel: PanelController?
    private var forwarder: ItemClickForwarder?
    private let permissions = PermissionsManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerLoginItemIfNeeded()

        let spacer = SpacerItem()
        let statusIcon = StatusIconController()
        let lister = MenuBarItemLister()
        let forwarder = ItemClickForwarder(lister: lister)
        let hiding = HidingController(spacer: spacer, lister: lister, forwarder: forwarder)
        let panel = PanelController(lister: lister)
        self.spacer = spacer
        self.statusIcon = statusIcon
        self.lister = lister
        self.forwarder = forwarder
        self.hiding = hiding
        self.panel = panel
        hiding.isPanelVisible = { [weak panel] in panel?.isVisible ?? false }

        statusIcon.onToggle = { [weak self] in
            guard let self else { return }
            self.panel?.toggle(iconFrame: self.iconFrameCG())
        }
        panel.onVisibilityChange = { [weak self] visible in
            self?.statusIcon?.isHighlighted = visible
        }
        panel.onItemClick = { [weak self] windowID, rightClick in
            // Close the panel just before forwarding (Ice does the same) so
            // the item's own menu does not fight our panel for the screen.
            self?.panel?.close()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(25))
                await forwarder.showAndClick(
                    windowID: windowID,
                    button: rightClick ? .right : .left
                )
            }
        }

        permissions.onGranted = { [weak self] freshlyGranted in
            guard let self else { return }
            if PermissionsManager.screenRecordingNeedsRelaunch {
                // Screen Recording only takes effect after a process restart.
                // Fresh grant: relaunch ourselves; otherwise the panel offers a button.
                if freshlyGranted {
                    PermissionsManager.relaunch()
                }
                return
            }
            self.startReconcileTimer()
        }
        permissions.requestIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hiding?.disengage()
    }

    /// Hiding is an idempotent reconcile pass every 5 s: it picks up
    /// third-party icons that appear after launch (newly started apps).
    private var reconcileTimer: Timer?
    private func startReconcileTimer() {
        guard reconcileTimer == nil else { return }
        Task { await hiding?.engage() }
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.hiding?.engage() }
        }
    }

    /// Frame of our icon's window in CG coordinates — the panel anchor.
    /// On macOS 26 the window is hosted by Control Centre, so we look it up
    /// by name in CGWindowList (available once Screen Recording is granted),
    /// falling back to the local button window.
    private func iconFrameCG() -> CGRect? {
        if let window = WindowInfo.statusItemWindows()
            .first(where: { $0.name == StatusIconController.autosaveName }) {
            return window.frame
        }
        return statusIcon?.screenFrame
    }

    /// Login item registration: only for the copy installed in /Applications,
    /// so dev builds from the project directory never enroll in Login Items.
    private func registerLoginItemIfNeeded() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}
