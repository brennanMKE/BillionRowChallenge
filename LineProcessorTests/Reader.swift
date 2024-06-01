import Foundation
@testable import LineProcessor

struct Reader {

    static func readContents(fileURL: URL) throws -> [String] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines
    }

    static func readMappedFile(fileURL: URL, segmentCount: Int) async throws -> [String] {
        guard let mmf = MemoryMappedFile(path: fileURL.path, numberOfSegments: segmentCount) else {
            throw Failure.failedToCreateMemoryMapFile
        }
        var mappedLines: [String] = []
        for index in 0..<segmentCount  {
            let lines = mmf.lines(forSegment: index)
            for await line in lines {
                mappedLines.append(line)
            }
        }

        return mappedLines
    }

}

