import AppSlicerML
import AppSlicerMetrics
import Foundation
import Testing
@testable import AppSlicerCollector

private func makeSnapshot(
    timestamp: TimeInterval = 0,
    pressureLevel: MemoryPressureLevel = .warning
) -> MemorySnapshot {
    MemorySnapshot(
        timestamp: Date(timeIntervalSince1970: timestamp),
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
            pressureLevel: pressureLevel
        )
    )
}

@Suite struct CollectorOptionsTests {
    @Test func usesDefaultsWithoutArguments() throws {
        let options = try CollectorOptions(arguments: [])
        #expect(options.interval == 2)
        #expect(options.top == 5)
        #expect(options.count == nil)
        #expect(options.modelFile == nil)
    }

    @Test func parsesAllOptions() throws {
        let options = try CollectorOptions(arguments: [
            "--interval", "0.5", "--top", "0", "--count", "3", "--model-file", "/tmp/m.model.json",
        ])
        #expect(options.interval == 0.5)
        #expect(options.top == 0)
        #expect(options.count == 3)
        #expect(options.modelFile == "/tmp/m.model.json")
    }

    @Test(arguments: [
        ["--interval"],
        ["--interval", "0.1"],
        ["--interval", "31"],
        ["--interval", "nan"],
        ["--interval", "inf"],
        ["--top", "-1"],
        ["--top", "many"],
        ["--count", "0"],
        ["--model-file"],
        ["--model-file", ""],
        ["--model-file", "--top"],
        ["--unknown"],
    ])
    func rejectsInvalidArguments(arguments: [String]) {
        #expect(throws: CollectorOptions.ParseError.self) {
            try CollectorOptions(arguments: arguments)
        }
    }

    @Test func maximumIntervalStaysWithinTheForecasterSampleGap() throws {
        let options = try CollectorOptions(arguments: ["--interval", "30"])
        #expect(options.interval < PressureForecaster.Configuration().maximumSampleGap)
    }

    @Test func recognizesHelp() {
        #expect(throws: CollectorOptions.ParseError.helpRequested) {
            try CollectorOptions(arguments: ["--help"])
        }
    }
}

@Suite struct ReportFormatterTests {
    @Test func formatsFullReport() {
        let report = ProcessMemoryReport(
            processes: [ProcessMemory(pid: 42, name: "Safari", footprintBytes: 536_870_912)],
            unreadableCount: 3
        )
        let output = ReportFormatter.format(
            time: "12:00:00",
            snapshot: makeSnapshot(),
            pageoutsPerSecond: 1.25,
            forecast: .ready(probability: 0.126, horizon: 600),
            report: report
        )
        #expect(output == """
        12:00:00  pressure: warning
          memory:  4.00 GB used of 8.00 GB (50%)
                   app 2.00 GB, wired 1.00 GB, compressed 1.00 GB
                   cached 1.00 GB, free 1.00 GB
          swap:    1.00 GB used of 4.00 GB, pageouts 1.2/s
          forecast: 13% chance of elevated pressure in the next 10 min
          top processes:
            0.50 GB  Safari (42)
          not readable without root: 3 processes
        """)
    }

    @Test func showsLearningProgressWithoutExceedingTheRequirement() {
        let output = ReportFormatter.format(
            time: "12:00:00",
            snapshot: makeSnapshot(),
            pageoutsPerSecond: nil,
            forecast: .learning(elevatedExamples: 3, calmExamples: 58, requiredExamples: 20),
            report: nil
        )
        #expect(output.contains("forecast: learning (3/20 elevated pressure examples, 20/20 calm examples)"))
        #expect(output.contains("pageouts -"))
        #expect(!output.contains("top processes"))
    }
}

@Suite struct MemorySampleMappingTests {
    @Test func convertsSnapshotFields() {
        let sample = MemorySample(snapshot: makeSnapshot(timestamp: 50), pageoutsPerSecond: 7)
        #expect(sample.timestamp == 50)
        #expect(sample.usedFraction == 0.5)
        #expect(sample.compressedFraction == 0.125)
        #expect(sample.swapUsedFraction == 0.125)
        #expect(sample.pageoutsPerSecond == 7)
        #expect(sample.isPressureElevated)
    }

    @Test func treatsMissingRateAsZeroAndNormalPressureAsCalm() {
        let sample = MemorySample(snapshot: makeSnapshot(pressureLevel: .normal), pageoutsPerSecond: nil)
        #expect(sample.pageoutsPerSecond == 0)
        #expect(!sample.isPressureElevated)
    }
}

@Suite struct LiveForecastSessionTests {
    private let directory: URL
    private let store: ForecasterStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSlicerOSCollectorTests-\(UUID().uuidString)", isDirectory: true)
        store = ForecasterStore(fileURL: directory.appendingPathComponent("test.model.json"))
    }

    private func makeSession(now: TimeInterval = 0) throws -> LiveForecastSession {
        try LiveForecastSession(
            store: store,
            saveInterval: 300,
            now: Date(timeIntervalSince1970: now)
        )
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: store.fileURL.path)
    }

    @Test func reportsLearningAndTrainsAfterTheHorizon() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var session = try makeSession()
        var status: ForecastStatus?
        for second in stride(from: 0, through: 660, by: 2) {
            status = session.observe(
                snapshot: makeSnapshot(timestamp: TimeInterval(second), pressureLevel: .normal),
                pageoutsPerSecond: 0
            )
        }
        #expect(session.forecaster.negativeExampleCount > 0)
        #expect(status == .learning(
            elevatedExamples: 0,
            calmExamples: session.forecaster.negativeExampleCount,
            requiredExamples: 20
        ))
    }

    @Test func savesOnlyWhenTheIntervalHasPassed() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var session = try makeSession()
        #expect(try !session.saveIfDue(now: Date(timeIntervalSince1970: 299)))
        #expect(!fileExists)
        #expect(try session.saveIfDue(now: Date(timeIntervalSince1970: 300)))
        #expect(fileExists)
        #expect(try !session.saveIfDue(now: Date(timeIntervalSince1970: 599)))
        #expect(try session.saveIfDue(now: Date(timeIntervalSince1970: 600)))
    }

    @Test func newSessionResumesFromTheSavedModel() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = try makeSession()
        for second in stride(from: 0, through: 660, by: 2) {
            _ = first.observe(
                snapshot: makeSnapshot(timestamp: TimeInterval(second), pressureLevel: .normal),
                pageoutsPerSecond: 0
            )
        }
        try first.save()

        let second = try makeSession()
        #expect(second.forecaster.negativeExampleCount == first.forecaster.negativeExampleCount)
        #expect(second.forecaster.negativeExampleCount > 0)
        #expect(second.forecaster.pendingExampleCount == first.forecaster.pendingExampleCount)
    }
}
