import Foundation
import Testing
@testable import AppSlicerML

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private func calmSample(at timestamp: TimeInterval, elevated: Bool = false) -> MemorySample {
    MemorySample(
        timestamp: timestamp,
        usedFraction: 0.5,
        compressedFraction: 0.1,
        swapUsedFraction: 0.1,
        pageoutsPerSecond: 0,
        isPressureElevated: elevated
    )
}

@Suite struct RunningStandardizerTests {
    @Test func producesZeroMeanAndUnitVariance() {
        var standardizer = RunningStandardizer(featureCount: 1)
        for value in [2.0, 4.0, 6.0] {
            standardizer.update([value])
        }
        #expect(standardizer.transform([4])[0] == 0)
        #expect(abs(standardizer.transform([6])[0] - 1) < 1e-12)
    }

    @Test func mapsConstantFeatureToZero() {
        var standardizer = RunningStandardizer(featureCount: 1)
        standardizer.update([5])
        standardizer.update([5])
        #expect(standardizer.transform([9]) == [0])
    }
}

@Suite struct OnlineLogisticRegressionTests {
    @Test func learnsSeparableClasses() {
        var generator = SeededGenerator(state: 1)
        var model = OnlineLogisticRegression(featureCount: 2)
        for _ in 0..<2_000 {
            let x = Double.random(in: -1...1, using: &generator)
            let y = Double.random(in: -1...1, using: &generator)
            model.update([x, y], label: x + y > 0)
        }
        #expect(model.probability([1, 1]) > 0.9)
        #expect(model.probability([-1, -1]) < 0.1)
    }
}

@Suite struct EWMAAnomalyDetectorTests {
    @Test func flagsSpikeOnlyAfterWarmup() {
        var detector = EWMAAnomalyDetector(warmupCount: 10, minimumDeviation: 0.01)
        #expect(!detector.update(0.5).isAnomaly)
        #expect(!detector.update(5).isAnomaly, "spike during warmup must not be flagged")

        var generator = SeededGenerator(state: 2)
        var detectorAfterWarmup = EWMAAnomalyDetector(warmupCount: 10, minimumDeviation: 0.01)
        for _ in 0..<50 {
            let result = detectorAfterWarmup.update(0.5 + Double.random(in: -0.001...0.001, using: &generator))
            #expect(!result.isAnomaly)
        }
        #expect(detectorAfterWarmup.update(0.9).isAnomaly)
    }
}

@Suite struct PressureForecasterTests {
    private func makeConfiguration(minimumExamples: Int = 1) -> PressureForecaster.Configuration {
        var configuration = PressureForecaster.Configuration()
        configuration.horizon = 10
        configuration.maximumSampleGap = 60
        configuration.minimumExamplesPerClass = minimumExamples
        return configuration
    }

    @Test func labelsOnlyEventsInsideTheHorizon() {
        var forecaster = PressureForecaster(configuration: makeConfiguration())
        // The event at t=10 is inside the horizon of t=0 and t=5. It is not in the future
        // of t=10 or t=11, so those two samples must be labeled as calm.
        for (timestamp, elevated) in [(0.0, false), (5, false), (10, true), (11, false), (22, false)] {
            _ = forecaster.observe(calmSample(at: timestamp, elevated: elevated))
        }
        #expect(forecaster.positiveExampleCount == 2)
        #expect(forecaster.negativeExampleCount == 2)
        #expect(forecaster.pendingExampleCount == 1)
    }

    @Test func discardsUnobservedOutcomesAfterSleep() {
        var forecaster = PressureForecaster(configuration: makeConfiguration())
        _ = forecaster.observe(calmSample(at: 0))
        _ = forecaster.observe(calmSample(at: 5))
        _ = forecaster.observe(calmSample(at: 10_000))
        #expect(forecaster.positiveExampleCount == 0)
        #expect(forecaster.negativeExampleCount == 0)
        #expect(forecaster.pendingExampleCount == 1)
    }

    @Test func ignoresNonFiniteSamples() {
        var forecaster = PressureForecaster(configuration: makeConfiguration())
        var invalid = calmSample(at: 0)
        invalid.usedFraction = .nan
        #expect(forecaster.observe(invalid) == nil)
        #expect(forecaster.pendingExampleCount == 0)
    }

    @Test func withholdsForecastUntilBothClassesAreSeen() {
        var forecaster = PressureForecaster(configuration: makeConfiguration())
        for step in 0..<50 {
            #expect(forecaster.observe(calmSample(at: Double(step))) == nil)
        }
        #expect(!forecaster.isReady)
    }

    /// Synthetic scenario: memory and swap ramp up for 5 minutes before each pressure
    /// event. This verifies the learning loop, not accuracy on a real Mac.
    @Test func anticipatesEventsAndBeatsBaseRate() throws {
        var configuration = PressureForecaster.Configuration()
        configuration.horizon = 300
        configuration.minimumExamplesPerClass = 20

        var generator = SeededGenerator(state: 3)
        var forecaster = PressureForecaster(configuration: configuration)

        let step = 10.0
        let calmDuration = 1_800.0
        let rampDuration = 300.0
        let eventDuration = 120.0
        let cycle = calmDuration + rampDuration + eventDuration
        let cycles = 60.0
        let evaluationStart = cycle * 40

        var forecasts: [(timestamp: Double, probability: Double)] = []
        var elevatedTimestamps: [Double] = []
        var rampProbabilities: [Double] = []
        var earlyCalmProbabilities: [Double] = []

        var timestamp = 0.0
        while timestamp < cycle * cycles {
            let phase = timestamp.truncatingRemainder(dividingBy: cycle)
            let noise = Double.random(in: -0.01...0.01, using: &generator)
            let progress: Double
            if phase < calmDuration {
                progress = 0
            } else if phase < calmDuration + rampDuration {
                progress = (phase - calmDuration) / rampDuration
            } else {
                progress = 1
            }
            let elevated = phase >= calmDuration + rampDuration
            if elevated { elevatedTimestamps.append(timestamp) }

            let sample = MemorySample(
                timestamp: timestamp,
                usedFraction: 0.5 + 0.4 * progress + noise,
                compressedFraction: 0.1 + 0.2 * progress + noise,
                swapUsedFraction: 0.1 + 0.5 * progress + noise,
                pageoutsPerSecond: 200 * progress,
                isPressureElevated: elevated
            )

            if let probability = forecaster.observe(sample), timestamp >= evaluationStart {
                forecasts.append((timestamp, probability))
                if phase >= calmDuration + rampDuration / 2 && phase < calmDuration + rampDuration {
                    rampProbabilities.append(probability)
                } else if phase < calmDuration / 2 {
                    earlyCalmProbabilities.append(probability)
                }
            }
            timestamp += step
        }

        let rampMean = rampProbabilities.reduce(0, +) / Double(rampProbabilities.count)
        let calmMean = earlyCalmProbabilities.reduce(0, +) / Double(earlyCalmProbabilities.count)
        #expect(rampMean > 0.7)
        #expect(calmMean < 0.2)

        let scored = forecasts.filter { $0.timestamp + configuration.horizon < cycle * cycles }
        let labels = scored.map { forecast in
            elevatedTimestamps.contains { $0 > forecast.timestamp && $0 <= forecast.timestamp + configuration.horizon }
        }
        let baseRate = Double(labels.filter { $0 }.count) / Double(labels.count)
        var modelError = 0.0
        var baselineError = 0.0
        for (forecast, label) in zip(scored, labels) {
            let outcome = label ? 1.0 : 0.0
            modelError += pow(forecast.probability - outcome, 2)
            baselineError += pow(baseRate - outcome, 2)
        }
        #expect(modelError < baselineError)
    }
}
