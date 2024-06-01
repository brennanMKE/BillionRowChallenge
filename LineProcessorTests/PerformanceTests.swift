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
        try await asyncMeasure(iterations: 5) {
            let mappedLines = try await Reader.readMappedFile(fileURL: fileURL, segmentCount: segmentCount)
            XCTAssertEqual(100_000, mappedLines.count)
        }
    }

    func testTenMillionLines() async throws {
        let segmentCount = 4
        let fileURL = try tenMillionLineFileURL

        try await asyncMeasure(iterations: 5) {
            let mappedLines = try await Reader.readMappedFile(fileURL: fileURL, segmentCount: segmentCount)
            XCTAssertEqual(10_000_000, mappedLines.count)
        }
    }

    func asyncMeasure(iterations: Int, operation: () async throws -> Void) async throws {
        guard iterations > 0 else {
            XCTFail()
            return
        }

        var totalTimeElapsed: TimeInterval = 0.0
        for iteration in 0..<iterations {
            let start = Date()
            try await operation()
            let timeElapsed = -start.timeIntervalSinceNow
            totalTimeElapsed += timeElapsed
            print("Iteration \(iteration + 1): \(timeElapsed * 1000) ms")
        }
        let averageTimeElapsed = totalTimeElapsed / Double(iterations)
        print("Averaged \(averageTimeElapsed * 1000) ms")
    }

}
