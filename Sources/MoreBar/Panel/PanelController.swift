import AppKit
import SwiftUI

/// Owns the second bar lifecycle: open/close, snapshot refresh (on open and
/// every 2 s while open), dismissal on outside click and Esc.
@MainActor
final class PanelController {
    private let panel = SecondBarPanel()
    private let lister: MenuBarItemLister
    private let capturer = ItemImageCapturer()

    /// Forwards a click to the real icon (wired up in M6).
    var onItemClick: (CGWindowID, _ rightClick: Bool) -> Void = { _, _ in }
    var onVisibilityChange: (Bool) -> Void = { _ in }

    private(set) var isVisible = false
    /// Right edge of the "…" icon — the panel anchor, captured at open time.
    private var anchorRightX: CGFloat?
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
        guard !isVisible else { return }
        isVisible = true
        anchorRightX = iconFrame?.maxX
        onVisibilityChange(true)

        Task { await refreshContent() }

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
        panel.dismiss()
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
        panel.present(view, height: barHeight, anchorRightX: anchorRightX, on: screen)
    }

    // MARK: - Dismissal

    private func installMonitors() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isVisible else { return }
                // Global click location vs the panel frame.
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
