import AppSlicerHistory
import Charts
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: DashboardModel

    private var maximumGigabytes: Double {
        model.snapshot.map { Double($0.counters.physicalMemoryBytes) / Formatting.bytesPerGigabyte } ?? 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: L("nav.history"), detail: L("history.detail"))

            Picker(L("history.period"), selection: $model.historyPeriod) {
                ForEach(HistoryPeriod.allCases) { period in
                    Text(period.label).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.historyFailed {
            Card { Text(L("history.failed")).foregroundStyle(.secondary) }
        } else if let buckets = model.historyBuckets {
            if buckets.isEmpty {
                Card { Text(L("history.empty")).foregroundStyle(.secondary) }
            } else {
                CompositionChart(
                    buckets: buckets,
                    period: model.historyPeriod,
                    minimumGigabytes: maximumGigabytes
                )
                SwapHistoryChart(buckets: buckets, period: model.historyPeriod)
            }
        } else {
            Card {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(L("history.loading")).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Shared scale so the charts cover the whole period, with empty time left visibly empty.
private func domain(for period: HistoryPeriod) -> ClosedRange<Date> {
    let now = Date()
    return now.addingTimeInterval(-period.span)...now
}

private func summary(_ key: String, average: Double, peak: UInt64) -> String {
    L(key, Formatting.gigabytes(value: average / Formatting.bytesPerGigabyte), Formatting.gigabytes(peak))
}

private func weightedAverage(_ buckets: [HistoryBucket], _ value: (HistoryBucket) -> Double) -> Double {
    let samples = buckets.reduce(0) { $0 + $1.sampleCount }
    guard samples > 0 else { return 0 }
    return buckets.reduce(0.0) { $0 + value($1) * Double($1.sampleCount) } / Double(samples)
}

/// Date labels that fit each period's length.
private func axisFormat(for period: HistoryPeriod) -> Date.FormatStyle {
    switch period {
    case .hour, .day: .dateTime.hour().minute()
    case .week, .quarter: .dateTime.day().month(.abbreviated)
    }
}

private func nearestBucket(to date: Date, in buckets: [HistoryBucket]) -> HistoryBucket? {
    buckets.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
}

private func tooltipDate(_ bucket: HistoryBucket, period: HistoryPeriod) -> String {
    switch period {
    case .hour, .day: bucket.start.formatted(date: .omitted, time: .shortened)
    case .week, .quarter: bucket.start.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Tracks the pointer across a chart and reports the bucket under it.
private struct ChartHover: ViewModifier {
    let buckets: [HistoryBucket]
    let bucketDuration: TimeInterval
    @Binding var hovered: HistoryBucket?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plot = geometry[proxy.plotAreaFrame]
                            let date: Date? = proxy.value(atX: location.x - plot.minX)
                            hovered = date.flatMap { date in
                                nearestBucket(to: date.addingTimeInterval(-bucketDuration / 2), in: buckets)
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }
}

private struct CompositionChart: View {
    let buckets: [HistoryBucket]
    let period: HistoryPeriod
    let minimumGigabytes: Double

    @State private var hovered: HistoryBucket?

    private var segments: [CompositionSegment] {
        CompositionSegment.segments(from: buckets, bucketDuration: period.bucketDuration)
    }

    private var summaryText: String {
        summary(
            "history.composition.summary",
            average: weightedAverage(buckets, \.averageUsedBytes),
            peak: buckets.map(\.maximumUsedBytes).max() ?? 0
        )
    }

    private var tooltip: String? {
        guard let hovered, let values = hovered.compositionValues else { return nil }
        let parts = MemoryCategory.allCases.map { category in
            "\(category.label) \(Formatting.gigabytes(value: (values[category] ?? 0) / Formatting.bytesPerGigabyte))"
        }
        return "\(tooltipDate(hovered, period: period)): \(parts.joined(separator: " · "))"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("history.composition.title")).font(.system(size: 16, weight: .semibold))
                    Text(tooltip ?? summaryText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .monospacedDigit()
                }
                if segments.isEmpty {
                    Text(L("history.composition.empty")).foregroundStyle(.secondary)
                } else {
                    chart.frame(height: 240)
                }
            }
        }
    }

    private var chart: some View {
        Chart(segments) { segment in
            RectangleMark(
                xStart: .value(L("chart.axis.time"), segment.start),
                xEnd: .value(L("chart.axis.time"), segment.end),
                yStart: .value(L("chart.axis.used"), segment.lowerGigabytes),
                yEnd: .value(L("chart.axis.used"), segment.upperGigabytes)
            )
            .foregroundStyle(by: .value(L("history.composition.title"), segment.category.label))
        }
        .chartForegroundStyleScale(
            domain: MemoryCategory.allCases.map(\.label),
            range: MemoryCategory.allCases.map(\.color)
        )
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXScale(domain: domain(for: period))
        .chartYScale(domain: 0...max(minimumGigabytes, segments.map(\.upperGigabytes).max() ?? 0))
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: axisFormat(for: period))
            }
        }
        .modifier(ChartHover(buckets: buckets, bucketDuration: period.bucketDuration, hovered: $hovered))
        .accessibilityElement()
        .accessibilityLabel(L("history.composition.title"))
        .accessibilityValue(summaryText)
    }
}

private struct SwapHistoryChart: View {
    let buckets: [HistoryBucket]
    let period: HistoryPeriod

    @State private var hovered: HistoryBucket?

    private var summaryText: String {
        summary(
            "history.swap.summary",
            average: weightedAverage(buckets, \.averageSwapUsedBytes),
            peak: buckets.map(\.maximumSwapUsedBytes).max() ?? 0
        )
    }

    private var tooltip: String? {
        hovered.map { bucket in
            let value = Formatting.gigabytes(value: bucket.averageSwapUsedBytes / Formatting.bytesPerGigabyte)
            return "\(tooltipDate(bucket, period: period)): \(value)"
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("history.swap.title")).font(.system(size: 16, weight: .semibold))
                    Text(tooltip ?? summaryText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                chart.frame(height: 140)
            }
        }
    }

    private var chart: some View {
        Chart(buckets, id: \.start) { bucket in
            RectangleMark(
                xStart: .value(L("chart.axis.time"), bucket.start),
                xEnd: .value(L("chart.axis.time"), bucket.start.addingTimeInterval(period.bucketDuration)),
                yStart: .value(L("history.swap.title"), 0.0),
                yEnd: .value(L("history.swap.title"), bucket.averageSwapUsedBytes / Formatting.bytesPerGigabyte)
            )
            .foregroundStyle(Color.primary.opacity(0.75))
        }
        .chartXScale(domain: domain(for: period))
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: axisFormat(for: period))
            }
        }
        .modifier(ChartHover(buckets: buckets, bucketDuration: period.bucketDuration, hovered: $hovered))
        .accessibilityElement()
        .accessibilityLabel(L("history.swap.title"))
        .accessibilityValue(summaryText)
    }
}

private extension HistoryBucket {
    var compositionValues: [MemoryCategory: Double]? {
        guard let averageAppBytes, let averageWiredBytes, let averageCachedBytes, let averageFreeBytes else {
            return nil
        }
        return [
            .app: averageAppBytes,
            .wired: averageWiredBytes,
            .compressed: averageCompressedBytes,
            .cached: averageCachedBytes,
            .free: averageFreeBytes,
        ]
    }
}
