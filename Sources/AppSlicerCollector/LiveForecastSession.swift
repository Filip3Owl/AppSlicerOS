import AppSlicerML
import AppSlicerMetrics
import Foundation

enum ForecastStatus: Equatable {
    case learning(elevatedExamples: Int, calmExamples: Int, requiredExamples: Int)
    case ready(probability: Double, horizon: TimeInterval)
}

extension MemorySample {
    /// The first reading has no pageout rate yet, so it counts as zero.
    init(snapshot: MemorySnapshot, pageoutsPerSecond: Double?) {
        self.init(
            timestamp: snapshot.timestamp.timeIntervalSince1970,
            usedFraction: snapshot.usedFraction,
            compressedFraction: snapshot.compressedFraction,
            swapUsedFraction: snapshot.swapUsedFraction,
            pageoutsPerSecond: pageoutsPerSecond ?? 0,
            isPressureElevated: snapshot.counters.pressureLevel.isElevated
        )
    }
}

/// Feeds live readings to the model and keeps its saved state up to date.
struct LiveForecastSession {
    private let store: ForecasterStore
    private let saveInterval: TimeInterval
    private var lastSave: Date
    private(set) var forecaster: PressureForecaster

    init(store: ForecasterStore, saveInterval: TimeInterval, now: Date) throws {
        self.store = store
        self.saveInterval = saveInterval
        lastSave = now
        forecaster = try store.load(configuration: PressureForecaster.Configuration())
    }

    mutating func observe(snapshot: MemorySnapshot, pageoutsPerSecond: Double?) -> ForecastStatus {
        let sample = MemorySample(snapshot: snapshot, pageoutsPerSecond: pageoutsPerSecond)
        guard let probability = forecaster.observe(sample) else {
            return .learning(
                elevatedExamples: forecaster.positiveExampleCount,
                calmExamples: forecaster.negativeExampleCount,
                requiredExamples: forecaster.configuration.minimumExamplesPerClass
            )
        }
        return .ready(probability: probability, horizon: forecaster.configuration.horizon)
    }

    /// - Returns: Whether a save happened.
    @discardableResult
    mutating func saveIfDue(now: Date) throws -> Bool {
        guard now.timeIntervalSince(lastSave) >= saveInterval else { return false }
        // Updated first so a failing disk is retried at the next interval, not every reading.
        lastSave = now
        try store.save(forecaster)
        return true
    }

    func save() throws {
        try store.save(forecaster)
    }
}
