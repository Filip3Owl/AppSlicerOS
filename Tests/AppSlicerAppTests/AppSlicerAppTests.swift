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
        let usage = /"((?:nav|status|tile|pressure|chart(?!\.line)|collection|apps|forecast|settings|menu|error)\.[a-z.]+|loading)"/
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
