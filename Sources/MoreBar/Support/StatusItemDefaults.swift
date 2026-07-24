import Foundation

/// Доступ к системным UserDefaults-ключам NSStatusItem
/// ("NSStatusItem Preferred Position <autosaveName>" и др.).
/// Позиция измеряется в поинтах от правого края секции статус-итемов:
/// 0 — правее всех сторонних, большее значение — левее.
/// Референс: Ice, ControlItem.swift (MIT).
enum StatusItemDefaults {
    struct Key<Value> {
        let rawValue: String

        func stringKey(for autosaveName: String) -> String {
            "NSStatusItem \(rawValue) \(autosaveName)"
        }

        static var preferredPosition: Key<CGFloat> { .init(rawValue: "Preferred Position") }
        static var visible: Key<Bool> { .init(rawValue: "Visible") }
        // Новый ключ macOS 26: видимость итема в системном меню-баре, управляемом Control Center.
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
