import Foundation

/// One system-wide memory reading. Fractions are relative to total RAM, or to the swap
/// capacity in the case of `swapUsedFraction`.
public struct MemorySample: Codable, Equatable, Sendable {
    public var timestamp: TimeInterval
    public var usedFraction: Double
    public var compressedFraction: Double
    public var swapUsedFraction: Double
    public var pageoutsPerSecond: Double
    public var isPressureElevated: Bool

    public init(
        timestamp: TimeInterval,
        usedFraction: Double,
        compressedFraction: Double,
        swapUsedFraction: Double,
        pageoutsPerSecond: Double,
        isPressureElevated: Bool
    ) {
        self.timestamp = timestamp
        self.usedFraction = usedFraction
        self.compressedFraction = compressedFraction
        self.swapUsedFraction = swapUsedFraction
        self.pageoutsPerSecond = pageoutsPerSecond
        self.isPressureElevated = isPressureElevated
    }
}

/// Learns on-device whether memory pressure will become elevated within a time horizon.
///
/// Each sample is held until its horizon has passed, because only then is its true label
/// known. The model therefore never trains on information from the sample's own future.
public struct PressureForecaster: Codable, Sendable {
    public struct Configuration: Codable, Sendable {
        public var horizon: TimeInterval = 600
        /// Longer gaps, such as the Mac sleeping, leave outcomes unobserved, so pending
        /// samples are discarded instead of being labeled as calm.
        public var maximumSampleGap: TimeInterval = 60
        /// Examples required from each class before forecasts are published.
        public var minimumExamplesPerClass = 20

        public init() {}
    }

    private struct PendingExample: Codable, Sendable {
        let timestamp: TimeInterval
        let features: [Double]
        var becameElevated = false
    }

    private static let featureCount = 7

    public private(set) var positiveExampleCount = 0
    public private(set) var negativeExampleCount = 0

    private let configuration: Configuration
    private var standardizer = RunningStandardizer(featureCount: featureCount)
    private var model = OnlineLogisticRegression(featureCount: featureCount)
    private var pending: [PendingExample] = []
    private var previousSample: MemorySample?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isReady: Bool {
        positiveExampleCount >= configuration.minimumExamplesPerClass
            && negativeExampleCount >= configuration.minimumExamplesPerClass
    }

    public var pendingExampleCount: Int { pending.count }

    /// Learns from any outcomes this sample resolves and forecasts from its features.
    /// - Returns: The probability of elevated pressure within the horizon, or `nil` while
    ///   the model lacks enough examples or the sample contains non-finite values.
    public mutating func observe(_ sample: MemorySample) -> Double? {
        if let previousSample {
            let gap = sample.timestamp - previousSample.timestamp
            if gap <= 0 || gap > configuration.maximumSampleGap {
                resetContinuity()
            }
        }

        // Computed after the gap check so a discontinuity never appears as a sudden trend.
        guard let features = makeFeatures(for: sample) else {
            resetContinuity()
            return nil
        }

        trainOnResolvedExamples(before: sample.timestamp)

        if sample.isPressureElevated {
            for index in pending.indices {
                pending[index].becameElevated = true
            }
        }

        standardizer.update(features)
        pending.append(PendingExample(timestamp: sample.timestamp, features: features))
        previousSample = sample

        guard isReady else { return nil }
        return model.probability(standardizer.transform(features))
    }

    private mutating func trainOnResolvedExamples(before timestamp: TimeInterval) {
        var resolvedCount = 0
        for example in pending where example.timestamp + configuration.horizon < timestamp {
            model.update(standardizer.transform(example.features), label: example.becameElevated)
            if example.becameElevated {
                positiveExampleCount += 1
            } else {
                negativeExampleCount += 1
            }
            resolvedCount += 1
        }
        pending.removeFirst(resolvedCount)
    }

    private mutating func resetContinuity() {
        pending.removeAll()
        previousSample = nil
    }

    private func makeFeatures(for sample: MemorySample) -> [Double]? {
        var usedTrend = 0.0
        var compressedTrend = 0.0
        var swapTrend = 0.0

        if let previousSample {
            let minutes = (sample.timestamp - previousSample.timestamp) / 60
            if minutes > 0 {
                usedTrend = (sample.usedFraction - previousSample.usedFraction) / minutes
                compressedTrend = (sample.compressedFraction - previousSample.compressedFraction) / minutes
                swapTrend = (sample.swapUsedFraction - previousSample.swapUsedFraction) / minutes
            }
        }

        let features = [
            sample.usedFraction,
            sample.compressedFraction,
            sample.swapUsedFraction,
            log1p(max(sample.pageoutsPerSecond, 0)),
            usedTrend,
            compressedTrend,
            swapTrend,
        ]
        return features.allSatisfy(\.isFinite) && sample.timestamp.isFinite ? features : nil
    }
}
