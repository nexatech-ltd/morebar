import AppKit

/// Small cursor utilities used while posting synthetic events.
enum MouseHelpers {
    /// Current mouse location in CoreGraphics (top-left origin) coordinates.
    static var locationCoreGraphics: CGPoint? {
        CGEvent(source: nil)?.location
    }

    static func hideCursor() {
        CGDisplayHideCursor(CGMainDisplayID())
    }

    static func showCursor() {
        CGDisplayShowCursor(CGMainDisplayID())
    }

    /// Moves the cursor without generating events.
    static func warpCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
    }

    /// Seconds since the last real user input of the given types.
    static func secondsSinceLastUserInput() -> TimeInterval {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .scrollWheel, .keyDown,
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .greatestFiniteMagnitude
    }
}
