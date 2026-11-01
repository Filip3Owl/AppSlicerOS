import AppSlicerHistory
import AppSlicerML
import AppSlicerMetrics
import Foundation

/// Feeds the interface with live readings. It only reads while a window or the menu bar
/// panel is visible, and it never writes the model or the history, which the collector owns.
@MainActor
final class DashboardModel: ObservableObject {
    private enum Interval {
        static let metrics = 2.0
        static let apps = 5.0
        static let history = 30.0
        static let forecastModel = 300.0
    }

    @Published private(set) var snapshot: MemorySnapshot?
    @Published private(set) var isSwapGrowing = false
    @Published private(set) var forecast = ForecastState.unavailable
    @Published var section = AppSection.overview {
        didSet {
            if section == .history { refreshBucketsIfDue(now: Date()) }
        }
    }
    @Published private(set) var apps: [AppMemory] = []
    @Published private(set) var otherFootprintBytes: UInt64 = 0
    @Published private(set) var otherProcessCount = 0
    @Published private(set) var unreadableProcessCount = 0
    @Published private(set) var chartPoints: [ChartPoint] = []
    @Published private(set) var collection = CollectionState.neverStarted
    @Published private(set) var loadFailed = false
    @Published var historyPeriod = HistoryPeriod.hour {
        didSet {
            if historyPeriod != oldValue {
                historyBuckets = nil
                lastBucketsRead = .distantPast
                refreshBucketsIfDue(now: Date())
            }
        }
    }
    /// `nil` while the selected period is loading.
    @Published private(set) var historyBuckets: [HistoryBucket]?
    @Published private(set) var historyFailed = false

    let dataFolder: URL?

    private let systemReader: SystemMemoryReader?
    private let processReader = ProcessMemoryReader()
    private let forecasterStore: ForecasterStore?
    private let historyStore: HistoryStore?
    private var forecaster: PressureForecaster?
    private var previousSnapshot: MemorySnapshot?
    private var visibleSurfaces = 0
    private var updates: Task<Void, Never>?
    private var lastAppsRead = Date.distantPast
    private var lastHistoryRead = Date.distantPast
    private var lastForecastModelRead = Date.distantPast
    private var lastBucketsRead = Date.distantPast
    private let historyQueries: HistoryQueryService?

    /// - Parameter dataFiles: The model and history to read. Tests must pass their own,
    ///   because opening a history can migrate it.
    init(dataFiles: (model: URL?, history: URL?)? = nil) {
        systemReader = try? SystemMemoryReader()
        let modelFile = dataFiles?.model ?? (dataFiles == nil ? try? ForecasterStore.defaultFileURL() : nil)
        let historyFile = dataFiles?.history ?? (dataFiles == nil ? try? HistoryStore.defaultFileURL() : nil)
        forecasterStore = modelFile.map(ForecasterStore.init(fileURL:))
        historyStore = historyFile.flatMap { try? HistoryStore(fileURL: $0) }
        historyQueries = historyFile.map(HistoryQueryService.init(fileURL:))
        dataFolder = historyFile?.deletingLastPathComponent()
        loadFailed = systemReader == nil
    }

    var status: HealthStatus? {
        snapshot.map { HealthStatus(pressure: $0.counters.pressureLevel, forecast: forecast) }
    }

    func surfaceAppeared() {
        visibleSurfaces += 1
        guard updates == nil else { return }
        updates = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh(now: Date())
                try? await Task.sleep(for: .seconds(Interval.metrics))
            }
        }
    }

    func surfaceDisappeared() {
        visibleSurfaces = max(visibleSurfaces - 1, 0)
        if visibleSurfaces == 0 {
            updates?.cancel()
            updates = nil
        }
    }

    private func refresh(now: Date) {
        refreshForecastModelIfDue(now: now)
        refreshMetrics()
        refreshAppsIfDue(now: now)
        refreshHistoryIfDue(now: now)
        refreshBucketsIfDue(now: now)
    }

    /// Long periods can scan many rows, so they run away from the main thread and only while
    /// the History page is open.
    private func refreshBucketsIfDue(now: Date) {
        guard section == .history, visibleSurfaces > 0, let historyQueries,
              now.timeIntervalSince(lastBucketsRead) >= historyPeriod.refreshInterval
        else { return }
        lastBucketsRead = now
        let period = historyPeriod
        Task { [weak self] in
            let buckets = try? await historyQueries.buckets(period: period, now: now)
            guard let self, self.historyPeriod == period else { return }
            self.historyFailed = buckets == nil
            self.historyBuckets = buckets ?? []
        }
    }

    private func refreshMetrics() {
        guard let systemReader, let current = try? systemReader.read() else {
            loadFailed = true
            return
        }
        loadFailed = false
        let rate = previousSnapshot.flatMap { current.pageoutsPerSecond(since: $0) }
        if let previousSnapshot {
            isSwapGrowing = current.counters.swapUsedBytes > previousSnapshot.counters.swapUsedBytes
        }
        snapshot = current
        previousSnapshot = current
        updateForecast(from: current, pageoutsPerSecond: rate)
    }

    /// Learning in this copy is discarded at the next reload, because only the collector
    /// saves the model.
    private func updateForecast(from snapshot: MemorySnapshot, pageoutsPerSecond: Double?) {
        guard forecaster != nil else {
            forecast = .unavailable
            return
        }
        let sample = MemorySample(
            timestamp: snapshot.timestamp.timeIntervalSince1970,
            usedFraction: snapshot.usedFraction,
            compressedFraction: snapshot.compressedFraction,
            swapUsedFraction: snapshot.swapUsedFraction,
            pageoutsPerSecond: pageoutsPerSecond ?? 0,
            isPressureElevated: snapshot.counters.pressureLevel.isElevated
        )
        if let probability = forecaster?.observe(sample) {
            forecast = .ready(probability: probability)
        } else if let forecaster {
            forecast = .learning(
                elevatedExamples: forecaster.positiveExampleCount,
                calmExamples: forecaster.negativeExampleCount,
                requiredExamples: forecaster.configuration.minimumExamplesPerClass
            )
        }
    }

    private func refreshForecastModelIfDue(now: Date) {
        guard now.timeIntervalSince(lastForecastModelRead) >= Interval.forecastModel else { return }
        lastForecastModelRead = now
        forecaster = try? forecasterStore?.load(configuration: PressureForecaster.Configuration())
    }

    private func refreshAppsIfDue(now: Date) {
        guard now.timeIntervalSince(lastAppsRead) >= Interval.apps else { return }
        lastAppsRead = now
        guard let report = try? processReader.readApps(limit: 30) else { return }
        apps = report.apps
        otherFootprintBytes = report.otherFootprintBytes
        otherProcessCount = report.otherProcessCount
        unreadableProcessCount = report.unreadableCount
    }

    private func refreshHistoryIfDue(now: Date) {
        guard now.timeIntervalSince(lastHistoryRead) >= Interval.history else { return }
        lastHistoryRead = now
        guard let historyStore,
              let readings = try? historyStore.readings(from: now.addingTimeInterval(-3_600), through: now)
        else {
            collection = .neverStarted
            return
        }
        chartPoints = ChartPoint.byMinute(readings.map { (date: $0.timestamp, usedBytes: $0.usedBytes) })
        collection = CollectionState(latestReading: readings.last?.timestamp, now: now)
    }
}
