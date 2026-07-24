import AppKit
import os

/// An object that receives events from a defined point in the event stream.
/// Port of Ice/Events/EventTap.swift (MIT, github.com/jordanbaird/Ice).
final class EventTap {
    /// Insertion points for event taps.
    enum Location {
        case hidEventTap
        case sessionEventTap
        case annotatedSessionEventTap
        /// The point where events are delivered to the given process.
        case pid(pid_t)
    }

    private static let log = Logger(subsystem: "com.nexatech.MoreBar", category: "eventTap")

    /// Shared C callback for all taps.
    private static let sharedCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            tap.enable()
            return nil
        }
        guard tap.isEnabled else {
            return Unmanaged.passUnretained(event)
        }
        return tap.callback(tap, event).map { Unmanaged.passUnretained($0) }
    }

    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?
    private let callback: (EventTap, CGEvent) -> CGEvent?
    let label: String

    var isEnabled: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    init(
        label: String,
        types: [CGEventType],
        location: Location,
        placement: CGEventTapPlacement,
        option: CGEventTapOptions,
        callback: @escaping (_ tap: EventTap, _ event: CGEvent) -> CGEvent?
    ) {
        self.label = label
        self.callback = callback

        let mask: CGEventMask = types.reduce(0) { $0 | (1 << $1.rawValue) }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let machPort: CFMachPort? = switch location {
        case .hidEventTap:
            CGEvent.tapCreate(
                tap: .cghidEventTap, place: placement, options: option,
                eventsOfInterest: mask, callback: Self.sharedCallback, userInfo: userInfo
            )
        case .sessionEventTap:
            CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: placement, options: option,
                eventsOfInterest: mask, callback: Self.sharedCallback, userInfo: userInfo
            )
        case .annotatedSessionEventTap:
            CGEvent.tapCreate(
                tap: .cgAnnotatedSessionEventTap, place: placement, options: option,
                eventsOfInterest: mask, callback: Self.sharedCallback, userInfo: userInfo
            )
        case .pid(let pid):
            CGEvent.tapCreateForPid(
                pid: pid, place: placement, options: option,
                eventsOfInterest: mask, callback: Self.sharedCallback, userInfo: userInfo
            )
        }

        guard
            let machPort,
            let source = CFMachPortCreateRunLoopSource(nil, machPort, 0)
        else {
            Self.log.error("failed to create event tap \"\(label, privacy: .public)\"")
            return
        }
        self.machPort = machPort
        self.source = source
    }

    convenience init(
        label: String,
        type: CGEventType,
        location: Location,
        placement: CGEventTapPlacement,
        option: CGEventTapOptions,
        callback: @escaping (_ tap: EventTap, _ event: CGEvent) -> CGEvent?
    ) {
        self.init(
            label: label, types: [type], location: location,
            placement: placement, option: option, callback: callback
        )
    }

    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFMachPortInvalidate(machPort)
        }
    }

    func enable() {
        guard let machPort, let source else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    func disable() {
        guard let machPort, let source else { return }
        CGEvent.tapEnable(tap: machPort, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
}
