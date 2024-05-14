import Foundation

let groupingStrategy = GroupStrategy.single
let groupSize = GroupSize.custom(2)

enum GroupStrategy {
    case single
    case groupedLinesWithTaskGroup
    case groupedLinesWithoutTaskGroup

    var useGroupedLines: Bool {
        switch self {
        case .single:
            false
        case .groupedLinesWithTaskGroup, .groupedLinesWithoutTaskGroup:
            true
        }
    }

    var useTaskGroup: Bool {
        switch self {
        case .single, .groupedLinesWithoutTaskGroup:
            false
        case .groupedLinesWithTaskGroup:
            true
        }
    }
}

enum GroupSize {
    case activeProcessorCount
    case doubleActiveProcessorCount
    case custom(Int)

    var count: Int {
        switch self {
        case .activeProcessorCount:
            ProcessInfo.processInfo.activeProcessorCount
        case .doubleActiveProcessorCount:
            ProcessInfo.processInfo.activeProcessorCount * 2
        case .custom(let count):
            count
        }
    }
}


@globalActor actor ProcessorActor: GlobalActor {
    static let shared = ProcessorActor()
}

let measurementFilePath = FileManager.default.currentDirectoryPath + "/measurements.txt"
let outputFilePath = FileManager.default.currentDirectoryPath + "/output.txt"

class Processor {

    actor Tally {
        var min: Double
        var max: Double
        var total: Double
        var count: Int

        init(temperature: Double) {
            self.min = temperature
            self.max = temperature
            self.total = temperature
            self.count = 1
        }

        func add(temperature: Double) {
            if temperature < min {
                min = temperature
            } else if temperature > max {
                max = temperature
            }
            total += temperature
            count += 1
        }

        func output(id: String) -> String {
            let mean = (total / Double(count) * 10).rounded() / 10
            return "\(id),\(min),\(mean),\(max)\n"
        }
    }

    let start = Date()
    let fileHandle: FileHandle
    let bufferLength: Int
    var buffer: Data
    let delimiter = "\n".data(using: .utf8)!

    var totalElapsed: Double {
        -start.timeIntervalSinceNow
    }

    @ProcessorActor var tallies: [String: Tally] = [:]

    init?(inputFilePath: String, bufferLength: Int = 4096) {
        guard FileManager.default.fileExists(atPath: inputFilePath) else {
            print("Measurements not found")
            exit(EXIT_FAILURE)
        }

        guard let handle = FileHandle(forReadingAtPath: inputFilePath) else {
            return nil
        }
        self.fileHandle = handle
        self.bufferLength = bufferLength
        self.buffer = Data(capacity: bufferLength)
    }

    deinit {
        fileHandle.closeFile()
    }

    @ProcessorActor func add(id: String, temperature: Double) async {
        if let tally = tallies[id] {
            await tally.add(temperature: temperature)
        } else {
            tallies[id] = Tally(temperature: temperature)
        }
    }

    @discardableResult
    func loadBuffer() -> Bool {
        let tempData = fileHandle.readData(ofLength: bufferLength)
        if !tempData.isEmpty {
            buffer.append(tempData)
            return true
        } else {
            return false
        }
    }

    func nextLine() -> String? {
        while true {
            // attempts to read to newline
            if let range = buffer.range(of: delimiter) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                if let line = String(data: lineData, encoding: .utf8) {
                    return line
                } else {
                    fatalError()
                }
            }
            // tries to load more data into buffer
            if !loadBuffer() {
                assert(buffer.isEmpty)
                return nil
            }
        }
    }

    func nextLines() -> [String]? {
        var batch: [String] = []
        for _ in 0..<groupSize.count {
            if let range = buffer.range(of: delimiter) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                if let line = String(data: lineData, encoding: .utf8) {
                    batch.append(line)
                }
            } else if !loadBuffer() {
                break
            }
        }
        return !batch.isEmpty ? batch : nil
    }

    func process() async {
        loadBuffer()

        if groupingStrategy.useGroupedLines {
            while let lines = nextLines() {
                if groupingStrategy.useTaskGroup {
                    await processLines(lines: lines)
                } else {
                    for line in lines {
                        await processLine(line: line)
                    }
                }
            }
        } else {
            while let line = nextLine() {
                await processLine(line: line)
            }
        }

        await writeOutput()

        print("Processed \(await tallies.count) results in \(totalElapsed * 1000) ms")
        exit(EXIT_SUCCESS)
    }

    func processLine(line: String) async {
        let parts = line.components(separatedBy: ";")
        let id = parts[0]
        if let temperature = Double(parts[1]) {
            await add(id: id, temperature: temperature)
        }
    }

    nonisolated func processLines(lines: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for line in lines {
                group.addTask { //@ProcessorActor in
                    let parts = line.components(separatedBy: ";")
                    let id = parts[0]
                    if let temperature = Double(parts[1]) {
                        await self.add(id: id, temperature: temperature)
                    }
                }
            }

            await group.waitForAll()
        }
    }

    @ProcessorActor func writeOutput() async {
        FileManager.default.createFile(atPath: outputFilePath, contents: nil, attributes: nil)

        if let fileHandle = FileHandle(forWritingAtPath: outputFilePath) {
            defer {
                fileHandle.closeFile()
            }

            for id in tallies.keys.sorted() {
                if let tally = tallies[id] {
                    let output = await tally.output(id: id)
                    if let data = output.data(using: .utf8) {
                        fileHandle.write(data)
                    }
                }
            }
        }
    }
}

Task {
    let inputFilePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : measurementFilePath
    await Processor(inputFilePath: inputFilePath)?.process()
}

dispatchMain()
