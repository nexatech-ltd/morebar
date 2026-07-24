import AppKit
import SwiftUI

/// Управляет жизненным циклом второго бара: открытие/закрытие, обновление
/// снимков (при открытии и каждые 2 с), закрытие по клику вне панели и Esc.
@MainActor
final class PanelController {
    private let panel = SecondBarPanel()
    private let lister: MenuBarItemLister
    private let capturer = ItemImageCapturer()

    /// Форвард клика в реальную иконку (подключается в M6).
    var onItemClick: (CGWindowID, _ rightClick: Bool) -> Void = { _, _ in }
    var onVisibilityChange: (Bool) -> Void = { _ in }

    private(set) var isVisible = false
    private var refreshTimer: Timer?
    private var outsideClickMonitor: Any?
    private var escMonitor: Any?

    init(lister: MenuBarItemLister) {
        self.lister = lister
    }

    func toggle(iconFrame: CGRect?) {
        isVisible ? close() : open(iconFrame: iconFrame)
    }

    func open(iconFrame: CGRect?) {
        guard !isVisible, let screen = NSScreen.main else { return }
        isVisible = true
        onVisibilityChange(true)

        Task { await refreshContent() }
        panel.show(alignedTo: iconFrame, on: screen)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.refreshContent() }
        }
        installMonitors()
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        onVisibilityChange(false)
        refreshTimer?.invalidate()
        refreshTimer = nil
        removeMonitors()
        panel.hide()
    }

    // MARK: - Content

    private func refreshContent() async {
        guard isVisible, let screen = NSScreen.main else { return }
        let barHeight = screen.menuBarHeight

        let content: SecondBarView.Content
        switch PermissionsManager.status {
        case .granted where PermissionsManager.screenRecordingNeedsRelaunch:
            content = .needsRelaunch
        case .granted:
            let hidden = lister.hiddenItems()
            if hidden.isEmpty {
                content = .empty
            } else {
                let images = await capturer.captureImages(for: hidden.map(\.window))
                let entries = hidden.compactMap { item -> SecondBarView.Entry? in
                    guard let image = images[item.window.windowID] else { return nil }
                    return SecondBarView.Entry(
                        id: item.window.windowID,
                        image: image,
                        title: item.sourceApp?.localizedName
                    )
                }
                content = entries.isEmpty ? .empty : .items(entries)
            }
        case .missingAccessibility:
            content = .needsPermissions(accessibility: false, screenRecording: true)
        case .missingScreenRecording:
            content = .needsPermissions(accessibility: true, screenRecording: false)
        case .missingBoth:
            content = .needsPermissions(accessibility: false, screenRecording: false)
        }

        guard isVisible else { return }
        var view = SecondBarView(content: content, barHeight: barHeight)
        view.onItemClick = { [weak self] windowID, right in
            self?.onItemClick(windowID, right)
        }
        view.onOpenAccessibility = { PermissionsManager.openAccessibilitySettings() }
        view.onOpenScreenRecording = { PermissionsManager.openScreenRecordingSettings() }
        view.onRelaunch = { PermissionsManager.relaunch() }
        panel.setGlassContent(view, height: barHeight)
    }

    // MARK: - Dismissal

    private func installMonitors() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.isVisible else { return }
                // Глобальные координаты клика против фрейма панели.
                if !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.close()
                }
            }
        }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // Esc
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        outsideClickMonitor = nil
        escMonitor = nil
    }
}
