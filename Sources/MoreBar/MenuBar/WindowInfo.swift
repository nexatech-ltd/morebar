import AppKit

/// Снимок окна статус-итема из CGWindowList.
/// Координаты — CG (начало в левом верхнем углу главного экрана).
struct WindowInfo: Sendable {
    let windowID: CGWindowID
    let frame: CGRect
    let isOnScreen: Bool
    let ownerPID: pid_t
    /// Для окон, хостируемых Control Centre (macOS 26), имя = autosaveName итема.
    /// Чтение имён чужих окон требует разрешения «Запись экрана».
    let name: String?

    /// Все окна на слое статус-итемов (kCGStatusWindowLevel), включая off-screen.
    static func statusItemWindows() -> [WindowInfo] {
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard
                (info[kCGWindowLayer as String] as? Int) == statusLayer,
                let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t
            else {
                return nil
            }
            let frame = CGRect(
                x: boundsDict["X"] as? CGFloat ?? 0,
                y: boundsDict["Y"] as? CGFloat ?? 0,
                width: boundsDict["Width"] as? CGFloat ?? 0,
                height: boundsDict["Height"] as? CGFloat ?? 0
            )
            return WindowInfo(
                windowID: windowID,
                frame: frame,
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                ownerPID: ownerPID,
                name: info[kCGWindowName as String] as? String
            )
        }
    }

    /// Свежий фрейм этого окна (nil — окно исчезло).
    func currentFrame() -> CGRect? {
        let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowNumber as String] as? CGWindowID) == windowID {
            guard let b = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(
                x: b["X"] as? CGFloat ?? 0,
                y: b["Y"] as? CGFloat ?? 0,
                width: b["Width"] as? CGFloat ?? 0,
                height: b["Height"] as? CGFloat ?? 0
            )
        }
        return nil
    }
}
