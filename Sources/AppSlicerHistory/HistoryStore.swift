import AppSlicerMetrics
import Foundation

/// One stored reading at full resolution.
public struct HistoryReading: Equatable, Sendable {
    public let timestamp: Date
    public let physicalMemoryBytes: UInt64
    public let usedBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedBytes: UInt64
    public let freeBytes: UInt64
    public let swapTotalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pageoutsPerSecond: Double?
    public let pressureLevel: MemoryPressureLevel
}

/// One minute of readings, kept after the full-resolution readings expire.
public struct MinuteSummary: Equatable, Sendable {
    public let minuteStart: Date
    public let sampleCount: Int
    public let averageUsedBytes: Double
    public let maximumUsedBytes: UInt64
    public let averageCompressedBytes: Double
    public let maximumCompressedBytes: UInt64
    public let averageSwapUsedBytes: Double
    public let maximumSwapUsedBytes: UInt64
    public let averagePageoutsPerSecond: Double?
    public let maximumPageoutsPerSecond: Double?
    public let worstPressureLevel: MemoryPressureLevel
    public let elevatedSampleCount: Int
}

/// Readings and summaries combined into one period of a chart. Composition values are `nil`
/// only for summaries written before the history stored them.
public struct HistoryBucket: Equatable, Sendable {
    public let start: Date
    public let sampleCount: Int
    public let averageUsedBytes: Double
    public let maximumUsedBytes: UInt64
    public let averageAppBytes: Double?
    public let averageWiredBytes: Double?
    public let averageCompressedBytes: Double
    public let averageCachedBytes: Double?
    public let averageFreeBytes: Double?
    public let averageSwapUsedBytes: Double
    public let maximumSwapUsedBytes: UInt64
    public let worstPressureLevel: MemoryPressureLevel
    public let elevatedSampleCount: Int

    public init(
        start: Date,
        sampleCount: Int,
        averageUsedBytes: Double,
        maximumUsedBytes: UInt64,
        averageAppBytes: Double?,
        averageWiredBytes: Double?,
        averageCompressedBytes: Double,
        averageCachedBytes: Double?,
        averageFreeBytes: Double?,
        averageSwapUsedBytes: Double,
        maximumSwapUsedBytes: UInt64,
        worstPressureLevel: MemoryPressureLevel,
        elevatedSampleCount: Int
    ) {
        self.start = start
        self.sampleCount = sampleCount
        self.averageUsedBytes = averageUsedBytes
        self.maximumUsedBytes = maximumUsedBytes
        self.averageAppBytes = averageAppBytes
        self.averageWiredBytes = averageWiredBytes
        self.averageCompressedBytes = averageCompressedBytes
        self.averageCachedBytes = averageCachedBytes
        self.averageFreeBytes = averageFreeBytes
        self.averageSwapUsedBytes = averageSwapUsedBytes
        self.maximumSwapUsedBytes = maximumSwapUsedBytes
        self.worstPressureLevel = worstPressureLevel
        self.elevatedSampleCount = elevatedSampleCount
    }
}

public struct RetentionPolicy: Equatable, Sendable {
    public var readingRetention: TimeInterval
    public var summaryRetention: TimeInterval

    public init(
        readingRetention: TimeInterval = 7 * 86_400,
        summaryRetention: TimeInterval = 90 * 86_400
    ) {
        self.readingRetention = readingRetention
        self.summaryRetention = summaryRetention
    }
}

/// Stores system-wide memory history in a local SQLite database. It holds no per-process
/// data, because the model does not need it and app names reveal usage habits.
public final class HistoryStore {
    private static let schemaVersion = 2

    private let database: SQLiteConnection
    private let insertReading: SQLiteStatement
    private let selectReadings: SQLiteStatement
    private let selectSummaries: SQLiteStatement
    private let selectBuckets: SQLiteStatement
    private let summarizeReadings: SQLiteStatement
    private let deleteReadings: SQLiteStatement
    private let deleteSummaries: SQLiteStatement

    public let fileURL: URL

    /// `~/Library/Application Support/AppSlicerOS/history.sqlite`
    public static func defaultFileURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AppSlicerOS", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    /// Unlike the model, history cannot be relearned, so an unreadable or newer database
    /// throws instead of being replaced.
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try Self.createPrivateFileIfNeeded(at: fileURL)
        database = try SQLiteConnection(fileURL: fileURL)
        try Self.prepareSchema(database)

        insertReading = try database.prepare("""
            INSERT OR REPLACE INTO readings (
                timestamp, physical_bytes, used_bytes, app_bytes, wired_bytes, compressed_bytes,
                cached_bytes, free_bytes, swap_total_bytes, swap_used_bytes, pageouts_per_second,
                pressure_level
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        selectReadings = try database.prepare("""
            SELECT timestamp, physical_bytes, used_bytes, app_bytes, wired_bytes, compressed_bytes,
                cached_bytes, free_bytes, swap_total_bytes, swap_used_bytes, pageouts_per_second,
                pressure_level
            FROM readings WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp
            """)
        selectSummaries = try database.prepare("""
            SELECT minute, sample_count, average_used_bytes, maximum_used_bytes,
                average_compressed_bytes, maximum_compressed_bytes, average_swap_used_bytes,
                maximum_swap_used_bytes, average_pageouts_per_second, maximum_pageouts_per_second,
                worst_pressure_level, elevated_sample_count
            FROM minute_summaries WHERE minute >= ? AND minute <= ? ORDER BY minute
            """)
        // Readings and summaries never overlap, because retention deletes each reading in
        // the same transaction that summarizes it. Each row counts by its sample count.
        selectBuckets = try database.prepare("""
            SELECT CAST(time / ?1 AS INTEGER) * ?1,
                SUM(samples),
                SUM(used * samples) / SUM(samples),
                MAX(peak_used),
                SUM(app * samples) / SUM(CASE WHEN app IS NULL THEN 0 ELSE samples END),
                SUM(wired * samples) / SUM(CASE WHEN wired IS NULL THEN 0 ELSE samples END),
                SUM(compressed * samples) / SUM(samples),
                SUM(cached * samples) / SUM(CASE WHEN cached IS NULL THEN 0 ELSE samples END),
                SUM(free * samples) / SUM(CASE WHEN free IS NULL THEN 0 ELSE samples END),
                SUM(swap * samples) / SUM(samples),
                MAX(peak_swap),
                MAX(pressure),
                SUM(elevated)
            FROM (
                SELECT timestamp AS time, 1 AS samples, used_bytes AS used, used_bytes AS peak_used,
                    app_bytes AS app, wired_bytes AS wired, compressed_bytes AS compressed,
                    cached_bytes AS cached, free_bytes AS free, swap_used_bytes AS swap,
                    swap_used_bytes AS peak_swap, pressure_level AS pressure,
                    pressure_level > 1 AS elevated
                FROM readings WHERE timestamp >= ?2 AND timestamp <= ?3
                UNION ALL
                SELECT minute * 60, sample_count, average_used_bytes, maximum_used_bytes,
                    average_app_bytes, average_wired_bytes, average_compressed_bytes,
                    average_cached_bytes, average_free_bytes, average_swap_used_bytes,
                    maximum_swap_used_bytes, worst_pressure_level, elevated_sample_count
                FROM minute_summaries WHERE minute >= ?4 AND minute <= ?5
            )
            GROUP BY CAST(time / ?1 AS INTEGER)
            ORDER BY 1
            """)
        // A minute already summarized keeps its summary. This only happens if the clock
        // moves back, and a few lost readings are better than a corrupted average.
        summarizeReadings = try database.prepare("""
            INSERT INTO minute_summaries (
                minute, sample_count, average_used_bytes, maximum_used_bytes,
                average_compressed_bytes, maximum_compressed_bytes, average_swap_used_bytes,
                maximum_swap_used_bytes, average_pageouts_per_second, maximum_pageouts_per_second,
                worst_pressure_level, elevated_sample_count, average_app_bytes,
                average_wired_bytes, average_cached_bytes, average_free_bytes
            )
            SELECT CAST(timestamp / 60 AS INTEGER), COUNT(*), AVG(used_bytes), MAX(used_bytes),
                AVG(compressed_bytes), MAX(compressed_bytes), AVG(swap_used_bytes), MAX(swap_used_bytes),
                AVG(pageouts_per_second), MAX(pageouts_per_second), MAX(pressure_level),
                SUM(pressure_level > 1), AVG(app_bytes), AVG(wired_bytes), AVG(cached_bytes),
                AVG(free_bytes)
            FROM readings WHERE timestamp < ?
            GROUP BY CAST(timestamp / 60 AS INTEGER)
            ON CONFLICT (minute) DO NOTHING
            """)
        deleteReadings = try database.prepare("DELETE FROM readings WHERE timestamp < ?")
        deleteSummaries = try database.prepare("DELETE FROM minute_summaries WHERE minute < ?")
    }

    public func record(_ snapshot: MemorySnapshot, pageoutsPerSecond: Double?) throws {
        let statement = insertReading
        statement.bind(snapshot.timestamp.timeIntervalSince1970, at: 1)
        statement.bind(snapshot.counters.physicalMemoryBytes, at: 2)
        statement.bind(snapshot.usedBytes, at: 3)
        statement.bind(snapshot.appBytes, at: 4)
        statement.bind(snapshot.wiredBytes, at: 5)
        statement.bind(snapshot.compressedBytes, at: 6)
        statement.bind(snapshot.cachedBytes, at: 7)
        statement.bind(snapshot.freeBytes, at: 8)
        statement.bind(snapshot.counters.swapTotalBytes, at: 9)
        statement.bind(snapshot.counters.swapUsedBytes, at: 10)
        statement.bind(pageoutsPerSecond, at: 11)
        statement.bind(UInt64(snapshot.counters.pressureLevel.rawValue), at: 12)
        try statement.run()
    }

    /// Summarizes expired readings by minute, then deletes data older than the policy allows.
    public func applyRetention(_ policy: RetentionPolicy = RetentionPolicy(), now: Date) throws {
        let readingCutoff = Self.minute(containing: now.addingTimeInterval(-policy.readingRetention))
        let summaryCutoff = Self.minute(containing: now.addingTimeInterval(-policy.summaryRetention))

        try database.transaction {
            summarizeReadings.bind(readingCutoff * 60, at: 1)
            try summarizeReadings.run()
            deleteReadings.bind(readingCutoff * 60, at: 1)
            try deleteReadings.run()
            deleteSummaries.bind(summaryCutoff, at: 1)
            try deleteSummaries.run()
        }
        try database.execute("PRAGMA incremental_vacuum")
    }

    public func readings(from start: Date, through end: Date) throws -> [HistoryReading] {
        selectReadings.bind(start.timeIntervalSince1970, at: 1)
        selectReadings.bind(end.timeIntervalSince1970, at: 2)
        return try selectReadings.rows { row in
            HistoryReading(
                timestamp: Date(timeIntervalSince1970: row.double(at: 0)),
                physicalMemoryBytes: row.unsignedInt(at: 1),
                usedBytes: row.unsignedInt(at: 2),
                appBytes: row.unsignedInt(at: 3),
                wiredBytes: row.unsignedInt(at: 4),
                compressedBytes: row.unsignedInt(at: 5),
                cachedBytes: row.unsignedInt(at: 6),
                freeBytes: row.unsignedInt(at: 7),
                swapTotalBytes: row.unsignedInt(at: 8),
                swapUsedBytes: row.unsignedInt(at: 9),
                pageoutsPerSecond: row.optionalDouble(at: 10),
                pressureLevel: try Self.pressureLevel(row.int64(at: 11))
            )
        }
    }

    public func minuteSummaries(from start: Date, through end: Date) throws -> [MinuteSummary] {
        selectSummaries.bind(Self.minute(containing: start), at: 1)
        selectSummaries.bind(Self.minute(containing: end), at: 2)
        return try selectSummaries.rows { row in
            MinuteSummary(
                minuteStart: Date(timeIntervalSince1970: row.double(at: 0) * 60),
                sampleCount: Int(row.int64(at: 1)),
                averageUsedBytes: row.double(at: 2),
                maximumUsedBytes: row.unsignedInt(at: 3),
                averageCompressedBytes: row.double(at: 4),
                maximumCompressedBytes: row.unsignedInt(at: 5),
                averageSwapUsedBytes: row.double(at: 6),
                maximumSwapUsedBytes: row.unsignedInt(at: 7),
                averagePageoutsPerSecond: row.optionalDouble(at: 8),
                maximumPageoutsPerSecond: row.optionalDouble(at: 9),
                worstPressureLevel: try Self.pressureLevel(row.int64(at: 10)),
                elevatedSampleCount: Int(row.int64(at: 11))
            )
        }
    }

    /// Combines readings and minute summaries into periods of the given length.
    public func buckets(
        from start: Date,
        through end: Date,
        duration: TimeInterval
    ) throws -> [HistoryBucket] {
        selectBuckets.bind(duration, at: 1)
        selectBuckets.bind(start.timeIntervalSince1970, at: 2)
        selectBuckets.bind(end.timeIntervalSince1970, at: 3)
        selectBuckets.bind(Self.minute(containing: start), at: 4)
        selectBuckets.bind(Self.minute(containing: end), at: 5)
        return try selectBuckets.rows { row in
            HistoryBucket(
                start: Date(timeIntervalSince1970: row.double(at: 0)),
                sampleCount: Int(row.int64(at: 1)),
                averageUsedBytes: row.double(at: 2),
                maximumUsedBytes: row.unsignedInt(at: 3),
                averageAppBytes: row.optionalDouble(at: 4),
                averageWiredBytes: row.optionalDouble(at: 5),
                averageCompressedBytes: row.double(at: 6),
                averageCachedBytes: row.optionalDouble(at: 7),
                averageFreeBytes: row.optionalDouble(at: 8),
                averageSwapUsedBytes: row.double(at: 9),
                maximumSwapUsedBytes: row.unsignedInt(at: 10),
                worstPressureLevel: try Self.pressureLevel(row.int64(at: 11)),
                elevatedSampleCount: Int(row.int64(at: 12))
            )
        }
    }

    private static func minute(containing date: Date) -> Double {
        (date.timeIntervalSince1970 / 60).rounded(.down)
    }

    private static func pressureLevel(_ value: Int64) throws -> MemoryPressureLevel {
        let rawValue = Int32(clamping: value)
        guard let level = MemoryPressureLevel(rawValue: rawValue) else {
            throw HistoryError.invalidPressureLevel(rawValue)
        }
        return level
    }

    /// Created up front because SQLite would otherwise create a world-readable file. Its
    /// temporary journal files inherit these permissions.
    private static func createPrivateFileIfNeeded(at url: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func prepareSchema(_ database: SQLiteConnection) throws {
        let version = try database.prepare("PRAGMA user_version").rows { Int($0.int64(at: 0)) }.first ?? 0
        guard version <= schemaVersion else {
            throw HistoryError.unsupportedSchema(version: version)
        }

        if version == 0 {
            // Must be set before the first table exists to take effect.
            try database.execute("PRAGMA auto_vacuum = INCREMENTAL")
        }
        // Lets each reading be written without forcing the disk to sync.
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")

        if version == 0 {
            try createFirstSchema(database)
        }
        if version < 2 {
            try database.transaction {
                try database.execute("""
                    ALTER TABLE minute_summaries ADD COLUMN average_app_bytes REAL;
                    ALTER TABLE minute_summaries ADD COLUMN average_wired_bytes REAL;
                    ALTER TABLE minute_summaries ADD COLUMN average_cached_bytes REAL;
                    ALTER TABLE minute_summaries ADD COLUMN average_free_bytes REAL;
                    PRAGMA user_version = 2;
                    """)
            }
        }
    }

    private static func createFirstSchema(_ database: SQLiteConnection) throws {
        try database.transaction {
            try database.execute("""
                CREATE TABLE readings (
                    timestamp REAL PRIMARY KEY,
                    physical_bytes INTEGER NOT NULL,
                    used_bytes INTEGER NOT NULL,
                    app_bytes INTEGER NOT NULL,
                    wired_bytes INTEGER NOT NULL,
                    compressed_bytes INTEGER NOT NULL,
                    cached_bytes INTEGER NOT NULL,
                    free_bytes INTEGER NOT NULL,
                    swap_total_bytes INTEGER NOT NULL,
                    swap_used_bytes INTEGER NOT NULL,
                    pageouts_per_second REAL,
                    pressure_level INTEGER NOT NULL
                ) WITHOUT ROWID;

                CREATE TABLE minute_summaries (
                    minute INTEGER PRIMARY KEY,
                    sample_count INTEGER NOT NULL,
                    average_used_bytes REAL NOT NULL,
                    maximum_used_bytes INTEGER NOT NULL,
                    average_compressed_bytes REAL NOT NULL,
                    maximum_compressed_bytes INTEGER NOT NULL,
                    average_swap_used_bytes REAL NOT NULL,
                    maximum_swap_used_bytes INTEGER NOT NULL,
                    average_pageouts_per_second REAL,
                    maximum_pageouts_per_second REAL,
                    worst_pressure_level INTEGER NOT NULL,
                    elevated_sample_count INTEGER NOT NULL
                );

                PRAGMA user_version = 1;
                """)
        }
    }
}
