import AppSlicerMetrics
import Foundation
import Testing
@testable import AppSlicerCollector

@Suite struct CollectorOptionsTests {
    @Test func usesDefaultsWithoutArguments() throws {
        let options = try CollectorOptions(arguments: [])
        #expect(options.interval == 2)
        #expect(options.top == 5)
        #expect(options.count == nil)
    }

    @Test func parsesAllOptions() throws {
        let options = try CollectorOptions(arguments: ["--interval", "0.5", "--top", "0", "--count", "3"])
        #expect(options.interval == 0.5)
        #expect(options.top == 0)
        #expect(options.count == 3)
    }

    @Test(arguments: [
        ["--interval"],
        ["--interval", "0.1"],
        ["--interval", "nan"],
        ["--interval", "inf"],
        ["--top", "-1"],
        ["--top", "many"],
        ["--count", "0"],
        ["--unknown"],
    ])
    func rejectsInvalidArguments(arguments: [String]) {
        #expect(throws: CollectorOptions.ParseError.self) {
            try CollectorOptions(arguments: arguments)
        }
    }

    @Test func recognizesHelp() {
        #expect(throws: CollectorOptions.ParseError.helpRequested) {
            try CollectorOptions(arguments: ["--help"])
        }
    }
}

@Suite struct ReportFormatterTests {
    private let snapshot = MemorySnapshot(
        timestamp: Date(timeIntervalSince1970: 0),
        counters: MemoryCounters(
            pageSize: 4_096,
            physicalMemoryBytes: 8_589_934_592,
            internalPages: 524_288,
            externalPages: 262_144,
            purgeablePages: 0,
            wiredPages: 262_144,
            compressorPages: 262_144,
            freePages: 262_144,
            pageouts: 0,
            swapTotalBytes: 4_294_967_296,
            swapUsedBytes: 1_073_741_824,
            pressureLevel: .warning
        )
    )

    @Test func formatsFullReport() {
        let report = ProcessMemoryReport(
            processes: [ProcessMemory(pid: 42, name: "Safari", footprintBytes: 536_870_912)],
            unreadableCount: 3
        )
        let output = ReportFormatter.format(
            time: "12:00:00",
            snapshot: snapshot,
            pageoutsPerSecond: 1.25,
            report: report
        )
        #expect(output == """
        12:00:00  pressure: warning
          memory:  4.00 GB used of 8.00 GB (50%)
                   app 2.00 GB, wired 1.00 GB, compressed 1.00 GB
                   cached 1.00 GB, free 1.00 GB
          swap:    1.00 GB used of 4.00 GB, pageouts 1.2/s
          top processes:
            0.50 GB  Safari (42)
          not readable without root: 3 processes
        """)
    }

    @Test func showsMissingRateOnFirstReadingAndOmitsProcesses() {
        let output = ReportFormatter.format(
            time: "12:00:00",
            snapshot: snapshot,
            pageoutsPerSecond: nil,
            report: nil
        )
        #expect(output.contains("pageouts -"))
        #expect(!output.contains("top processes"))
    }
}
