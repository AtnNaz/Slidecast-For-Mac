import Foundation

nonisolated enum Timecode {
    /// `1:05` ya da bir saati aşınca `1:02:05`.
    static func string(_ seconds: Double) -> String {
        let (hours, minutes, secs) = components(seconds)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Her zaman `00:12:45` biçiminde.
    static func elapsed(_ seconds: Double) -> String {
        let (hours, minutes, secs) = components(seconds)
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    private static func components(_ seconds: Double) -> (Int, Int, Int) {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        return (total / 3600, (total % 3600) / 60, total % 60)
    }
}
