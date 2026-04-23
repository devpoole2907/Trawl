import Testing
import Foundation
@testable import Trawl

@Suite("ByteFormatter Tests")
struct ByteFormatterTests {
    @Test("Format Bytes", arguments: [
        (Int64(0), "Zero KB"),
        (Int64(1024), "1 KB"),
        (Int64(1048576), "1 MB"),
        (Int64(1073741824), "1 GB")
    ])
    func formatBytes(bytes: Int64, expected: String) {
        #expect(ByteFormatter.format(bytes: bytes) == expected)
    }

    @Test("Format Speed", arguments: [
        (Int64(0), "0 B/s"),
        (Int64(-100), "0 B/s"),
        (Int64(1024), "1 KB/s"),
        (Int64(1536), "2 KB/s")
    ])
    func formatSpeed(bytesPerSecond: Int64, expected: String) {
        #expect(ByteFormatter.formatSpeed(bytesPerSecond: bytesPerSecond) == expected)
    }

    @Test("Format ETA", arguments: [
        (0, "∞"),
        (-10, "∞"),
        (8_640_001, "∞"),
        (45, "45s"),
        (125, "2m 5s"),
        (3720, "1h 2m"),
        (90000, "1d 1h")
    ])
    func formatETA(seconds: Int, expected: String) {
        #expect(ByteFormatter.formatETA(seconds: seconds) == expected)
    }
}
