import AppKit
import SwiftUI

/// Панель «второго бара»: неактивирующая, без рамки, живёт чуть выше уровня
/// главного меню, ведёт себя как системный UI (не крадёт фокус, ходит между
/// Spaces, доступна поверх fullscreen). Конфигурация — как у Ice Bar (MIT).
@MainActor
final class SecondBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isMovable = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Ставит контент в «стекло» macOS 26 и подгоняет размер под содержимое.
    func setGlassContent<V: View>(_ view: V, height: CGFloat) {
        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)

        let glass = NSGlassEffectView()
        glass.cornerRadius = height / 2
        glass.contentView = hosting
        glass.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        contentView = glass
        setContentSize(hosting.fittingSize)
    }

    /// Показ под меню-баром: правый край панели — под правым краем окна
    /// нашей иконки (в пределах экрана), с зазором 4 pt под баром.
    func show(alignedTo iconFrameCG: CGRect?, on screen: NSScreen) {
        let gap: CGFloat = 4
        let size = frame.size
        let y = screen.frame.maxY - screen.menuBarHeight - size.height - gap

        // CG-координаты (origin сверху) и Cocoa (origin снизу) по x совпадают.
        var right = iconFrameCG?.maxX ?? screen.frame.maxX - 8
        right = min(right, screen.frame.maxX - 8)
        let x = max(screen.frame.minX + 8, right - size.width)

        setFrameOrigin(NSPoint(x: x, y: y))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Хендлер приходит на главном потоке — фиксируем это для компилятора.
            MainActor.assumeIsolated {
                self?.orderOut(nil)
            }
        })
    }
}
