import Foundation

// 10 is the ASCII code for newline
private let newline = 10

/**
  Memory Mapped File which makes it possible to read the text file as memory.
 */
final class MemoryMappedFile {
    private let fileDescriptor: Int32
    private let fileSize: Int
    private let dataPointer: UnsafeMutablePointer<CChar>
    private let segmentSize: Int

    init?(path: String, numberOfSegments: Int) {
        fileDescriptor = open(path, O_RDONLY)
        guard fileDescriptor != -1 else { return nil }

        fileSize = Int(lseek(fileDescriptor, 0, SEEK_END))
        dataPointer = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, fileDescriptor, 0).assumingMemoryBound(to: CChar.self)
        close(fileDescriptor)

        segmentSize = fileSize / numberOfSegments
    }

    deinit {
        munmap(dataPointer, fileSize)
    }

    private func stringValue(prefix: String, from start: UnsafePointer<CChar>, to end: UnsafePointer<CChar>) -> String {
        let length = start.distance(to: end)
        let cString = String(cString: start, length: length) ?? "-"
        let formatted = (cString.prefix(20) + " ... " + cString.suffix(20)).replacingOccurrences(of: "\n", with: "\\n")
        return "\(prefix) \(formatted)"
    }

    /// Lines provides a sequence which can be iterated over asynchronously.
    /// - Parameter index: section index
    /// - Returns: async sequence to access each line
    func lines(forSegment index: Int) -> LineSequence {
        let startOffset = index * segmentSize
        let endOffset = (index == (fileSize / segmentSize) - 1) ? fileSize : startOffset + segmentSize
        let startPointer = dataPointer.advanced(by: startOffset)
        let endPointer = dataPointer.advanced(by: endOffset)
        let maxPointer = dataPointer.advanced(by: fileSize)
        let lastSegmentIndex = (fileSize / segmentSize) - 1

        let adjustedStart: UnsafePointer<CChar> = (index == 0) ? UnsafePointer(startPointer) : findNextNewline(from: UnsafePointer(startPointer), until: UnsafePointer(endPointer)).advanced(by: 1)

        let adjustedEnd: UnsafePointer<CChar> = (index == lastSegmentIndex) ? UnsafePointer(endPointer) : findNextNewline(from: endPointer, until: UnsafePointer(maxPointer))

        let string = stringValue(prefix: "===", from: adjustedStart, to: adjustedEnd)

        return LineSequence(start: adjustedStart, end: adjustedEnd)
    }

    func findNextNewline(from start: UnsafePointer<CChar>, until end: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
        var current = start
        while current < end && current.pointee != newline {
            current = current.advanced(by: 1)
        }
        return current
    }

    struct LineSequence: AsyncSequence {
        typealias Element = String

        let start: UnsafePointer<CChar>
        let end: UnsafePointer<CChar>

        init(start: UnsafePointer<CChar>, end: UnsafePointer<CChar>) {
            self.start = start
            self.end = end
        }

        func makeAsyncIterator() -> LineIterator {
            LineIterator(start: start, end: end)
        }

        struct LineIterator: AsyncIteratorProtocol {
            private var current: UnsafePointer<CChar>
            private let end: UnsafePointer<CChar>

            init(start: UnsafePointer<CChar>, end: UnsafePointer<CChar>) {
                self.current = start
                self.end = end
            }

            mutating func next() async -> String? {
                guard current < end else { return nil }

                let lineEnd = findNextNewline(from: current)
                let line = String(cString: current, length: lineEnd - current)
                current = lineEnd.advanced(by: 1)
                return line
            }

            private func findNextNewline(from pointer: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
                var current = pointer
                while current < end && current.pointee != newline {
                    current = current.advanced(by: 1)
                }
                return current
            }
        }
    }
}

extension String {
    init?(cString: UnsafePointer<CChar>, length: Int) {
        let buffer = UnsafeBufferPointer(start: cString, count: length)
        self.init(bytes: buffer.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}
