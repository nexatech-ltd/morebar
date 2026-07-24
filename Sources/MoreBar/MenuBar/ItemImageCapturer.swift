import AppKit
import ScreenCaptureKit

/// The obsoleted-but-alive CoreGraphics window capture. ScreenCaptureKit
/// cannot capture off-screen menu bar item windows (SCStreamError -3811,
/// same finding as Ice on Tahoe), while this symbol still works for them.
/// Removed from the macOS 15+ SDK surface, hence the silgen declaration.
@_silgen_name("CGWindowListCreateImageFromArray")
private func CGWindowListCreateImageFromArray(
    _ screenBounds: CGRect,
    _ windowArray: CFArray,
    _ imageOption: UInt32
) -> Unmanaged<CGImage>?

/// Captures item window images.
/// On-screen windows go through ScreenCaptureKit; hidden (off-screen) ones —
/// the very reason this app exists — go through the legacy CGWindowList
/// capture, which is the only API able to shoot them. Both require the
/// Screen Recording permission.
final class ItemImageCapturer: Sendable {
    /// kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
    private static let legacyOptions: UInt32 = (1 << 0) | (1 << 3)

    /// Captures all given windows; the returned dictionary may be incomplete
    /// (a window disappeared, a capture failed).
    func captureImages(for windows: [WindowInfo]) async -> [CGWindowID: NSImage] {
        var images: [CGWindowID: NSImage] = [:]

        let offscreen = windows.filter { !$0.isOnScreen }
        let onscreen = windows.filter { $0.isOnScreen }

        for window in offscreen {
            if let image = Self.legacyCapture(window) {
                images[window.windowID] = image
            }
        }
        if !onscreen.isEmpty {
            for (id, image) in await sckCapture(onscreen) {
                images[id] = image
            }
        }
        return images
    }

    // MARK: - Legacy path (hidden windows)

    private static func legacyCapture(_ window: WindowInfo) -> NSImage? {
        guard window.frame.width > 1 else { return nil }
        var pointers: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(window.windowID))]
        guard let array = pointers.withUnsafeMutableBufferPointer({ buf in
            CFArrayCreate(kCFAllocatorDefault, buf.baseAddress, 1, nil)
        }) else { return nil }
        guard
            let cgImage = CGWindowListCreateImageFromArray(.null, array, legacyOptions)?
                .takeRetainedValue(),
            cgImage.width > 1
        else { return nil }
        // bestResolution captures at Retina scale; report point size so the
        // panel renders the icon at its natural bar size.
        let scale = CGFloat(cgImage.width) / window.frame.width
        let size = NSSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )
        return NSImage(cgImage: cgImage, size: size)
    }

    // MARK: - ScreenCaptureKit path (visible windows)

    private func sckCapture(_ windows: [WindowInfo]) async -> [CGWindowID: NSImage] {
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
