import Foundation

enum Failure: Error {
    case resourceNotFound
    case failedToCreateMemoryMapFile
}
