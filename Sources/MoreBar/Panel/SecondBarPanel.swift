import AppKit
import SwiftUI

/// The second-bar panel: non-activating, borderless, floating just above the
/// main-menu window level; behaves like system UI (never steals focus, moves
/// across Spaces, shows over fullscreen). Configured after Ice Bar (MIT).
@MainActor
final class SecondBarPanel: NSPanel {
    private var isShown = false

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

    /// The single show/update entry point: measure the content first, then
    /// place the frame so the right edge sits under the right edge of the
    /// "…" icon (anchorRightX) without ever leaving the screen.
    /// The order is critical: positioning AFTER measuring — otherwise the
    /// panel grows rightwards past the screen edge.
    func present(_ view: some View, height: CGFloat, anchorRightX: CGFloat?, on screen: NSScreen) {
        let hosting = NSHostingView(rootView: view)
        var size = hosting.fittingSize
        // Clamp the width: a long icon row must not run off the screen.
        size.width = min(size.width, screen.frame.width - 16)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let glass = NSGlassEffectView()
        glass.cornerRadius = height / 2
        glass.contentView = hosting
        contentView = glass

        let gap: CGFloat = 4
        let y = screen.frame.maxY - screen.menuBarHeight - size.height - gap
        let rightLimit = screen.frame.maxX - 8
        let right = min(anchorRightX ?? rightLimit, rightLimit)
        let x = max(screen.frame.minX + 8, right - size.width)
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        if !isShown {
            isShown = true
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // The handler arrives on the main thread — assert that for the compiler.
            MainActor.assumeIsolated {
                self?.orderOut(nil)
            }
        })
    }
}
