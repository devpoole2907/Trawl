import Foundation

enum ByteFormatter {
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()

    /// Formats byte count to human-readable string (e.g., "1.5 GB")
    static func format(bytes: Int64) -> String {
        byteCountFormatter.string(fromByteCount: bytes)
    }

    /// Formats bytes-per-second to speed string (e.g., "2.3 MB/s")
    static func formatSpeed(bytesPerSecond: Int64) -> String {
        if bytesPerSecond <= 0 { return "0 B/s" }
        return "\(byteCountFormatter.string(fromByteCount: bytesPerSecond))/s"
    }

    /// Formats seconds to ETA string (e.g., "2h 15m", "∞" for stalled)
    static func formatETA(seconds: Int) -> String {
        if seconds <= 0 || seconds > 8_640_000 { return "∞" }

        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}
