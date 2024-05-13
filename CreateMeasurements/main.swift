import Foundation

struct WeatherStation {
    let id: String
    let meanTemperature: Double

    init(_ id: String, _ meanTemperature: Double) {
        self.id = id
        self.meanTemperature = meanTemperature
    }

    func measurement() -> Double {
        let deviation = 10.0
        let randomMeasurement = Double.random(in: -deviation...deviation) + meanTemperature
        return (randomMeasurement * 10).rounded() / 10
    }
}

class MeasurementsGenerator {
    let measurementFilePath = FileManager.default.currentDirectoryPath + "/measurements.txt"

    func createMeasurements(numberOfRecords: Int) {
        let start = Date()

        FileManager.default.createFile(atPath: measurementFilePath, contents: nil, attributes: nil)

        if let fileHandle = FileHandle(forWritingAtPath: measurementFilePath) {
            defer {
                fileHandle.closeFile()
            }

            for i in 0..<numberOfRecords {
                if i > 0 && i % 50_000_000 == 0 {
                    let timeElapsed = -start.timeIntervalSinceNow
                    print("Wrote \(i) measurements in \(timeElapsed * 1000) ms")
                }
                let station = allStations.randomElement()!
                let line = "\(station.id);\(station.measurement())\n"
                if let data = line.data(using: .utf8) {
                    fileHandle.write(data)
                }
            }

            let totalElapsed = -start.timeIntervalSinceNow
            print("Created file with \(numberOfRecords) measurements in \(totalElapsed * 1000) ms")
            print("Output:", measurementFilePath)
        } else {
            print("Failed to open file for writing.")
        }
    }
}

if CommandLine.arguments.count > 1 {
    let countArg = CommandLine.arguments[1]

    if let count = Int(countArg) {
        let generator = MeasurementsGenerator()
        generator.createMeasurements(numberOfRecords: count)
        exit(EXIT_SUCCESS)
    } else {
        print("Please provide a value number.")
        exit(EXIT_FAILURE)
    }
} else {
    print("Please provide a count.")
    exit(EXIT_FAILURE)
}
