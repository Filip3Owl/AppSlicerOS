/// Flags values far from an exponentially weighted mean of a metric's recent history.
public struct EWMAAnomalyDetector: Codable, Sendable {
    public struct Result: Equatable, Sendable {
        public let zScore: Double
        public let isAnomaly: Bool
    }

    private let alpha: Double
    private let threshold: Double
    private let warmupCount: Int
    private let minimumDeviation: Double
    private var count = 0
    private var mean = 0.0
    private var variance = 0.0

    /// - Parameter minimumDeviation: Floor that stops tiny fluctuations in a flat metric
    ///   from producing huge z-scores. Use the smallest change that matters for the metric.
    public init(
        alpha: Double = 0.1,
        threshold: Double = 3,
        warmupCount: Int = 30,
        minimumDeviation: Double = 1e-6
    ) {
        precondition(alpha > 0 && alpha <= 1, "alpha must be in (0, 1]")
        self.alpha = alpha
        self.threshold = threshold
        self.warmupCount = warmupCount
        self.minimumDeviation = minimumDeviation
    }

    /// Scores the value against prior history, then adds it to that history.
    public mutating func update(_ value: Double) -> Result {
        guard count > 0 else {
            mean = value
            count = 1
            return Result(zScore: 0, isAnomaly: false)
        }

        let delta = value - mean
        let zScore = delta / max(variance.squareRoot(), minimumDeviation)
        let isAnomaly = count >= warmupCount && abs(zScore) >= threshold

        mean += alpha * delta
        variance = (1 - alpha) * (variance + alpha * delta * delta)
        count += 1
        return Result(zScore: zScore, isAnomaly: isAnomaly)
    }
}
