import AppKit
import ScreenCaptureKit

/// Снимки окон иконок через ScreenCaptureKit.
/// Ключевое: SCContentFilter(desktopIndependentWindow:) снимает окно
/// независимо от его положения — в т.ч. запаркованные за экраном иконки
/// (проверено на macOS 26.5). Требует права «Запись экрана».
final class ItemImageCapturer: Sendable {
    /// Снимает все переданные окна; вернувшийся словарь может быть неполным
    /// (окно исчезло, capture не удался).
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
