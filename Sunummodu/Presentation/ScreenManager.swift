import AppKit
import Observation

enum OutputTarget: Hashable {
    /// Sunucu penceresinin bulunmadığı ekran; harici ekran yoksa pencere.
    case automatic
    case display(CGDirectDisplayID)
    /// Tam ekran yerine normal bir önizleme penceresi.
    case window
}

/// Bağlı ekranları izler ve çıkışın hangi ekrana verileceğini belirler.
@Observable
final class ScreenManager {
    struct Display: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        let isBuiltin: Bool
    }

    private(set) var displays: [Display] = []
    /// Ekran yansıtma açıkken sistem tek ekran bildirir; ayrı çıkış verilemez.
    private(set) var isMirroring = false
    var target: OutputTarget = .automatic {
        didSet {
            if target != oldValue { onChange?() }
        }
    }

    /// Ekran takılıp çıkarıldığında ya da hedef değiştiğinde çağrılır.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onChange?()
            }
        }
    }

    /// Çıkışın tam ekran açılacağı ekran; nil ise çıkış pencere olarak açılır.
    func resolveOutputScreen(avoiding presenterScreen: NSScreen?) -> NSScreen? {
        let screens = NSScreen.screens
        switch target {
        case .window:
            return nil
        case .display(let id):
            return screens.first { $0.displayID == id }
        case .automatic:
            guard screens.count > 1 else { return nil }
            let candidates = screens.filter { $0 != presenterScreen }
            return candidates.first { !Self.isBuiltin($0) } ?? candidates.first
        }
    }

    func name(of screen: NSScreen?) -> String {
        screen?.localizedName ?? "Pencere"
    }

    private func refresh() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return Display(id: id, name: screen.localizedName, isBuiltin: Self.isBuiltin(screen))
        }
        isMirroring = CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0
        if case .display(let id) = target, !displays.contains(where: { $0.id == id }) {
            target = .automatic
        }
    }

    private static func isBuiltin(_ screen: NSScreen) -> Bool {
        guard let id = screen.displayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
