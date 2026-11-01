import AppSlicerHistory
import AppSlicerMetrics
import Foundation
import Testing
@testable import AppSlicerApp

@Suite struct HealthStatusTests {
    @Test func systemPressureComesBeforeTheForecast() {
        for forecast in [ForecastState.unavailable, .ready(probability: 0.01)] {
            #expect(HealthStatus(pressure: .warning, forecast: forecast) == .elevatedNow)
            #expect(HealthStatus(pressure: .critical, forecast: forecast) == .elevatedNow)
        }
    }

    @Test func forecastDecidesWhilePressureIsNormal() {
        #expect(HealthStatus(pressure: .normal, forecast: .ready(probability: 0.49)) == .calm)
        #expect(HealthStatus(pressure: .normal, forecast: .ready(probability: 0.5)) == .elevatedSoon)
    }

    @Test func withoutAForecastItNeverClaimsMoreThanLearning() {
        let learning = ForecastState.learning(elevatedExamples: 0, calmExamples: 50, requiredExamples: 20)
        #expect(HealthStatus(pressure: .normal, forecast: learning) == .learning)
        #expect(HealthStatus(pressure: .normal, forecast: .unavailable) == .learning)
    }

    @Test func onlyElevatedStatesNeedAttention() {
        #expect(!HealthStatus.calm.needsAttention)
        #expect(!HealthStatus.learning.needsAttention)
        #expect(HealthStatus.elevatedSoon.needsAttention)
        #expect(HealthStatus.elevatedNow.needsAttention)
    }
}

@Suite struct CollectionStateTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func reflectsTheAgeOfTheLatestReading() {
        #expect(CollectionState(latestReading: nil, now: now) == .neverStarted)
        #expect(CollectionState(latestReading: now.addingTimeInterval(-90), now: now) == .active)
        #expect(CollectionState(latestReading: now.addingTimeInterval(-91), now: now) == .stopped)
    }
}

@Suite struct ChartPointTests {
    @Test func averagesReadingsByMinuteInOrder() {
        let gigabyte = UInt64(Formatting.bytesPerGigabyte)
        let readings: [(date: Date, usedBytes: UInt64)] = [
            (Date(timeIntervalSince1970: 130), 5 * gigabyte),
            (Date(timeIntervalSince1970: 60), 2 * gigabyte),
            (Date(timeIntervalSince1970: 119), 4 * gigabyte),
        ]
        #expect(ChartPoint.byMinute(readings) == [
            ChartPoint(date: Date(timeIntervalSince1970: 60), usedGigabytes: 3),
            ChartPoint(date: Date(timeIntervalSince1970: 120), usedGigabytes: 5),
        ])
    }

    @Test func startsANewSegmentAfterAGapInTheData() {
        let readings: [(date: Date, usedBytes: UInt64)] = [0.0, 60, 240, 600, 660].map {
            (Date(timeIntervalSince1970: $0), 1)
        }
        // Gaps of 180 seconds stay joined. Longer ones break the line.
        #expect(ChartPoint.byMinute(readings).map(\.segment) == [0, 0, 0, 1, 1])
    }

    @Test func handlesNoReadings() {
        #expect(ChartPoint.byMinute([]).isEmpty)
    }
}

@Suite struct FormattingTests {
    @Test func followsTheLocale() {
        let brazil = Locale(identifier: "pt_BR")
        let us = Locale(identifier: "en_US")
        #expect(Formatting.gigabytes(1_610_612_736, locale: brazil) == "1,50 GB")
        #expect(Formatting.gigabytes(1_610_612_736, locale: us) == "1.50 GB")
        #expect(Formatting.percent(0.73, locale: us) == "73%")
    }

    @Test func showsSmallAmountsInMegabytes() {
        let us = Locale(identifier: "en_US")
        #expect(Formatting.compactSize(52_428_800, locale: us) == "50 MB")
        #expect(Formatting.compactSize(1_073_741_823, locale: us) == "1,024 MB")
        #expect(Formatting.compactSize(1_073_741_824, locale: us) == "1.00 GB")
    }
}

@MainActor
@Suite struct DashboardUpdateTests {
    /// Never the default files, because the real history must not be migrated by a test.
    private func makeModel() -> DashboardModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSlicerOSAppTests-\(UUID().uuidString)", isDirectory: true)
        return DashboardModel(dataFiles: (
            model: directory.appendingPathComponent("test.model.json"),
            history: directory.appendingPathComponent("history.sqlite")
        ))
    }

    @Test func readsOnlyWhileASurfaceIsVisible() async throws {
        let model = makeModel()
        #expect(model.snapshot == nil)

        model.surfaceAppeared()
        model.surfaceAppeared()
        try await Task.sleep(for: .milliseconds(300))
        let first = try #require(model.snapshot)

        // One surface is still visible, so readings continue.
        model.surfaceDisappeared()
        try await Task.sleep(for: .seconds(3))
        let second = try #require(model.snapshot)
        #expect(second.timestamp > first.timestamp)

        // No surface is visible, so readings stop.
        model.surfaceDisappeared()
        try await Task.sleep(for: .seconds(3))
        #expect(model.snapshot?.timestamp == second.timestamp)
    }

    @Test func extraHideEventsDoNotBreakTheCount() async throws {
        let model = makeModel()
        model.surfaceDisappeared()
        model.surfaceAppeared()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.snapshot != nil)
        model.surfaceDisappeared()
    }

    @Test func loadsTheSelectedHistoryPeriodOnlyOnTheHistoryPage() async throws {
        let model = makeModel()
        model.surfaceAppeared()
        defer { model.surfaceDisappeared() }

        try await Task.sleep(for: .milliseconds(300))
        #expect(model.historyBuckets == nil)

        model.section = .history
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.historyBuckets == [])
        #expect(!model.historyFailed)

        // Changing the period clears the old data until the new one arrives.
        model.historyPeriod = .week
        #expect(model.historyBuckets == nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.historyBuckets == [])
    }
}

@Suite struct HistoryPeriodTests {
    @Test func periodsKeepTheChartsLight() {
        for period in HistoryPeriod.allCases {
            #expect(period.span / period.bucketDuration <= 360)
        }
    }

    @Test func longerPeriodsReadLessOften() {
        #expect(HistoryPeriod.hour.refreshInterval < HistoryPeriod.week.refreshInterval)
    }

    @Test func periodSpansMatchTheRetentionOfTheHistory() {
        #expect(HistoryPeriod.week.span == RetentionPolicy().readingRetention)
        #expect(HistoryPeriod.quarter.span == RetentionPolicy().summaryRetention)
    }
}

@Suite struct CompositionTests {
    private func bucket(start: TimeInterval = 600, app: Double? = 10, wired: Double? = 20, cached: Double? = 40, free: Double? = 50) -> HistoryBucket {
        HistoryBucket(
            start: Date(timeIntervalSince1970: start),
            sampleCount: 1,
            averageUsedBytes: 60,
            maximumUsedBytes: 60,
            averageAppBytes: app,
            averageWiredBytes: wired,
            averageCompressedBytes: 30,
            averageCachedBytes: cached,
            averageFreeBytes: free,
            averageSwapUsedBytes: 0,
            maximumSwapUsedBytes: 0,
            worstPressureLevel: .normal,
            elevatedSampleCount: 0
        )
    }

    @Test func stacksCategoriesInFixedOrderWithoutGaps() {
        let segments = CompositionSegment.segments(from: [bucket()], bucketDuration: 60)
        #expect(segments.map(\.category) == MemoryCategory.allCases)
        #expect(segments.map(\.lowerGigabytes) == [0, 10, 30, 60, 100].map { $0 / Formatting.bytesPerGigabyte })
        #expect(segments.map(\.upperGigabytes) == [10, 30, 60, 100, 150].map { $0 / Formatting.bytesPerGigabyte })
        #expect(segments.allSatisfy { $0.end.timeIntervalSince($0.start) == 60 })
    }

    @Test func omitsPeriodsWithoutComposition() {
        #expect(CompositionSegment.segments(from: [bucket(app: nil)], bucketDuration: 60).isEmpty)
        #expect(CompositionSegment.segments(from: [bucket(free: nil)], bucketDuration: 60).isEmpty)
    }

    @Test func leavesTimeWithoutDataEmpty() {
        let segments = CompositionSegment.segments(from: [bucket(start: 0), bucket(start: 600)], bucketDuration: 60)
        #expect(Set(segments.map(\.start.timeIntervalSince1970)) == [0, 600])
    }

    @Test func eachCategoryHasALabel() {
        #expect(Set(MemoryCategory.allCases.map(\.label)).count == MemoryCategory.allCases.count)
    }
}

@Suite struct AppSectionTests {
    @Test func shortcutsFollowThePageOrder() {
        #expect(AppSection.allCases.map(\.shortcut.character) == ["1", "2", "3", "4", "5"])
    }
}

@Suite struct LocalizationTests {
    private func strings(language: String) throws -> [String: String] {
        let url = try #require(Bundle.module.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: language
        ))
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    @Test func selectsPortugueseOnlyWhenPreferred() {
        func selection(for preferences: [String]) -> String? {
            Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: preferences)
                .first?.lowercased()
        }
        #expect(selection(for: ["pt-BR"]) == "pt-br")
        #expect(selection(for: ["en-BR", "pt-BR"]) == "en")
        #expect(selection(for: ["fr-FR"]) == "en")
    }

    @Test func bothLanguagesHaveTheSameKeys() throws {
        let english = try strings(language: "en")
        let portuguese = try strings(language: "pt-BR")
        #expect(!english.isEmpty)
        #expect(Set(english.keys) == Set(portuguese.keys))
    }

    @Test func formatPlaceholdersMatchBetweenLanguages() throws {
        let english = try strings(language: "en")
        let portuguese = try strings(language: "pt-BR")
        let placeholder = /%(\d\$)?[@d]/
        for (key, text) in english {
            let expected = text.matches(of: placeholder).map { String($0.output.0) }.sorted()
            let actual = (portuguese[key] ?? "").matches(of: placeholder).map { String($0.output.0) }.sorted()
            #expect(expected == actual, "\(key)")
        }
    }

    @Test func everyKeyUsedInTheSourceExists() throws {
        let english = try strings(language: "en")
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AppSlicerApp")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        // The lookahead skips the "chart.line…" SF Symbol name, which is not a text key.
        let usage = /"((?:nav|status|tile|pressure|chart(?!\.line)|collection|apps|forecast|settings|menu|error|history)\.[a-z.]+|loading)"/
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: usage) {
                checked += 1
                #expect(english[String(match.output.1)] != nil, "\(match.output.1)")
            }
        }
        #expect(checked > 30)
    }
}
