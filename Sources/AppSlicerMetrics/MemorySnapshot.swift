import Foundation

/// The system's memory pressure, using the kernel's `kern.memorystatus_vm_pressure_level`
/// values.
public enum MemoryPressureLevel: Int32, Codable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var isElevated: Bool { self != .normal }
}

/// Raw values read from the kernel.
public struct MemoryCounters: Equatable, Sendable {
    public var pageSize: UInt64
    public var physicalMemoryBytes: UInt64
    public var internalPages: UInt64
    public var externalPages: UInt64
    public var purgeablePages: UInt64
    public var wiredPages: UInt64
    public var compressorPages: UInt64
    public var freePages: UInt64
    /// Cumulative since boot.
    public var pageouts: UInt64
    public var swapTotalBytes: UInt64
    public var swapUsedBytes: UInt64
    public var pressureLevel: MemoryPressureLevel

    public init(
        pageSize: UInt64,
        physicalMemoryBytes: UInt64,
        internalPages: UInt64,
        externalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        freePages: UInt64,
        pageouts: UInt64,
        swapTotalBytes: UInt64,
        swapUsedBytes: UInt64,
        pressureLevel: MemoryPressureLevel
    ) {
        self.pageSize = pageSize
        self.physicalMemoryBytes = physicalMemoryBytes
        self.internalPages = internalPages
        self.externalPages = externalPages
        self.purgeablePages = purgeablePages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
        self.freePages = freePages
        self.pageouts = pageouts
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressureLevel = pressureLevel
    }
}

/// One system-wide memory reading, grouped the way Activity Monitor presents it.
public struct MemorySnapshot: Equatable, Sendable {
    public let timestamp: Date
    public let counters: MemoryCounters

    public init(timestamp: Date, counters: MemoryCounters) {
        self.timestamp = timestamp
        self.counters = counters
    }

    public var appBytes: UInt64 {
        bytes(counters.internalPages - min(counters.purgeablePages, counters.internalPages))
    }

    public var wiredBytes: UInt64 { bytes(counters.wiredPages) }
    public var compressedBytes: UInt64 { bytes(counters.compressorPages) }
    public var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }
    public var cachedBytes: UInt64 { bytes(counters.externalPages + counters.purgeablePages) }
    public var freeBytes: UInt64 { bytes(counters.freePages) }

    public var usedFraction: Double { fraction(usedBytes, of: counters.physicalMemoryBytes) }

    public var compressedFraction: Double {
        fraction(compressedBytes, of: counters.physicalMemoryBytes)
    }

    /// Relative to physical memory because macOS resizes the swap capacity as it runs,
    /// which would change a capacity-based fraction without any change in swap usage.
    public var swapUsedFraction: Double {
        fraction(counters.swapUsedBytes, of: counters.physicalMemoryBytes)
    }

    /// Returns `nil` when no time has passed. A counter that went backward counts as zero.
    public func pageoutsPerSecond(since previous: MemorySnapshot) -> Double? {
        let elapsed = timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return nil }
        guard counters.pageouts >= previous.counters.pageouts else { return 0 }
        return Double(counters.pageouts - previous.counters.pageouts) / elapsed
    }

    private func bytes(_ pages: UInt64) -> UInt64 {
        pages * counters.pageSize
    }

    private func fraction(_ value: UInt64, of total: UInt64) -> Double {
        total > 0 ? Double(value) / Double(total) : 0
    }
}
