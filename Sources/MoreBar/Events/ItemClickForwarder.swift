import AppKit
import os

/// Forwards clicks from the second bar to real menu bar items, and moves
/// items between the hidden and visible zones with synthetic events.
///
/// There is no public API for either operation. This is a focused port of
/// Ice's MenuBarItemManager (MIT, github.com/jordanbaird/Ice, branch
/// macos-26): a Cmd-flagged leftMouseDown + plain leftMouseUp pair with
/// special event fields performs a "drag" move; a down/up pair with the
/// same fields performs a click. Events are trampolined ("scrombled")
/// between a pid-specific tap and the session tap so the item actually
/// receives them. All fragile constants live in this one file so that a
/// minor macOS update can be patched quickly.
@MainActor
final class ItemClickForwarder {
    private static let log = Logger(subsystem: "com.nexatech.MoreBar", category: "clickForwarder")

    private let lister: MenuBarItemLister
    private var inProgress = false

    /// Pending rehide state: the shown item should go back to the hidden
    /// zone once its interface closes and the user pauses input.
    private struct PendingRehide {
        let windowID: CGWindowID
        var shownInterfaceWindowID: CGWindowID?
        var attempts = 0
    }
    private var pendingRehide: PendingRehide?
    private var rehideTimer: Timer?

    init(lister: MenuBarItemLister) {
        self.lister = lister
    }

    // MARK: - Public entry point

    /// Temporarily shows the hidden item with the given window, clicks it,
    /// and schedules its return to the hidden zone.
    func showAndClick(windowID: CGWindowID, button: CGMouseButton) async {
        guard !inProgress else { return }
        inProgress = true
        defer { inProgress = false }

        guard let item = lister.currentItems().first(where: { $0.window.windowID == windowID }) else {
            Self.log.error("item for window \(windowID) not found")
            return
        }

        do {
            let wasHidden = !item.window.isOnScreen
            if wasHidden {
                try await temporarilyShow(item)
            }
            try await waitForUserToPauseInput()
            let idsBeforeClick = onScreenWindowIDs()
            try await click(item: item, with: button)

            guard wasHidden else { return }

            // Detect the popped-up interface (menu/popover) of the item:
            // a new on-screen window from the same source process.
            try? await Task.sleep(for: .milliseconds(250))
            let eventPID = eventPID(for: item)
            let newWindow = onScreenWindows().first { window in
                window.ownerPID == eventPID && !idsBeforeClick.contains(window.windowID)
            }
            pendingRehide = PendingRehide(
                windowID: windowID,
                shownInterfaceWindowID: newWindow?.windowID
            )
            scheduleRehide(after: 2.5)
        } catch {
            Self.log.error("showAndClick failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Rehide policy

    /// Rehide policy: wait until the item's interface closed AND the user
    /// paused input; then move the item back left of the spacer (the hidden
    /// zone). Gives up after 40 attempts (~2 minutes at the fastest pace).
    private func scheduleRehide(after interval: TimeInterval) {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor [weak self] in await self?.rehideIfPossible() }
        }
    }

    private func rehideIfPossible() async {
        guard var pending = pendingRehide else { return }

        if let interfaceID = pending.shownInterfaceWindowID,
           onScreenWindowIDs().contains(interfaceID) {
            // The menu/popover is still open — check again later.
            scheduleRehide(after: 3)
            return
        }
        guard MouseHelpers.secondsSinceLastUserInput() > 0.25 else {
            scheduleRehide(after: 1)
            return
        }

        pending.attempts += 1
        pendingRehide = pending
        guard pending.attempts <= 40 else {
            Self.log.error("giving up on rehide after \(pending.attempts) attempts")
            pendingRehide = nil
            return
        }

        guard
            let item = lister.currentItems().first(where: { $0.window.windowID == pending.windowID }),
            item.window.isOnScreen
        else {
            // Already hidden (or gone) — done.
            pendingRehide = nil
            return
        }
        guard let spacerItem = spacerAsItem() else {
            pendingRehide = nil
            return
        }

        do {
            try await move(item: item, to: .leftOfItem(spacerItem))
            pendingRehide = nil
            Self.log.info("item \(pending.windowID) returned to hidden zone")
        } catch {
            Self.log.error("rehide failed: \(error, privacy: .public)")
            scheduleRehide(after: 2)
        }
    }

    // MARK: - Temporarily showing

    /// Moves a hidden item into the visible zone: left of the leftmost
    /// on-screen item that has room (right of the notch).
    private func temporarilyShow(_ item: MenuBarItem) async throws {
        guard let screen = NSScreen.main else { throw EventError.cannotComplete }

        // The leftmost x where the shown item may land: right of the notch
        // (or of the screen middle when there is no notch), like Ice.
        let leftBound: CGFloat = (screen.notchRect?.maxX ?? screen.frame.midX)
            + 30 + item.window.frame.width

        let candidates = WindowInfo.statusItemWindows()
            .filter { $0.isOnScreen && $0.windowID != item.window.windowID }
            .filter { $0.frame.minX > leftBound }
            .sorted { $0.frame.minX < $1.frame.minX }

        guard let targetWindow = candidates.first else {
            Self.log.warning("not enough room to show item \(item.window.windowID)")
            throw EventError.notEnoughRoom
        }
        let target = MenuBarItem(window: targetWindow, sourcePID: targetWindow.ownerPID)
        try await move(item: item, to: .leftOfItem(target))
    }

    /// The spacer as a MenuBarItem — the anchor of the hidden zone.
    private func spacerAsItem() -> MenuBarItem? {
        WindowInfo.statusItemWindows()
            .filter { $0.name == SpacerItem.autosaveName }
            .max { $0.windowID < $1.windowID }
            .map { MenuBarItem(window: $0, sourcePID: pid_t(ProcessInfo.processInfo.processIdentifier)) }
    }

    // MARK: - Errors

    enum EventError: Error, CustomStringConvertible {
        case cannotComplete
        case eventCreationFailure
        case eventOperationTimeout
        case itemResponseTimeout
        case notEnoughRoom

        var description: String {
            switch self {
            case .cannotComplete: "operation cannot complete"
            case .eventCreationFailure: "failed to create event"
            case .eventOperationTimeout: "event operation timed out"
            case .itemResponseTimeout: "item did not respond"
            case .notEnoughRoom: "not enough room to show item"
            }
        }
    }

    // MARK: - Moving

    enum MoveDestination {
        case leftOfItem(MenuBarItem)
        case rightOfItem(MenuBarItem)

        var targetItem: MenuBarItem {
            switch self {
            case .leftOfItem(let item), .rightOfItem(let item): item
            }
        }
    }

    /// Moves a menu bar item to the destination, retrying up to 5 times.
    func move(item: MenuBarItem, to destination: MoveDestination) async throws {
        try await waitForUserToPauseInput()

        if try itemHasCorrectPosition(item: item, for: destination) { return }

        MouseHelpers.hideCursor()
        defer { MouseHelpers.showCursor() }

        let maxAttempts = 5
        for attempt in 1...maxAttempts {
            do {
                if try itemHasCorrectPosition(item: item, for: destination) { return }
                try await postMoveEvents(item: item, destination: destination)
                return
            } catch {
                Self.log.debug("move attempt \(attempt) failed: \(error, privacy: .public)")
                if attempt == maxAttempts {
                    throw error
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func getCurrentBounds(for windowID: CGWindowID) throws -> CGRect {
        let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowNumber as String] as? CGWindowID) == windowID {
            guard let b = info[kCGWindowBounds as String] as? [String: Any] else { break }
            return CGRect(
                x: b["X"] as? CGFloat ?? 0,
                y: b["Y"] as? CGFloat ?? 0,
                width: b["Width"] as? CGFloat ?? 0,
                height: b["Height"] as? CGFloat ?? 0
            )
        }
        throw EventError.cannotComplete
    }

    private func itemHasCorrectPosition(item: MenuBarItem, for destination: MoveDestination) throws -> Bool {
        let itemBounds = try getCurrentBounds(for: item.window.windowID)
        let targetBounds = try getCurrentBounds(for: destination.targetItem.window.windowID)
        return switch destination {
        case .leftOfItem: itemBounds.maxX == targetBounds.minX
        case .rightOfItem: itemBounds.minX == targetBounds.maxX
        }
    }

    /// Start/end points of the synthetic drag (port of Ice getTargetPoints).
    private func getTargetPoints(
        forMoving item: MenuBarItem,
        to destination: MoveDestination
    ) throws -> (start: CGPoint, end: CGPoint) {
        let itemBounds = try getCurrentBounds(for: item.window.windowID)
        let targetBounds = try getCurrentBounds(for: destination.targetItem.window.windowID)
        switch destination {
        case .leftOfItem:
            var start = CGPoint(x: targetBounds.minX, y: targetBounds.minY)
            var end = start
            if itemBounds.maxX <= targetBounds.minX {
                end.x -= itemBounds.width
            } else {
                start.x -= 1
            }
            return (start, end)
        case .rightOfItem:
            var start = CGPoint(x: targetBounds.maxX, y: targetBounds.minY)
            var end = start
            if itemBounds.minX <= targetBounds.maxX {
                end.x -= itemBounds.width
            } else {
                start.x += 1
            }
            return (start, end)
        }
    }

    private func waitForMoveEventResponse(
        item: MenuBarItem,
        initialOrigin: CGPoint,
        timeout: Duration
    ) async throws -> CGPoint {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let origin = try getCurrentBounds(for: item.window.windowID).origin
            if origin != initialOrigin { return origin }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw EventError.itemResponseTimeout
    }

    private func postMoveEvents(item: MenuBarItem, destination: MoveDestination) async throws {
        var itemOrigin = try getCurrentBounds(for: item.window.windowID).origin
        let targetPoints = try getTargetPoints(forMoving: item, to: destination)
        let mouseLocation = MouseHelpers.locationCoreGraphics
        let source = try eventSource()
        try permitLocalEvents()

        guard
            let mouseDown = CGEvent.menuBarItemEvent(
                windowID: item.window.windowID,
                source: source,
                type: .move(.mouseDown),
                location: targetPoints.start
            ),
            let mouseUp = CGEvent.menuBarItemEvent(
                windowID: destination.targetItem.window.windowID,
                source: source,
                type: .move(.mouseUp),
                location: targetPoints.end
            )
        else {
            throw EventError.eventCreationFailure
        }

        let timeout = Duration.milliseconds(100)
        MouseHelpers.hideCursor()
        defer {
            if let mouseLocation { MouseHelpers.warpCursor(to: mouseLocation) }
            MouseHelpers.showCursor()
        }

        do {
            try await scrombleEvent(mouseDown, pid: eventPID(for: item), timeout: timeout)
            itemOrigin = try await waitForMoveEventResponse(
                item: item, initialOrigin: itemOrigin, timeout: timeout
            )
            // Double mouse up prevents an invalid item state (Ice).
            try await scrombleEvent(mouseUp, pid: eventPID(for: item), timeout: timeout, repeating: 2)
            _ = try await waitForMoveEventResponse(
                item: item, initialOrigin: itemOrigin, timeout: timeout
            )
        } catch {
            // Fallback: always finish with mouse up so the item is not left
            // in a dragged state.
            try? await scrombleEvent(
                mouseUp, pid: eventPID(for: item), timeout: .milliseconds(100), repeating: 2
            )
            throw error
        }
    }

    // MARK: - Clicking

    /// Clicks a menu bar item (which must be on screen).
    func click(item: MenuBarItem, with button: CGMouseButton) async throws {
        let clickPoint = try getCurrentBounds(for: item.window.windowID).center
        let mouseLocation = MouseHelpers.locationCoreGraphics
        let source = try eventSource()
        try permitLocalEvents()

        let subtypes: (down: CGEvent.MenuBarItemEventType.ClickSubtype, up: CGEvent.MenuBarItemEventType.ClickSubtype) =
            switch button {
            case .left: (.leftMouseDown, .leftMouseUp)
            case .right: (.rightMouseDown, .rightMouseUp)
            default: (.otherMouseDown, .otherMouseUp)
            }

        guard
            let mouseDown = CGEvent.menuBarItemEvent(
                windowID: item.window.windowID,
                source: source,
                type: .click(subtypes.down),
                location: clickPoint
            ),
            let mouseUp = CGEvent.menuBarItemEvent(
                windowID: item.window.windowID,
                source: source,
                type: .click(subtypes.up),
                location: clickPoint
            )
        else {
            throw EventError.eventCreationFailure
        }

        let timeout = Duration.milliseconds(250)
        MouseHelpers.hideCursor()
        defer {
            if let mouseLocation { MouseHelpers.warpCursor(to: mouseLocation) }
            MouseHelpers.showCursor()
        }

        let pid = eventPID(for: item)
        do {
            try await postEventWithBarrier(mouseDown, pid: pid, timeout: timeout)
            // Double mouse up prevents an invalid item state (Ice).
            try await postEventWithBarrier(mouseUp, pid: pid, timeout: timeout, repeating: 2)
        } catch {
            try? await postEventWithBarrier(mouseUp, pid: pid, timeout: timeout, repeating: 2)
            throw error
        }
    }

    // MARK: - Event plumbing (the fragile core)

    /// PID that receives item events: the source app, or the window owner
    /// (Control Centre) when the source is unknown — `sourcePID ?? ownerPID`
    /// per Ice on macOS 26.
    private func eventPID(for item: MenuBarItem) -> pid_t {
        item.sourcePID ?? item.window.ownerPID
    }

    private var cachedSources: [CGEventSourceStateID: CGEventSource] = [:]

    private func eventSource(with stateID: CGEventSourceStateID = .hidSystemState) throws -> CGEventSource {
        if let source = cachedSources[stateID] { return source }
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError.cannotComplete
        }
        cachedSources[stateID] = source
        return source
    }

    /// Prevents local events from being suppressed while we synthesize input.
    private func permitLocalEvents() throws {
        let source = try eventSource(with: .combinedSessionState)
        let permitAll: CGEventFilterMask = [
            .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents,
        ]
        for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag,
                      .eventSuppressionStateSuppressionInterval] {
            source.setLocalEventsFilterDuringSuppressionState(permitAll, state: state)
        }
        source.localEventsSuppressionInterval = 0
    }

    private func waitForUserToPauseInput() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while MouseHelpers.secondsSinceLastUserInput() < 0.25 {
            if ContinuousClock.now > deadline { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func onScreenWindows() -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard
                let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t
            else { return nil }
            return WindowInfo(
                windowID: windowID, frame: .zero, isOnScreen: true,
                ownerPID: ownerPID, name: info[kCGWindowName as String] as? String
            )
        }
    }

    private func onScreenWindowIDs() -> Set<CGWindowID> {
        Set(onScreenWindows().map(\.windowID))
    }

    /// Posts an event to the item's process and waits for it to round-trip
    /// through the session tap (port of Ice postEventWithBarrier).
    private func postEventWithBarrier(
        _ event: CGEvent,
        pid: pid_t,
        timeout: Duration,
        repeating count: Int = 1
    ) async throws {
        MouseHelpers.hideCursor()
        defer { MouseHelpers.showCursor() }

        guard
            let entryEvent = CGEvent.uniqueNullEvent(),
            let exitEvent = CGEvent.uniqueNullEvent()
        else { throw EventError.eventCreationFailure }

        event.setTargetPID(pid)
        var remaining = count
        var eventTaps: [EventTap] = []

        try await withTimeout(timeout * count) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeOnce = ResumeOnce(continuation)

                // Tap 1 at the pid location: entry event -> post the real
                // event to the session tap; exit event -> resume.
                let tap1 = EventTap(
                    label: "barrier.pid", type: .null,
                    location: .pid(pid), placement: .headInsertEventTap, option: .defaultTap
                ) { tap, rEvent in
                    if rEvent.matches(entryEvent, byIntegerFields: [.eventSourceUserData]) {
                        remaining -= 1
                        event.post(to: .sessionEventTap)
                        return nil
                    }
                    if rEvent.matches(exitEvent, byIntegerFields: [.eventSourceUserData]) {
                        tap.disable()
                        resumeOnce.resume()
                        return nil
                    }
                    return rEvent
                }

                // Tap 2 at the session tap: when the real event arrives,
                // either continue the loop or signal completion.
                let tap2 = EventTap(
                    label: "barrier.session", type: event.type,
                    location: .sessionEventTap, placement: .tailAppendEventTap, option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if remaining <= 0 {
                        tap.disable()
                        exitEvent.post(to: .pid(pid))
                    } else {
                        entryEvent.post(to: .pid(pid))
                    }
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                eventTaps.append(tap1)
                eventTaps.append(tap2)
                tap1.enable()
                tap2.enable()
                entryEvent.post(to: .pid(pid))
            }
        } onTimeout: {
            for tap in eventTaps { tap.disable() }
        }
        withExtendedLifetime(eventTaps) {}
    }

    /// "Casts forbidden magic": posts an event during a move operation so
    /// the item receives AND responds to it (port of Ice scrombleEvent).
    private func scrombleEvent(
        _ event: CGEvent,
        pid: pid_t,
        timeout: Duration,
        repeating count: Int = 1
    ) async throws {
        MouseHelpers.hideCursor()
        defer { MouseHelpers.showCursor() }

        guard
            let entryEvent = CGEvent.uniqueNullEvent(),
            let exitEvent = CGEvent.uniqueNullEvent()
        else { throw EventError.eventCreationFailure }

        event.setTargetPID(pid)
        var remaining = count
        var eventTaps: [EventTap] = []

        try await withTimeout(timeout * count) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeOnce = ResumeOnce(continuation)

                let tap1 = EventTap(
                    label: "scromble.null", type: .null,
                    location: .pid(pid), placement: .headInsertEventTap, option: .defaultTap
                ) { tap, rEvent in
                    if rEvent.matches(entryEvent, byIntegerFields: [.eventSourceUserData]) {
                        remaining -= 1
                        event.post(to: .sessionEventTap)
                        return nil
                    }
                    if rEvent.matches(exitEvent, byIntegerFields: [.eventSourceUserData]) {
                        tap.disable()
                        resumeOnce.resume()
                        return nil
                    }
                    return rEvent
                }

                // Session tap: repost the real event to the pid location.
                let tap2 = EventTap(
                    label: "scromble.session", type: event.type,
                    location: .sessionEventTap, placement: .tailAppendEventTap, option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if remaining <= 0 {
                        tap.disable()
                    }
                    event.post(to: .pid(pid))
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                // Pid tap for the real event: continue or exit the loop.
                let tap3 = EventTap(
                    label: "scromble.pid", type: event.type,
                    location: .pid(pid), placement: .headInsertEventTap, option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if remaining <= 0 {
                        tap.disable()
                        exitEvent.post(to: .pid(pid))
                    } else {
                        entryEvent.post(to: .pid(pid))
                    }
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                eventTaps.append(tap1)
                eventTaps.append(tap2)
                eventTaps.append(tap3)
                tap1.enable()
                tap2.enable()
                tap3.enable()
                entryEvent.post(to: .pid(pid))
            }
        } onTimeout: {
            for tap in eventTaps { tap.disable() }
        }
        withExtendedLifetime(eventTaps) {}
    }

    /// Runs the operation with a timeout; calls onTimeout and throws when
    /// the clock runs out first.
    private func withTimeout(
        _ timeout: Duration,
        operation: @escaping @MainActor () async throws -> Void,
        onTimeout: @escaping @MainActor () -> Void
    ) async throws {
        let operationTask = Task { @MainActor in
            try await operation()
        }
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            if !operationTask.isCancelled {
                onTimeout()
                operationTask.cancel()
            }
        }
        do {
            try await operationTask.value
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            throw EventError.eventOperationTimeout
        }
    }
}

/// Resumes a continuation exactly once even when several tap callbacks race.
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

// MARK: - CGEvent helpers (constants ported verbatim from Ice)

extension CGEventField {
    /// Private field that contains the event's target window identifier.
    static let windowID = CGEventField(rawValue: 0x33)!

    /// Fields used to recognize our synthetic menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}

extension CGEvent {
    enum MenuBarItemEventType {
        case move(MoveSubtype)
        case click(ClickSubtype)

        enum MoveSubtype {
            case mouseDown, mouseUp

            var cgEventType: CGEventType {
                switch self {
                case .mouseDown: .leftMouseDown
                case .mouseUp: .leftMouseUp
                }
            }
        }

        enum ClickSubtype {
            case leftMouseDown, leftMouseUp
            case rightMouseDown, rightMouseUp
            case otherMouseDown, otherMouseUp

            var cgEventType: CGEventType {
                switch self {
                case .leftMouseDown: .leftMouseDown
                case .leftMouseUp: .leftMouseUp
                case .rightMouseDown: .rightMouseDown
                case .rightMouseUp: .rightMouseUp
                case .otherMouseDown: .otherMouseDown
                case .otherMouseUp: .otherMouseUp
                }
            }

            var cgMouseButton: CGMouseButton {
                switch self {
                case .leftMouseDown, .leftMouseUp: .left
                case .rightMouseDown, .rightMouseUp: .right
                case .otherMouseDown, .otherMouseUp: .center
                }
            }

            var clickState: Int64 {
                switch self {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown: 1
                case .leftMouseUp, .rightMouseUp, .otherMouseUp: 0
                }
            }
        }

        var cgEventType: CGEventType {
            switch self {
            case .move(let subtype): subtype.cgEventType
            case .click(let subtype): subtype.cgEventType
            }
        }

        /// The Cmd flag on move-mouseDown is what turns the event pair into
        /// an item drag.
        var cgEventFlags: CGEventFlags {
            switch self {
            case .move(.mouseDown): .maskCommand
            case .move, .click: []
            }
        }

        var cgMouseButton: CGMouseButton {
            switch self {
            case .move: .left
            case .click(let subtype): subtype.cgMouseButton
            }
        }
    }

    /// Builds an event that a menu bar item will accept (port of Ice
    /// CGEvent.menuBarItemEvent).
    static func menuBarItemEvent(
        windowID: CGWindowID,
        source: CGEventSource,
        type: MenuBarItemEventType,
        location: CGPoint
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type.cgEventType,
            mouseCursorPosition: location,
            mouseButton: type.cgMouseButton
        ) else {
            return nil
        }

        event.flags = type.cgEventFlags

        let userData = Int64(Int(bitPattern: ObjectIdentifier(event)))
        event.setIntegerValueField(.eventSourceUserData, value: userData)

        let windowID64 = Int64(windowID)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID64)
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID64
        )
        if case .move = type {
            event.setIntegerValueField(.windowID, value: windowID64)
        }
        if case .click(let subtype) = type {
            event.setIntegerValueField(.mouseEventClickState, value: subtype.clickState)
        }
        return event
    }

    /// A null event with unique user data (start/stop signal for trampolines).
    static func uniqueNullEvent() -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let userData = Int64(Int(bitPattern: ObjectIdentifier(event)))
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        return event
    }

    func setTargetPID(_ pid: pid_t) {
        setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
    }

    func matches(_ other: CGEvent, byIntegerFields fields: [CGEventField]) -> Bool {
        fields.allSatisfy { field in
            getIntegerValueField(field) == other.getIntegerValueField(field)
        }
    }

    func post(to location: EventTap.Location) {
        switch location {
        case .hidEventTap: post(tap: .cghidEventTap)
        case .sessionEventTap: post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap: post(tap: .cgAnnotatedSessionEventTap)
        case .pid(let pid): postToPid(pid)
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
