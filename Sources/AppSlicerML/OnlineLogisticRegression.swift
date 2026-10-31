import Foundation

/// Binary classifier trained one example at a time with AdaGrad and L2 regularization.
public struct OnlineLogisticRegression: Codable, Sendable {
    public private(set) var weights: [Double]
    public private(set) var bias = 0.0

    private let learningRate: Double
    private let l2: Double
    private var weightGradientSums: [Double]
    private var biasGradientSum = 0.0

    public init(featureCount: Int, learningRate: Double = 0.1, l2: Double = 1e-4) {
        weights = Array(repeating: 0, count: featureCount)
        weightGradientSums = Array(repeating: 0, count: featureCount)
        self.learningRate = learningRate
        self.l2 = l2
    }

    func hasFeatureCount(_ featureCount: Int) -> Bool {
        weights.count == featureCount && weightGradientSums.count == featureCount
    }

    public func probability(_ features: [Double]) -> Double {
        precondition(features.count == weights.count, "feature count mismatch")
        var logit = bias
        for index in features.indices {
            logit += weights[index] * features[index]
        }
        return 1 / (1 + exp(-logit))
    }

    public mutating func update(_ features: [Double], label: Bool) {
        let error = probability(features) - (label ? 1 : 0)
        for index in features.indices {
            let gradient = error * features[index] + l2 * weights[index]
            weightGradientSums[index] += gradient * gradient
            weights[index] -= step(gradient, gradientSum: weightGradientSums[index])
        }
        biasGradientSum += error * error
        bias -= step(error, gradientSum: biasGradientSum)
    }

    private func step(_ gradient: Double, gradientSum: Double) -> Double {
        gradientSum > 0 ? learningRate * gradient / gradientSum.squareRoot() : 0
    }
}
