import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A log shared as a plain-text file.
///
/// The log screens used to hand `ShareLink` a bare `String`. The picker opened, but
/// what came out the other side was loose text rather than a file: Save to Files had
/// nothing to save, and Mail or AirDrop received a wall of pasted text instead of an
/// attachment. The file representation comes first, so any target that accepts files
/// gets a named `.txt`; the text stays behind it for targets that only take text.
nonisolated struct LogExportFile: Transferable, Sendable {
    let title: String
    let text: String
    var exportedAt: Date = .now

    /// "qBittorrent Log 2026-09-14 1407.txt" - sortable, and free of the `/` and `:`
    /// a localised date would put into a file name.
    var fileName: String {
        let stamp = exportedAt.formatted(
            .verbatim(
                "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
                locale: Locale(identifier: "en_US_POSIX"),
                timeZone: .current,
                calendar: Calendar(identifier: .gregorian)
            )
        )
        return "\(title) \(stamp).txt"
    }

    /// Each export gets its own directory, so two shares in the same minute cannot
    /// overwrite a file the first share is still handing to its target.
    func writeFile(in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = directory
            .appendingPathComponent("LogExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            SentTransferredFile(try export.writeFile())
        }
        ProxyRepresentation(exporting: \.text)
    }
}
