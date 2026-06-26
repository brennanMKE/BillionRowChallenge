import Foundation

// Billion Row Challenge — optimized Swift port.
//
// Strategy (mirrors the fast Java entries):
//   1. mmap the file and split it into one segment per core, aligned to newlines.
//   2. Each segment is processed on its own thread with NO shared mutable state —
//      results accumulate into a per-thread open-addressing hash table.
//   3. The hot loop never allocates: station names are hashed and compared as raw
//      bytes (pointers into the mmap), and temperatures are parsed as scaled Ints.
//   4. The ~N per-thread tables are merged once at the end, then sorted and written.

private let newline: UInt8 = 10      // '\n'
private let semicolon: UInt8 = 59    // ';'
private let minus: UInt8 = 45        // '-'
private let dot: UInt8 = 46          // '.'
private let zero: UInt8 = 48         // '0'

// MARK: - Per-thread statistics table (open addressing, byte-keyed)

/// Open-addressing hash table keyed on raw station-name bytes. Values are kept as
/// scaled integers (tenths of a degree) so the hot loop does only integer math.
private final class StatsTable {
    let capacity: Int
    let mask: Int

    // Parallel arrays, one slot each. `count == 0` marks an empty slot.
    let hashes: UnsafeMutablePointer<UInt64>
    let namePtrs: UnsafeMutablePointer<UnsafePointer<UInt8>?>
    let nameLens: UnsafeMutablePointer<Int32>
    let mins: UnsafeMutablePointer<Int32>
    let maxs: UnsafeMutablePointer<Int32>
    let sums: UnsafeMutablePointer<Int64>
    let counts: UnsafeMutablePointer<Int64>

    init(capacity: Int) {
        self.capacity = capacity
        self.mask = capacity - 1
        hashes = .allocate(capacity: capacity); hashes.initialize(repeating: 0, count: capacity)
        namePtrs = .allocate(capacity: capacity); namePtrs.initialize(repeating: nil, count: capacity)
        nameLens = .allocate(capacity: capacity); nameLens.initialize(repeating: 0, count: capacity)
        mins = .allocate(capacity: capacity); mins.initialize(repeating: 0, count: capacity)
        maxs = .allocate(capacity: capacity); maxs.initialize(repeating: 0, count: capacity)
        sums = .allocate(capacity: capacity); sums.initialize(repeating: 0, count: capacity)
        counts = .allocate(capacity: capacity); counts.initialize(repeating: 0, count: capacity)
    }

    deinit {
        hashes.deallocate(); namePtrs.deallocate(); nameLens.deallocate()
        mins.deallocate(); maxs.deallocate(); sums.deallocate(); counts.deallocate()
    }

    /// Find the slot for `name`, inserting an empty one if needed. Returns its index.
    @inline(__always)
    func slot(hash: UInt64, name: UnsafePointer<UInt8>, len: Int32) -> Int {
        var index = Int(hash & UInt64(mask))
        while true {
            if counts[index] == 0 {
                // Empty slot — claim it.
                hashes[index] = hash
                namePtrs[index] = name
                nameLens[index] = len
                return index
            }
            if hashes[index] == hash && nameLens[index] == len &&
                memcmp(namePtrs[index], name, Int(len)) == 0 {
                return index
            }
            index = (index + 1) & mask
        }
    }

    @inline(__always)
    func add(hash: UInt64, name: UnsafePointer<UInt8>, len: Int32, value: Int32) {
        let i = slot(hash: hash, name: name, len: len)
        if counts[i] == 0 {
            mins[i] = value; maxs[i] = value; sums[i] = Int64(value); counts[i] = 1
        } else {
            if value < mins[i] { mins[i] = value }
            if value > maxs[i] { maxs[i] = value }
            sums[i] += Int64(value)
            counts[i] += 1
        }
    }
}

// MARK: - Hot loop

/// FNV-1a over the name, scanning until ';'. Returns the byte after ';'.
@inline(__always)
private func processSegment(_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int, into table: StatsTable) {
    var p = start
    while p < end {
        // Scan the station name up to ';', hashing as we go.
        let nameStart = base + p
        var hash: UInt64 = 0xcbf29ce484222325
        var c = base[p]
        while c != semicolon {
            hash = (hash ^ UInt64(c)) &* 0x100000001b3
            p += 1
            c = base[p]
        }
        let nameLen = Int32(p - (nameStart - base))
        p += 1 // skip ';'

        // Parse the temperature as tenths: -?\d{1,2}\.\d
        var negative = false
        if base[p] == minus { negative = true; p += 1 }
        var value = Int32(base[p] - zero); p += 1
        if base[p] != dot { value = value * 10 + Int32(base[p] - zero); p += 1 }
        p += 1 // skip '.'
        value = value * 10 + Int32(base[p] - zero); p += 1
        if negative { value = -value }
        p += 1 // skip '\n'

        table.add(hash: hash, name: nameStart, len: nameLen, value: value)
    }
}

// MARK: - Driver

private func run() {
    let start = Date()

    let inputFilePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./10_000_000.txt"
    let outputFilePath = "./brc-output.txt"

    let fd = open(inputFilePath, O_RDONLY)
    guard fd != -1 else {
        print("Measurements not found")
        exit(EXIT_FAILURE)
    }
    let fileSize = Int(lseek(fd, 0, SEEK_END))
    guard fileSize > 0 else { print("Empty file"); exit(EXIT_FAILURE) }
    guard let raw = mmap(nil, fileSize, PROT_READ, MAP_PRIVATE, fd, 0), raw != MAP_FAILED else {
        print("Failed to map file"); exit(EXIT_FAILURE)
    }
    close(fd)
    madvise(raw, fileSize, MADV_SEQUENTIAL)
    let base = raw.assumingMemoryBound(to: UInt8.self)
    defer { munmap(raw, fileSize) }

    // Split into newline-aligned segments, one per core.
    let segments = max(1, ProcessInfo.processInfo.activeProcessorCount)
    var bounds = [Int](repeating: 0, count: segments + 1)
    bounds[segments] = fileSize
    for i in 1..<segments {
        var pos = fileSize / segments * i
        while pos < fileSize && base[pos] != newline { pos += 1 }
        if pos < fileSize { pos += 1 } // start just past the newline
        bounds[i] = pos
    }

    // Per-segment tables (sized generously; BRC has at most ~10k unique names).
    let tableCapacity = 1 << 14
    let tables = (0..<segments).map { _ in StatsTable(capacity: tableCapacity) }

    DispatchQueue.concurrentPerform(iterations: segments) { i in
        let s = bounds[i], e = bounds[i + 1]
        if s < e { processSegment(base, s, e, into: tables[i]) }
    }

    // Merge every per-segment table into one dictionary keyed by name String.
    // This runs only ~(unique stations × segments) times, so its cost is trivial.
    struct Stat { var min: Int32; var max: Int32; var sum: Int64; var count: Int64 }
    var merged: [String: Stat] = [:]
    merged.reserveCapacity(1024)
    for table in tables {
        for i in 0..<table.capacity where table.counts[i] != 0 {
            let name = String(decoding: UnsafeBufferPointer(start: table.namePtrs[i], count: Int(table.nameLens[i])), as: UTF8.self)
            if var s = merged[name] {
                if table.mins[i] < s.min { s.min = table.mins[i] }
                if table.maxs[i] > s.max { s.max = table.maxs[i] }
                s.sum += table.sums[i]; s.count += table.counts[i]
                merged[name] = s
            } else {
                merged[name] = Stat(min: table.mins[i], max: table.maxs[i], sum: table.sums[i], count: table.counts[i])
            }
        }
    }

    // Format and write output, sorted by station name.
    var out = ""
    out.reserveCapacity(merged.count * 24)
    for name in merged.keys.sorted() {
        let s = merged[name]!
        let mean = (Double(s.sum) / Double(s.count)).rounded() / 10  // round to tenths
        out += "\(name),\(Double(s.min) / 10),\(mean),\(Double(s.max) / 10)\n"
    }
    FileManager.default.createFile(atPath: outputFilePath, contents: Data(out.utf8), attributes: nil)

    let totalElapsed = -start.timeIntervalSinceNow
    print("Output:", outputFilePath)
    print("Processed with \(merged.count) results in \(totalElapsed * 1000) ms")
}

run()
