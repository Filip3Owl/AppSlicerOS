import AppSlicerHistory
import AppSlicerMetrics
import Foundation

/// Records each reading and applies the retention policy at start-up and every hour.
struct HistoryRecorder {
    private static let retentionInterval: TimeInterval = 3_600

    private let store: HistoryStore
    private var lastRetention: Date?

    init(store: HistoryStore) {
        self.store = store
    }

    mutating func record(_ snapshot: MemorySnapshot, pageoutsPerSecond: Double?, now: Date) throws {
        try store.record(snapshot, pageoutsPerSecond: pageoutsPerSecond)

        let isDue = lastRetention.map { now.timeIntervalSince($0) >= Self.retentionInterval } ?? true
        if isDue {
            // Updated first so a failure is retried at the next interval, not every reading.
            lastRetention = now
            try store.applyRetention(now: now)
        }
    }
}
