import Foundation

enum MultipartFormData {
    nonisolated static func sanitizedToken(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "'")
    }
}

extension Data {
    nonisolated mutating func appendMultipart(boundary: String, name: String, filename: String, data: Data) {
        let safeName = MultipartFormData.sanitizedToken(name)
        let safeFilename = MultipartFormData.sanitizedToken(filename)
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(safeName)\"; filename=\"\(safeFilename)\"\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }

    nonisolated mutating func appendMultipartField(boundary: String, name: String, value: String) {
        let safeName = MultipartFormData.sanitizedToken(name)
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(safeName)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }
}
