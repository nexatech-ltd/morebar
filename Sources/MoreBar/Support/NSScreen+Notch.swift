import AppKit

extension NSScreen {
    /// Menu bar height on this screen (equals safeAreaInsets.top on notched screens).
    var menuBarHeight: CGFloat {
        safeAreaInsets.top > 0 ? safeAreaInsets.top : NSStatusBar.system.thickness + 2
    }

    /// The notch rectangle in CG coordinates (origin at the top-left corner);
    /// nil on screens without a notch.
    var notchRect: CGRect? {
        guard
            safeAreaInsets.top > 0,
            let left = auxiliaryTopLeftArea,
            let right = auxiliaryTopRightArea
        else { return nil }
        // The auxiliary areas are in Cocoa coordinates (origin bottom-left);
        // convert to CG: y measured from the top of the screen.
        return CGRect(
            x: left.maxX,
            y: 0,
            width: right.minX - left.maxX,
            height: safeAreaInsets.top
        )
    }
}
