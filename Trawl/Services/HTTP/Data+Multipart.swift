import Foundation

extension Data {
    nonisolated mutating func appendMultipart(boundary: String, name: String, filename: String, data: Data) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }

    nonisolated mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }
}
