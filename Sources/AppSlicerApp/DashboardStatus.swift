import AppSlicerML
import AppSlicerMetrics
import Foundation

enum ForecastState: Equatable {
    case unavailable
    case learning(elevatedExamples: Int, calmExamples: Int, requiredExamples: Int)
    case ready(probability: Double)
}

enum HealthStatus: Equatable {
    case calm
    case learning
    case elevatedSoon
    case elevatedNow

    static let attentionProbability = 0.5

    /// The system's own report comes first, because a forecast is only an estimate.
    init(pressure: MemoryPressureLevel, forecast: ForecastState) {
        if pressure.isElevated {
            self = .elevatedNow
            return
        }
        switch forecast {
        case .unavailable, .learning:
            self = .learning
        case .ready(let probability):
            self = probability >= Self.attentionProbability ? .elevatedSoon : .calm
        }
    }

    var needsAttention: Bool {
        self == .elevatedSoon || self == .elevatedNow
    }
}

enum CollectionState: Equatable {
    case active
    case stopped
    case neverStarted

    /// The dashboard rereads the history every 30 seconds, so this allows for one missed
    /// refresh before reporting that collection stopped.
    static let maximumAge: TimeInterval = 90

    init(latestReading: Date?, now: Date) {
        guard let latestReading else {
            self = .neverStarted
            return
        }
        self = now.timeIntervalSince(latestReading) <= Self.maximumAge ? .active : .stopped
    }
}

struct ChartPoint: Identifiable, Equatable {
    let date: Date
    let usedGigabytes: Double
    /// Points in different segments are not joined, so the line never suggests data for a
    /// period with no readings, such as while the Mac was asleep.
    var segment = 0
    var id: Date { date }

    private static let maximumGapInSegment: TimeInterval = 180

    /// Averages readings by minute, which keeps the chart light and the line readable.
    static func byMinute(_ readings: [(date: Date, usedBytes: UInt64)]) -> [ChartPoint] {
        let groups = Dictionary(grouping: readings) { reading in
            (reading.date.timeIntervalSince1970 / 60).rounded(.down)
        }
        var points = groups
            .map { minute, readings in
                let total = readings.reduce(0.0) { $0 + Double($1.usedBytes) }
                return ChartPoint(
                    date: Date(timeIntervalSince1970: minute * 60),
                    usedGigabytes: total / Double(readings.count) / Formatting.bytesPerGigabyte
                )
            }
            .sorted { $0.date < $1.date }

        for index in points.indices.dropFirst() {
            let gap = points[index].date.timeIntervalSince(points[index - 1].date)
            points[index].segment = points[index - 1].segment + (gap > maximumGapInSegment ? 1 : 0)
        }
        return points
    }
}

enum Formatting {
    /// Uses 1,024-based units with the "GB" label, matching Activity Monitor.
    static let bytesPerGigabyte = 1_073_741_824.0

    static func gigabytes(_ bytes: UInt64, locale: Locale = .current) -> String {
        gigabytes(value: Double(bytes) / bytesPerGigabyte, locale: locale)
    }

    static func gigabytes(value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(2)).locale(locale)) + " GB"
    }

    /// Shows amounts under 1 GB in megabytes, so small apps do not read as "0.00 GB".
    static func compactSize(_ bytes: UInt64, locale: Locale = .current) -> String {
        guard Double(bytes) < bytesPerGigabyte else { return gigabytes(bytes, locale: locale) }
        let megabytes = Double(bytes) / 1_048_576
        return megabytes.formatted(.number.precision(.fractionLength(0)).locale(locale)) + " MB"
    }

    static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}
