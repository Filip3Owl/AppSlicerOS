import AppSlicerMetrics
import Foundation

enum ReportFormatter {
    /// - Parameter pageoutsPerSecond: `nil` on the first reading, which has no earlier
    ///   reading to compare against.
    static func format(
        time: String,
        snapshot: MemorySnapshot,
        pageoutsPerSecond: Double?,
        forecast: ForecastStatus,
        report: ProcessMemoryReport?
    ) -> String {
        let counters = snapshot.counters
        let rate = pageoutsPerSecond.map { String(format: "%.1f/s", $0) } ?? "-"
        var lines = [
            "\(time)  pressure: \(name(of: counters.pressureLevel))",
            "  memory:  \(gigabytes(snapshot.usedBytes)) used of \(gigabytes(counters.physicalMemoryBytes))"
                + " (\(percent(snapshot.usedFraction)))",
            "           app \(gigabytes(snapshot.appBytes)), wired \(gigabytes(snapshot.wiredBytes)),"
                + " compressed \(gigabytes(snapshot.compressedBytes))",
            "           cached \(gigabytes(snapshot.cachedBytes)), free \(gigabytes(snapshot.freeBytes))",
            "  swap:    \(gigabytes(counters.swapUsedBytes)) used of \(gigabytes(counters.swapTotalBytes))"
                + ", pageouts \(rate)",
            "  forecast: \(describe(forecast))",
        ]

        if let report {
            if !report.processes.isEmpty {
                lines.append("  top processes:")
                lines += report.processes.map { process in
                    "    \(gigabytes(process.footprintBytes))  \(process.name) (\(process.pid))"
                }
            }
            if report.unreadableCount > 0 {
                lines.append("  not readable without root: \(report.unreadableCount) processes")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ forecast: ForecastStatus) -> String {
        switch forecast {
        case .learning(let elevated, let calm, let required):
            "learning (\(min(elevated, required))/\(required) elevated pressure examples,"
                + " \(min(calm, required))/\(required) calm examples)"
        case .ready(let probability, let horizon):
            "\(percent(probability)) chance of elevated pressure in the next"
                + " \(Int((horizon / 60).rounded())) min"
        }
    }

    private static func name(of level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }

    /// Uses 1,024-based units with the "GB" label, matching Activity Monitor.
    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}
