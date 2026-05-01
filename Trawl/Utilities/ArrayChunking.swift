extension Array {
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0, "chunk size must be greater than zero")
        if isEmpty { return [] }

        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)

        var startIndex = 0
        while startIndex < count {
            let endIndex = Swift.min(startIndex + size, count)
            chunks.append(Array(self[startIndex..<endIndex]))
            startIndex += size
        }

        return chunks
    }
}
