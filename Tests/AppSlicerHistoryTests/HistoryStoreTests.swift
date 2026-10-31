import AppSlicerMetrics
import Foundation
import SQLite3
import Testing
@testable import AppSlicerHistory

private let day: TimeInterval = 86_400

private func makeSnapshot(
    at timestamp: TimeInterval,
    usedPages: UInt64 = 100,
    swapUsedBytes: UInt64 = 1_000,
    pressureLevel: MemoryPressureLevel = .normal
) -> MemorySnapshot {
    MemorySnapshot(
        timestamp: Date(timeIntervalSince1970: timestamp),
        counters: MemoryCounters(
            pageSize: 10,
            physicalMemoryBytes: 100_000,
            internalPages: usedPages,
            externalPages: 20,
            purgeablePages: 0,
            wiredPages: 0,
            compressorPages: 5,
            freePages: 30,
            pageouts: 0,
            swapTotalBytes: 8_000,
            swapUsedBytes: swapUsedBytes,
            pressureLevel: pressureLevel
        )
    )
}

@Suite struct HistoryStoreTests {
    private let directory: URL
    private let fileURL: URL
    private let distantPast = Date(timeIntervalSince1970: 0)
    private let distantFuture = Date(timeIntervalSince1970: 100_000_000)

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSlicerOSHistoryTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("nested/history.sqlite")
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func storesAndReturnsAllReadingFields() throws {
        defer { cleanUp() }
        let store = try HistoryStore(fileURL: fileURL)
        let snapshot = makeSnapshot(at: 1_000.5, pressureLevel: .critical)
        try store.record(snapshot, pageoutsPerSecond: 2.5)

        let reading = try #require(store.readings(from: distantPast, through: distantFuture).first)
        #expect(reading.timestamp == snapshot.timestamp)
        #expect(reading.physicalMemoryBytes == 100_000)
        #expect(reading.usedBytes == snapshot.usedBytes)
        #expect(reading.appBytes == snapshot.appBytes)
        #expect(reading.wiredBytes == snapshot.wiredBytes)
        #expect(reading.compressedBytes == snapshot.compressedBytes)
        #expect(reading.cachedBytes == snapshot.cachedBytes)
        #expect(reading.freeBytes == snapshot.freeBytes)
        #expect(reading.swapTotalBytes == 8_000)
        #expect(reading.swapUsedBytes == 1_000)
        #expect(reading.pageoutsPerSecond == 2.5)
        #expect(reading.pressureLevel == .critical)
    }

    @Test func keepsMissingPageoutRateAsNil() throws {
        defer { cleanUp() }
        let store = try HistoryStore(fileURL: fileURL)
        try store.record(makeSnapshot(at: 1), pageoutsPerSecond: nil)
        let reading = try #require(store.readings(from: distantPast, through: distantFuture).first)
        #expect(reading.pageoutsPerSecond == nil)
    }

    @Test func returnsOnlyTheRequestedPeriodInOrder() throws {
        defer { cleanUp() }
        let store = try HistoryStore(fileURL: fileURL)
        for timestamp in [30.0, 10, 20, 40] {
            try store.record(makeSnapshot(at: timestamp), pageoutsPerSecond: nil)
        }
        let readings = try store.readings(
            from: Date(timeIntervalSince1970: 20),
            through: Date(timeIntervalSince1970: 30)
        )
        #expect(readings.map(\.timestamp.timeIntervalSince1970) == [20, 30])
    }

    @Test func historySurvivesReopening() throws {
        defer { cleanUp() }
        do {
            let store = try HistoryStore(fileURL: fileURL)
            try store.record(makeSnapshot(at: 1), pageoutsPerSecond: 1)
        }
        let reopened = try HistoryStore(fileURL: fileURL)
        try reopened.record(makeSnapshot(at: 2), pageoutsPerSecond: 1)
        #expect(try reopened.readings(from: distantPast, through: distantFuture).count == 2)
    }

    @Test func summarizesExpiredReadingsByMinute() throws {
        defer { cleanUp() }
        let store = try HistoryStore(fileURL: fileURL)
        let minuteStart = 600.0
        try store.record(
            makeSnapshot(at: minuteStart, usedPages: 100, swapUsedBytes: 1_000),
            pageoutsPerSecond: nil
        )
        try store.record(
            makeSnapshot(at: minuteStart + 10, usedPages: 200, swapUsedBytes: 3_000, pressureLevel: .warning),
            pageoutsPerSecond: 4
        )
        try store.record(
            makeSnapshot(at: minuteStart + 20, usedPages: 300, swapUsedBytes: 2_000, pressureLevel: .critical),
            pageoutsPerSecond: 8
        )
        try store.applyRetention(now: Date(timeIntervalSince1970: minuteStart + 8 * day))

        #expect(try store.readings(from: distantPast, through: distantFuture).isEmpty)
        let summary = try #require(store.minuteSummaries(from: distantPast, through: distantFuture).first)
        #expect(summary.minuteStart.timeIntervalSince1970 == minuteStart)
        #expect(summary.sampleCount == 3)
        #expect(summary.averageUsedBytes == 2_050)
        #expect(summary.maximumUsedBytes == 3_050)
        #expect(summary.averageCompressedBytes == 50)
        #expect(summary.maximumCompressedBytes == 50)
        #expect(summary.averageSwapUsedBytes == 2_000)
        #expect(summary.maximumSwapUsedBytes == 3_000)
        #expect(summary.averagePageoutsPerSecond == 6)
        #expect(summary.maximumPageoutsPerSecond == 8)
        #expect(summary.worstPressureLevel == .critical)
        #expect(summary.elevatedSampleCount == 2)
    }

    @Test func keepsReadingsInsideTheRetentionPeriod() throws {
        defer { cleanUp() }
        let store = try HistoryStore(fileURL: fileURL)
        let now = 100 * day
        try store.record(makeSnapshot(at: now - 6 * day), pageoutsPerSecond: nil)
        try store.record(makeSnapshot(at: now - 8 * day), pageoutsPerSecond: nil)
        try store.applyRetention(now: Date(timeIntervalSince1970: now))

        #expect(try store.readings(from: distantPast, through: distantFuture).count == 1)
        #expect(try store.minuteSummaries(from: distantPast, through: distantFuture).count == 1)
    }

    @Test func neverSummarizesAPartialMinute() throws {
        defer { cleanUp() }
        let store = try HistoryStore(fileURL: fileURL)
        let now = 100 * day + 30
        let cutoff = now - 7 * day
        try store.record(makeSnapshot(at: cutoff - 10), pageoutsPerSecond: nil)
        try store.record(makeSnapshot(at: cutoff + 10), pageoutsPerSecond: nil)
        try store.applyRetention(now: Date(timeIntervalSince1970: now))

        #expect(try store.readings(from: distantPast, through: distantFuture).count == 2)
        #expect(try store.minuteSummaries(from: distantPast, through: distantFuture).isEmpty)
    }

    @Test func deletesExpiredSummaries() throws {
        defer { cleanUp() }
        let store = try HistoryStore(fileURL: fileURL)
        let start = 100 * day
        try store.record(makeSnapshot(at: start), pageoutsPerSecond: nil)
        try store.applyRetention(now: Date(timeIntervalSince1970: start + 89 * day))
        #expect(try store.minuteSummaries(from: distantPast, through: distantFuture).count == 1)

        try store.applyRetention(now: Date(timeIntervalSince1970: start + 91 * day))
        #expect(try store.minuteSummaries(from: distantPast, through: distantFuture).isEmpty)
    }

    @Test func applyingRetentionTwiceDoesNotChangeSummaries() throws {
        defer { cleanUp() }
        let store = try HistoryStore(fileURL: fileURL)
        try store.record(makeSnapshot(at: 600), pageoutsPerSecond: nil)
        let now = Date(timeIntervalSince1970: 600 + 8 * day)
        try store.applyRetention(now: now)
        let first = try store.minuteSummaries(from: distantPast, through: distantFuture)
        try store.applyRetention(now: now)
        #expect(try store.minuteSummaries(from: distantPast, through: distantFuture) == first)
    }

    @Test func aLateReadingDoesNotOverwriteAnExistingSummary() throws {
        defer { cleanUp() }
        let store = try HistoryStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 600 + 8 * day)
        try store.record(makeSnapshot(at: 600), pageoutsPerSecond: nil)
        try store.applyRetention(now: now)
        try store.record(makeSnapshot(at: 610), pageoutsPerSecond: nil)
        try store.applyRetention(now: now)

        let summaries = try store.minuteSummaries(from: distantPast, through: distantFuture)
        #expect(summaries.map(\.sampleCount) == [1])
        #expect(try store.readings(from: distantPast, through: distantFuture).isEmpty)
    }

    @Test func databaseIsPrivateToTheUser() throws {
        defer { cleanUp() }
        let store = try HistoryStore(fileURL: fileURL)
        try store.record(makeSnapshot(at: 1), pageoutsPerSecond: nil)
        let files = try FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(files.count >= 1)
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600, "\(file.lastPathComponent)")
        }
    }

    @Test func refusesACorruptedFileWithoutReplacingIt() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = Data(String(repeating: "not a database ", count: 200).utf8)
        try contents.write(to: fileURL)

        #expect(throws: HistoryError.self) { try HistoryStore(fileURL: fileURL) }
        #expect(try Data(contentsOf: fileURL) == contents)
    }

    @Test func refusesADatabaseFromANewerVersion() throws {
        defer { cleanUp() }
        do {
            _ = try HistoryStore(fileURL: fileURL)
        }
        var handle: OpaquePointer?
        #expect(sqlite3_open(fileURL.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "PRAGMA user_version = 999", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        #expect(throws: HistoryError.unsupportedSchema(version: 999)) {
            try HistoryStore(fileURL: fileURL)
        }
    }
}
