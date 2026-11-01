import AppKit
import AppSlicerHistory
import SwiftUI

enum HistoryPeriod: String, CaseIterable, Identifiable, Sendable {
    case hour
    case day
    case week
    case quarter

    var id: String { rawValue }

    var span: TimeInterval {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        case .quarter: 90 * 86_400
        }
    }

    var bucketDuration: TimeInterval {
        switch self {
        case .hour: 60
        case .day: 600
        case .week: 3_600
        case .quarter: 21_600
        }
    }

    var refreshInterval: TimeInterval {
        self == .hour ? 30 : 300
    }

    var label: String {
        switch self {
        case .hour: L("history.period.hour")
        case .day: L("history.period.day")
        case .week: L("history.period.week")
        case .quarter: L("history.period.quarter")
        }
    }
}

/// Runs history queries away from the main thread, on its own database connection.
actor HistoryQueryService {
    private let fileURL: URL
    private var store: HistoryStore?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func buckets(period: HistoryPeriod, now: Date) throws -> [HistoryBucket] {
        if store == nil {
            store = try HistoryStore(fileURL: fileURL)
        }
        return try store?.buckets(
            from: now.addingTimeInterval(-period.span),
            through: now,
            duration: period.bucketDuration
        ) ?? []
    }
}

/// The fixed stacking order. The colors passed the color vision check in both themes when
/// used in this order, so changing it requires validating the palette again.
enum MemoryCategory: String, CaseIterable, Identifiable {
    case app
    case wired
    case compressed
    case cached
    case free

    var id: String { rawValue }

    var label: String {
        switch self {
        case .app: L("history.category.app")
        case .wired: L("history.category.wired")
        case .compressed: L("history.category.compressed")
        case .cached: L("history.category.cached")
        case .free: L("history.category.free")
        }
    }

    var color: Color {
        switch self {
        case .app: Self.dynamic(light: 0x2A78D6, dark: 0x3987E5)
        case .wired: Self.dynamic(light: 0x1BAF7A, dark: 0x199E70)
        case .compressed: Self.dynamic(light: 0xEDA100, dark: 0xC98500)
        case .cached: Self.dynamic(light: 0xE87BA4, dark: 0xD55181)
        case .free: Self.dynamic(light: 0x6250D6, dark: 0x9085E9)
        }
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

struct CompositionSegment: Identifiable, Equatable {
    let category: MemoryCategory
    let start: Date
    let end: Date
    let lowerGigabytes: Double
    let upperGigabytes: Double

    var id: String { "\(start.timeIntervalSince1970)-\(category.rawValue)" }

    /// Builds one stacked column per period, so time without readings stays visibly empty
    /// and a period with a single reading still appears.
    static func segments(from buckets: [HistoryBucket], bucketDuration: TimeInterval) -> [CompositionSegment] {
        buckets.flatMap { bucket -> [CompositionSegment] in
            guard let app = bucket.averageAppBytes,
                  let wired = bucket.averageWiredBytes,
                  let cached = bucket.averageCachedBytes,
                  let free = bucket.averageFreeBytes
            else { return [] }

            let values: [(MemoryCategory, Double)] = [
                (.app, app),
                (.wired, wired),
                (.compressed, bucket.averageCompressedBytes),
                (.cached, cached),
                (.free, free),
            ]
            var lower = 0.0
            return values.map { category, bytes in
                let upper = lower + bytes
                defer { lower = upper }
                return CompositionSegment(
                    category: category,
                    start: bucket.start,
                    end: bucket.start.addingTimeInterval(bucketDuration),
                    lowerGigabytes: lower / Formatting.bytesPerGigabyte,
                    upperGigabytes: upper / Formatting.bytesPerGigabyte
                )
            }
        }
    }
}
