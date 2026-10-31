/// Incremental per-feature z-score normalization using Welford's algorithm.
public struct RunningStandardizer: Codable, Sendable {
    public private(set) var count = 0
    private var means: [Double]
    private var squaredDeviations: [Double]

    public init(featureCount: Int) {
        means = Array(repeating: 0, count: featureCount)
        squaredDeviations = Array(repeating: 0, count: featureCount)
    }

    func hasFeatureCount(_ featureCount: Int) -> Bool {
        means.count == featureCount && squaredDeviations.count == featureCount
    }

    public mutating func update(_ features: [Double]) {
        precondition(features.count == means.count, "feature count mismatch")
        count += 1
        for index in features.indices {
            let delta = features[index] - means[index]
            means[index] += delta / Double(count)
            squaredDeviations[index] += delta * (features[index] - means[index])
        }
    }

    /// Features without observed variance map to zero, since they carry no signal yet.
    public func transform(_ features: [Double]) -> [Double] {
        precondition(features.count == means.count, "feature count mismatch")
        guard count > 1 else { return Array(repeating: 0, count: features.count) }
        return features.indices.map { index in
            let variance = squaredDeviations[index] / Double(count - 1)
            return variance > 0 ? (features[index] - means[index]) / variance.squareRoot() : 0
        }
    }
}
