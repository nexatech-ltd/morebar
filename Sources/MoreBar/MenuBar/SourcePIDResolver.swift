import AppKit
import ApplicationServices

/// Определяет процесс-«источник» окна статус-итема.
///
/// До macOS 26 хватало kCGWindowOwnerPID. На Tahoe окна итемов приложений,
/// собранных с SDK 26, хостит Control Centre, поэтому истинного создателя
/// ищем через Accessibility: у каждого запущенного приложения берём элемент
/// AXExtrasMenuBar (его секцию статус-итемов) и сравниваем центры фреймов
/// детей с центром окна (допуск 1 pt).
/// Порт идеи Ice MenuBarItemService/SourcePIDCache.swift (MIT).
final class SourcePIDResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedPIDs: [CGWindowID: pid_t] = [:]
    private var extrasBars: [pid_t: AXUIElement] = [:]

    /// PID Control Centre — единственный «владелец-посредник», для окон
    /// которого требуется AX-резолвинг.
    static func controlCenterPID() -> pid_t? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.controlcenter"
        ).first?.processIdentifier
    }

    /// Источник окна: для окон со «своим» владельцем — ownerPID,
    /// для CC-хостируемых — поиск через AX (nil, если не нашли).
    func resolveSourcePID(for window: WindowInfo, controlCenterPID: pid_t?) -> pid_t? {
        guard window.ownerPID == controlCenterPID else {
            return window.ownerPID
        }

        lock.lock()
        let cached = cachedPIDs[window.windowID]
        lock.unlock()
        if let cached, isProcessAlive(cached) { return cached }

        guard AXIsProcessTrusted() else { return nil }

        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        for app in NSWorkspace.shared.runningApplications {
            guard
                app.isFinishedLaunching,
                !app.isTerminated,
                app.activationPolicy != .prohibited
            else { continue }
            guard let bar = extrasMenuBar(for: app.processIdentifier) else { continue }
            for child in axChildren(of: bar) {
                guard
                    let frame = axFrame(of: child),
                    hypot(frame.midX - center.x, frame.midY - center.y) <= 1
                else { continue }
                lock.lock()
                cachedPIDs[window.windowID] = app.processIdentifier
                lock.unlock()
                return app.processIdentifier
            }
        }
        return nil
    }

    func invalidate(windowID: CGWindowID) {
        lock.lock()
        cachedPIDs[windowID] = nil
        lock.unlock()
    }

    // MARK: - AX plumbing

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid) != nil
    }

    private func extrasMenuBar(for pid: pid_t) -> AXUIElement? {
        lock.lock()
        let cached = extrasBars[pid]
        lock.unlock()
        if let cached { return cached }

        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success,
            let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(bar, to: AXUIElement.self)
        lock.lock()
        extrasBars[pid] = element
        lock.unlock()
        return element
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
            let array = value as? [AnyObject]
        else { return [] }
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
            let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(axValue, to: AXValue.self), .cgRect, &rect) else {
            return nil
        }
        return rect
    }
}
