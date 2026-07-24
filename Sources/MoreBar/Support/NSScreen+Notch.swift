import AppKit

extension NSScreen {
    /// Высота меню-бара этого экрана (на экранах с чёлкой = safeAreaInsets.top).
    var menuBarHeight: CGFloat {
        safeAreaInsets.top > 0 ? safeAreaInsets.top : NSStatusBar.system.thickness + 2
    }

    /// Прямоугольник чёлки в CG-координатах (origin в левом верхнем углу),
    /// nil на экранах без чёлки.
    var notchRect: CGRect? {
        guard
            safeAreaInsets.top > 0,
            let left = auxiliaryTopLeftArea,
            let right = auxiliaryTopRightArea
        else { return nil }
        // auxiliary-области — в Cocoa-координатах (origin слева внизу);
        // переводим в CG: y от верха экрана.
        return CGRect(
            x: left.maxX,
            y: 0,
            width: right.minX - left.maxX,
            height: safeAreaInsets.top
        )
    }
}
