import Foundation

/// Uygulamanın kalıcı ayarları (ses düzeyi, geçiş süresi). Testler diske yazmayan sürümünü kullanır.
protocol SettingsStore: AnyObject {
    func number(forKey key: String) -> Double?
    func setNumber(_ value: Double, forKey key: String)
}

extension UserDefaults: SettingsStore {
    func number(forKey key: String) -> Double? {
        (object(forKey: key) as? NSNumber)?.doubleValue
    }

    func setNumber(_ value: Double, forKey key: String) {
        set(value, forKey: key)
    }
}

final class InMemorySettings: SettingsStore {
    private var values: [String: Double] = [:]

    func number(forKey key: String) -> Double? {
        values[key]
    }

    func setNumber(_ value: Double, forKey key: String) {
        values[key] = value
    }
}
