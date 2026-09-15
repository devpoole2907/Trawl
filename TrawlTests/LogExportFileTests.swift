import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Trawl

@Suite("Log export file")
struct LogExportFileTests {
    private static let exportedAt: Date = {
        let components = DateComponents(year: 2026, month: 9, day: 14, hour: 14, minute: 7)
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    @Test("Log screens share one naming contract")
    func serviceLogPresentation() {
        #expect(ServiceLogPresentation.qbittorrent.navigationTitle == "Logs")
        #expect(ServiceLogPresentation.seerr.navigationTitle == "Logs")
        #expect(ServiceLogPresentation.jellyfin.navigationTitle == "Logs")
        #expect(ServiceLogPresentation.qbittorrent.exportTitle == "qBittorrent Logs")
        #expect(ServiceLogPresentation.seerr.exportTitle == "Seerr Logs")
        #expect(ServiceLogPresentation.jellyfin.exportTitle == "Jellyfin Activity Log")
    }

    @Test("Names the file after the log and the minute it was exported")
    func fileName() {
        let export = LogExportFile(title: "qBittorrent Log", text: "", exportedAt: Self.exportedAt)
        #expect(export.fileName == "qBittorrent Log 2026-09-14 1407.txt")
    }

    @Test("Writes the exported text, byte for byte, to a file with that name")
    func writesTheText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "Seerr Logs\nExported 14/09/2026\n\n[14/09/2026] [INFO] Jellyfin Sync: Recently Added Scan Complete"

        let url = try LogExportFile(title: "Seerr Logs", text: text, exportedAt: Self.exportedAt).writeFile(in: directory)

        #expect(url.lastPathComponent == "Seerr Logs 2026-09-14 1407.txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test("Two exports in the same minute do not overwrite each other")
    func sameMinuteExportsKeepSeparateFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try LogExportFile(title: "Arr Events", text: "first", exportedAt: Self.exportedAt).writeFile(in: directory)
        let second = try LogExportFile(title: "Arr Events", text: "second", exportedAt: Self.exportedAt).writeFile(in: directory)

        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
    }

    /// The regression this type exists for: a bare `String` exported only text, so
    /// share targets never received a file. Plain text must be the first type offered.
    @Test("Offers a plain-text file ahead of any text fallback")
    func exportsPlainTextFirst() {
        #expect(LogExportFile.exportedContentTypes().first == .plainText)
    }
}
