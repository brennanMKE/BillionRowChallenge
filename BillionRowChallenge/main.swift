import Foundation

class Processor {
    let measurementFilePath = "./10_000_000.txt"
    let outputFilePath = "./brc-output.txt"

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
            min = Swift.min(min, temperature)
            max = Swift.max(max, temperature)
            total += temperature
            count += 1
        }

        func output(city: String) -> String {
            let mean = (total / Double(count) * 10).rounded() / 10
            return "\(city),\(min),\(mean),\(max)\n"
        }
    }

    let fileHandle: FileHandle
    let bufferLength: Int
    var buffer: Data
    let delimiter = "\n".data(using: .utf8)!

    var tallies: [String: Tally] = [:]

    init?(bufferLength: Int = 4096) {
        let inputFilePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : measurementFilePath

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

    func nextLine() -> String? {
        while true {
            if let range = buffer.range(of: delimiter) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                return String(data: lineData, encoding: .utf8)
            }

            let tempData = fileHandle.readData(ofLength: bufferLength)
            if tempData.isEmpty {
                return nil
            }
            buffer.append(tempData)
        }
    }

    func add(id: String, temperature: Double) async {
        if let tally = tallies[id] {
            await tally.add(temperature: temperature)
        } else {
            tallies[id] = Tally(temperature: temperature)
        }
    }

    func process() async {
        let start = Date()

        while let line = nextLine() {
            let parts = line.components(separatedBy: ";")
            assert(parts.count == 2)
            let id = parts[0]
            if let temperature = Double(parts[1]) {
                await add(id: id, temperature: temperature)
            }
        }

        await writeOutput()

        let totalElapsed = -start.timeIntervalSinceNow
        print("Processed with \(tallies.count) results in \(totalElapsed * 1000) ms")

        exit(EXIT_SUCCESS)
    }

    func writeOutput() async {
        FileManager.default.createFile(atPath: outputFilePath, contents: nil, attributes: nil)

        if let fileHandle = FileHandle(forWritingAtPath: outputFilePath) {
            defer {
                fileHandle.closeFile()
            }

            for city in tallies.keys.sorted() {
                if let tally = tallies[city] {
                    let output = await tally.output(city: city)
                    if let data = output.data(using: .utf8) {
                        fileHandle.write(data)
                    }
                }
            }

            print("Output:", outputFilePath)
        }
    }
}

Task {
    await Processor()?.process()
}

dispatchMain()
