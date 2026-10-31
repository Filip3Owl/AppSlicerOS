import Foundation
import Testing
@testable import AppSlicerMetrics

private func makeCounters(
    internalPages: UInt64 = 1_000,
    purgeablePages: UInt64 = 100,
    pageouts: UInt64 = 0,
    swapTotalBytes: UInt64 = 8_000,
    pressureLevel: MemoryPressureLevel = .normal
) -> MemoryCounters {
    MemoryCounters(
        pageSize: 4,
        physicalMemoryBytes: 16_000,
        internalPages: internalPages,
        externalPages: 300,
        purgeablePages: purgeablePages,
        wiredPages: 200,
        compressorPages: 500,
        freePages: 50,
        pageouts: pageouts,
        swapTotalBytes: swapTotalBytes,
        swapUsedBytes: 2_000,
        pressureLevel: pressureLevel
    )
}

@Suite struct MemorySnapshotTests {
    @Test func groupsMemoryLikeActivityMonitor() {
        let snapshot = MemorySnapshot(timestamp: Date(), counters: makeCounters())
        #expect(snapshot.appBytes == 3_600)
        #expect(snapshot.wiredBytes == 800)
        #expect(snapshot.compressedBytes == 2_000)
        #expect(snapshot.usedBytes == 6_400)
        #expect(snapshot.cachedBytes == 1_600)
        #expect(snapshot.freeBytes == 200)
        #expect(snapshot.usedFraction == 0.4)
        #expect(snapshot.compressedFraction == 0.125)
        #expect(snapshot.swapUsedFraction == 0.25)
    }

    @Test func doesNotUnderflowWhenPurgeableExceedsInternal() {
        let counters = makeCounters(internalPages: 10, purgeablePages: 20)
        #expect(MemorySnapshot(timestamp: Date(), counters: counters).appBytes == 0)
    }

    @Test func treatsMissingSwapAsZero() {
        let counters = makeCounters(swapTotalBytes: 0)
        #expect(MemorySnapshot(timestamp: Date(), counters: counters).swapUsedFraction == 0)
    }

    @Test func calculatesPageoutRate() {
        let start = Date(timeIntervalSince1970: 100)
        let first = MemorySnapshot(timestamp: start, counters: makeCounters(pageouts: 10))
        let second = MemorySnapshot(timestamp: start.addingTimeInterval(4), counters: makeCounters(pageouts: 30))
        #expect(second.pageoutsPerSecond(since: first) == 5)
    }

    @Test func handlesCounterResetAndZeroElapsedTime() {
        let start = Date(timeIntervalSince1970: 100)
        let first = MemorySnapshot(timestamp: start, counters: makeCounters(pageouts: 30))
        let reset = MemorySnapshot(timestamp: start.addingTimeInterval(4), counters: makeCounters(pageouts: 10))
        let sameTime = MemorySnapshot(timestamp: start, counters: makeCounters(pageouts: 40))
        #expect(reset.pageoutsPerSecond(since: first) == 0)
        #expect(sameTime.pageoutsPerSecond(since: first) == nil)
    }

    @Test func onlyNormalPressureIsNotElevated() {
        #expect(!MemoryPressureLevel.normal.isElevated)
        #expect(MemoryPressureLevel.warning.isElevated)
        #expect(MemoryPressureLevel.critical.isElevated)
    }
}

@Suite struct ProcessMemoryReaderTests {
    private let small = ProcessMemory(pid: 1, name: "small", footprintBytes: 10)
    private let large = ProcessMemory(pid: 2, name: "large", footprintBytes: 30)
    private let medium = ProcessMemory(pid: 3, name: "medium", footprintBytes: 20)

    @Test func selectsLargestProcessesInOrder() {
        #expect(ProcessMemoryReader.largest([small, large, medium], limit: 2) == [large, medium])
    }

    @Test func handlesLimitsOutsideTheList() {
        #expect(ProcessMemoryReader.largest([small], limit: 5) == [small])
        #expect(ProcessMemoryReader.largest([small], limit: 0).isEmpty)
        #expect(ProcessMemoryReader.largest([small], limit: -1).isEmpty)
    }
}

/// These tests read the real system, which is why they check invariants and not values.
@Suite struct LiveReadingTests {
    @Test func readsPlausibleSystemMetrics() throws {
        let snapshot = try SystemMemoryReader().read()
        #expect(snapshot.counters.physicalMemoryBytes > 0)
        #expect(snapshot.counters.pageSize > 0)
        #expect(snapshot.usedBytes > 0)
        #expect(snapshot.usedBytes <= snapshot.counters.physicalMemoryBytes)
        #expect(snapshot.counters.swapUsedBytes <= snapshot.counters.swapTotalBytes)
    }

    @Test func findsTheCurrentProcess() throws {
        let report = try ProcessMemoryReader().readTopProcesses(limit: Int.max)
        let current = report.processes.first { $0.pid == getpid() }
        #expect(try #require(current).footprintBytes > 0)
    }
}
