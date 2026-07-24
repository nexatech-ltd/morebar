import Foundation

/// Access to the system NSStatusItem UserDefaults keys
/// ("NSStatusItem Preferred Position <autosaveName>" and friends).
/// The position is measured in points from the right edge of the status
/// item section: 0 is rightmost among third-party items; larger values
/// place the item further left.
/// Reference: Ice, ControlItem.swift (MIT).
enum StatusItemDefaults {
    struct Key<Value> {
        let rawValue: String

        func stringKey(for autosaveName: String) -> String {
            "NSStatusItem \(rawValue) \(autosaveName)"
        }

        static var preferredPosition: Key<CGFloat> { .init(rawValue: "Preferred Position") }
        static var visible: Key<Bool> { .init(rawValue: "Visible") }
        // New macOS 26 key: item visibility in the Control-Center-managed menu bar.
        static var visibleCC: Key<Bool> { .init(rawValue: "VisibleCC") }
    }

    static subscript<Value>(key: Key<Value>, autosaveName: String) -> Value? {
        get {
            UserDefaults.standard.object(forKey: key.stringKey(for: autosaveName)) as? Value
        }
        set {
            let stringKey = key.stringKey(for: autosaveName)
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: stringKey)
            } else {
                UserDefaults.standard.removeObject(forKey: stringKey)
            }
        }
    }
}
