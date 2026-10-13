import SwiftUI

extension Color {
    /// "Yayında" göstergelerinin kırmızısı. Sistem rengi değil; seçili liste satırında beyaza dönmesin diye.
    static let live = Color(red: 1.0, green: 0.27, blue: 0.23)

    /// Aynı arka plan müziğini paylaşan slaytları işaretleyen renk; dosya adına göre sabittir.
    static func musicGroup(for fileName: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.35, green: 0.78, blue: 0.98),
            Color(red: 0.69, green: 0.55, blue: 1.00),
            Color(red: 0.40, green: 0.85, blue: 0.55),
            Color(red: 1.00, green: 0.80, blue: 0.30),
            Color(red: 1.00, green: 0.55, blue: 0.75),
            Color(red: 0.45, green: 0.90, blue: 0.85),
        ]
        let sum = fileName.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 9973 }
        return palette[sum % palette.count]
    }
}
