import XCTest
@testable import LineProcessor

final class LineProcessorTests: XCTestCase {
    var countriesFileURL: URL {
        get throws {
            guard let fileURL = Bundle(for: Self.self).url(forResource: "countries", withExtension: "txt") else {
                throw Failure.resourceNotFound
            }

            return fileURL
        }
    }

    func testMappingWith2Segments() async throws {
        let segmentCount = 2
        let fileURL = try countriesFileURL
        let lines = try Reader.readContents(fileURL: fileURL)
        let mappedLines = try await Reader.readMappedFile(fileURL: fileURL, segmentCount: segmentCount)

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
        let fileURL = try countriesFileURL
        let lines = try Reader.readContents(fileURL: fileURL)
        let mappedLines = try await Reader.readMappedFile(fileURL: fileURL, segmentCount: segmentCount)

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
        let fileURL = try countriesFileURL
        let lines = try Reader.readContents(fileURL: fileURL)
        let mappedLines = try await Reader.readMappedFile(fileURL: fileURL, segmentCount: segmentCount)

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
        let fileURL = try countriesFileURL
        let lines = try Reader.readContents(fileURL: fileURL)
        let mappedLines = try await Reader.readMappedFile(fileURL: fileURL, segmentCount: segmentCount)

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

}
