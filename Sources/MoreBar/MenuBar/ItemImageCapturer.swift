import AppKit
import ScreenCaptureKit

/// Captures item window images via ScreenCaptureKit.
/// Key point: SCContentFilter(desktopIndependentWindow:) captures a window
/// regardless of its position — including icons parked off screen (verified
/// on macOS 26.5). Requires the Screen Recording permission.
final class ItemImageCapturer: Sendable {
    /// Captures all given windows; the returned dictionary may be incomplete
    /// (a window disappeared, a capture failed).
    func captureImages(for windows: [WindowInfo]) async -> [CGWindowID: NSImage] {
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        else { return [:] }

        let scWindows = Dictionary(
            content.windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var images: [CGWindowID: NSImage] = [:]
        for window in windows {
            guard let scWindow = scWindows[window.windowID], scWindow.frame.width > 1 else { continue }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.ignoreGlobalClipSingleWindow = true
            config.captureResolution = .best
            guard
                let cgImage = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
            else { continue }
            let size = NSSize(
                width: CGFloat(cgImage.width) / scale,
                height: CGFloat(cgImage.height) / scale
            )
            images[window.windowID] = NSImage(cgImage: cgImage, size: size)
        }
        return images
    }
}
