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
        #expect(snapshot.swapUsedFraction == 0.125)
    }

    @Test func doesNotUnderflowWhenPurgeableExceedsInternal() {
        let counters = makeCounters(internalPages: 10, purgeablePages: 20)
        #expect(MemorySnapshot(timestamp: Date(), counters: counters).appBytes == 0)
    }

    @Test func swapFractionIgnoresChangesInSwapCapacity() {
        let date = Date()
        let smaller = MemorySnapshot(timestamp: date, counters: makeCounters(swapTotalBytes: 3_000))
        let larger = MemorySnapshot(timestamp: date, counters: makeCounters(swapTotalBytes: 4_000))
        #expect(smaller.swapUsedFraction == larger.swapUsedFraction)
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

@Suite struct AppGroupingTests {
    @Test func usesTheOutermostAppBundle() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Helper (Renderer).app/Contents/MacOS/Helper"
        #expect(ProcessMemoryReader.appName(forExecutablePath: helper) == "Google Chrome")
    }

    @Test(arguments: [
        ("/Applications/Slack.app/Contents/MacOS/Slack", "Slack"),
        ("/Applications/Utilities/Tool.app/Contents/MacOS/Tool", "Tool"),
        ("/System/Applications/Mail.app/Contents/MacOS/Mail", "Mail"),
        ("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "Terminal"),
        ("/Users/someone/Applications/Mine.app/Contents/MacOS/Mine", "Mine"),
    ])
    func recognizesAppsInStandardFolders(path: String, name: String) {
        #expect(ProcessMemoryReader.appName(forExecutablePath: path) == name)
    }

    @Test(arguments: [
        "/usr/bin/ssh",
        "/Users/someone/.local/share/tool/versions/2.1.316",
        "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight",
        "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect",
        "/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService",
    ])
    func treatsServicesAndToolsAsNotApps(path: String) {
        #expect(ProcessMemoryReader.appName(forExecutablePath: path) == nil)
    }

    @Test func treatsAnUnknownPathAsNotAnApp() {
        #expect(ProcessMemoryReader.appName(forExecutablePath: nil) == nil)
    }

    @Test func combinesProcessesAndSortsByFootprint() {
        let apps = ProcessMemoryReader.grouped(
            [(name: "Chrome", footprintBytes: 10), (name: "Mail", footprintBytes: 25), (name: "Chrome", footprintBytes: 20)],
            limit: 5
        )
        #expect(apps == [
            AppMemory(name: "Chrome", footprintBytes: 30, processCount: 2),
            AppMemory(name: "Mail", footprintBytes: 25, processCount: 1),
        ])
    }

    @Test func respectsTheLimit() {
        let processes = [(name: "A", footprintBytes: UInt64(1)), (name: "B", footprintBytes: UInt64(2))]
        #expect(ProcessMemoryReader.grouped(processes, limit: 1).map(\.name) == ["B"])
        #expect(ProcessMemoryReader.grouped(processes, limit: -1).isEmpty)
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

    @Test func readsAppsSortedByFootprint() throws {
        let report = try ProcessMemoryReader().readApps(limit: Int.max)
        let apps = report.apps
        #expect(apps.map(\.footprintBytes) == apps.map(\.footprintBytes).sorted(by: >))
        // The test process itself is a tool, so it counts toward the other processes.
        #expect(report.otherProcessCount > 0)
        #expect(report.otherFootprintBytes > 0)
    }

    @Test func findsTheCurrentProcess() throws {
        let report = try ProcessMemoryReader().readTopProcesses(limit: Int.max)
        let current = report.processes.first { $0.pid == getpid() }
        #expect(try #require(current).footprintBytes > 0)
    }
}
