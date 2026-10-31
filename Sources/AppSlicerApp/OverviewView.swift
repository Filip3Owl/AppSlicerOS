import Charts
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        if let snapshot = model.snapshot, let status = model.status {
            VStack(alignment: .leading, spacing: 16) {
                StatusHeader(status: status)
                    .padding(.bottom, 16)

                if model.collection != .active {
                    CollectionNotice(state: model.collection)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                    StatTile(
                        label: L("tile.memory"),
                        value: Formatting.gigabytes(snapshot.usedBytes),
                        detail: L("tile.memory.of", Formatting.gigabytes(snapshot.counters.physicalMemoryBytes))
                    )
                    StatTile(
                        label: L("tile.swap"),
                        value: Formatting.gigabytes(snapshot.counters.swapUsedBytes),
                        detail: L(model.isSwapGrowing ? "tile.swap.growing" : "tile.swap.steady")
                    )
                    StatTile(
                        label: L("tile.pressure"),
                        value: L(snapshot.counters.pressureLevel.isElevated ? "pressure.elevated" : "pressure.normal"),
                        detail: L("tile.pressure.detail")
                    )
                }

                MemoryChart(
                    points: model.chartPoints,
                    totalGigabytes: Double(snapshot.counters.physicalMemoryBytes) / Formatting.bytesPerGigabyte
                )
            }
        } else {
            LoadingOrFailure(failed: model.loadFailed)
        }
    }
}

struct CollectionNotice: View {
    let state: CollectionState

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("collection.notice.title")).font(.system(size: 15, weight: .semibold))
                Text(L(state == .stopped ? "collection.stopped" : "collection.never"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MemoryChart: View {
    let points: [ChartPoint]
    let totalGigabytes: Double

    @State private var hovered: ChartPoint?

    private var summary: String {
        guard let last = points.last, let peak = points.map(\.usedGigabytes).max() else {
            return L("chart.empty")
        }
        return L("chart.summary", Formatting.gigabytes(value: last.usedGigabytes), Formatting.gigabytes(value: peak))
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("chart.title")).font(.system(size: 16, weight: .semibold))
                    Text(summary).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if !points.isEmpty {
                    chart.frame(height: 180)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value(L("chart.axis.time"), point.date),
                    y: .value(L("chart.axis.used"), point.usedGigabytes)
                )
                .foregroundStyle(Color.primary)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let hovered {
                RuleMark(x: .value(L("chart.axis.time"), hovered.date))
                    .foregroundStyle(Color.secondary)
                    .annotation(position: .top) {
                        Text("\(hovered.date.formatted(date: .omitted, time: .shortened)): \(Formatting.gigabytes(value: hovered.usedGigabytes))")
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                    }
            }
        }
        .chartYScale(domain: 0...max(totalGigabytes, 1))
        .chartXAxis {
            // The aligned preset keeps the labels at both ends inside the chart.
            AxisMarks(preset: .aligned, values: .stride(by: .minute, count: 15)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartOverlay { proxy in
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
                                points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L("chart.title"))
        .accessibilityValue(summary)
    }
}
