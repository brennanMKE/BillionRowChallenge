import XCTest
@testable import LineProcessor

final class PerformanceTests: XCTestCase {
    var oneHundredThousandLineFileURL: URL {
        get throws {
            guard let fileURL = Bundle(for: Self.self).url(forResource: "100_000", withExtension: "txt") else {
                throw Failure.resourceNotFound
            }

            return fileURL
        }
    }

    var tenMillionLineFileURL: URL {
        get throws {
            guard let fileURL = Bundle(for: Self.self).url(forResource: "10_000_000", withExtension: "txt") else {
                throw Failure.resourceNotFound
            }

            return fileURL
        }
    }

    func testOneHundredThousandLines() async throws {
        let segmentCount = 4
        let fileURL = try oneHundredThousandLineFileURL
        let start = Date()
        let mappedLines = try await Reader.readMappedFile(fileURL: fileURL, segmentCount: segmentCount)
        XCTAssertEqual(100_000, mappedLines.count)
        let totalElapsed = -start.timeIntervalSinceNow
        print("Read in \(mappedLines.count) in \(totalElapsed * 1000) ms")
    }

    func testTenMillionLines() async throws {
        let segmentCount = 4
        let fileURL = try tenMillionLineFileURL

        let start = Date()
        let mappedLines = try await Reader.readMappedFile(fileURL: fileURL, segmentCount: segmentCount)
        XCTAssertEqual(10_000_000, mappedLines.count)
        let totalElapsed = -start.timeIntervalSinceNow
        print("Read in \(mappedLines.count) in \(totalElapsed * 1000) ms")
    }

}
