import XCTest
@testable import LineProcessor

final class LineProcessorTests: XCTestCase {
    enum Failure: Error {
        case resourceNotFound
        case failedToCreateMemoryMapFile
    }

    func testFindNewLine() async throws {
        let stringData = "1234567890\n1234567890\n1234567890\n1234567890\n"

        // TODO: read stringData as UnsafeMutablePointer<CChar> to 
    }

    func testMappingWith2Segments() async throws {
        let segmentCount = 2
        let bundle = Bundle(for: Self.self)
        guard let fileURL = bundle.url(forResource: "countries", withExtension: "txt") else {
            throw Failure.resourceNotFound
        }

        let lines = try readContents(fileURL: fileURL)
        let mappedLines = try await readMappedFile(fileURL: fileURL, segmentCount: segmentCount)

        XCTAssertFalse(lines.isEmpty, "The file should not be empty")
        XCTAssertEqual(lines.count, mappedLines.count)
        XCTAssertEqual(lines.first, mappedLines.first)
        XCTAssertEqual(lines.last, mappedLines.last)

        if lines.count == mappedLines.count {
            for index in 0..<lines.count {
                XCTAssertEqual(lines[index], mappedLines[index], "Index: \(index)")
            }
        }
    }

    func testMappingWith3Segments() async throws {
        let segmentCount = 3
        let bundle = Bundle(for: Self.self)
        guard let fileURL = bundle.url(forResource: "countries", withExtension: "txt") else {
            throw Failure.resourceNotFound
        }

        let lines = try readContents(fileURL: fileURL)
        let mappedLines = try await readMappedFile(fileURL: fileURL, segmentCount: segmentCount)

        XCTAssertFalse(lines.isEmpty, "The file should not be empty")
        XCTAssertEqual(lines.count, mappedLines.count)
        XCTAssertEqual(lines.first, mappedLines.first)
        XCTAssertEqual(lines.last, mappedLines.last)

        if lines.count == mappedLines.count {
            for index in 0..<lines.count {
                XCTAssertEqual(lines[index], mappedLines[index], "Index: \(index)")
            }
        }
    }

    func testMappingWith4Segments() async throws {
        let segmentCount = 4
        let bundle = Bundle(for: Self.self)
        guard let fileURL = bundle.url(forResource: "countries", withExtension: "txt") else {
            throw Failure.resourceNotFound
        }

        let lines = try readContents(fileURL: fileURL)
        let mappedLines = try await readMappedFile(fileURL: fileURL, segmentCount: segmentCount)

        XCTAssertFalse(lines.isEmpty, "The file should not be empty")
        XCTAssertEqual(lines.count, mappedLines.count)
        XCTAssertEqual(lines.first, mappedLines.first)
        XCTAssertEqual(lines.last, mappedLines.last)

        if lines.count == mappedLines.count {
            for index in 0..<lines.count {
                XCTAssertEqual(lines[index], mappedLines[index], "Index: \(index)")
            }
        }
    }

    func testMappingWith5Segments() async throws {
        let segmentCount = 5
        let bundle = Bundle(for: Self.self)
        guard let fileURL = bundle.url(forResource: "countries", withExtension: "txt") else {
            throw Failure.resourceNotFound
        }

        let lines = try readContents(fileURL: fileURL)
        let mappedLines = try await readMappedFile(fileURL: fileURL, segmentCount: segmentCount)

        XCTAssertFalse(lines.isEmpty, "The file should not be empty")
        XCTAssertEqual(lines.count, mappedLines.count)
        XCTAssertEqual(lines.first, mappedLines.first)
        XCTAssertEqual(lines.last, mappedLines.last)

        if lines.count == mappedLines.count {
            for index in 0..<lines.count {
                XCTAssertEqual(lines[index], mappedLines[index], "Index: \(index)")
            }
        }
    }

    // MARK: - Private -

    private func readContents(fileURL: URL) throws -> [String] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines
    }

    private func readMappedFile(fileURL: URL, segmentCount: Int) async throws -> [String] {
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
