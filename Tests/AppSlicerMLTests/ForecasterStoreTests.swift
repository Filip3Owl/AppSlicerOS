import Foundation
import Testing
@testable import AppSlicerML

@Suite struct ForecasterStoreTests {
    private let directory: URL
    private let store: ForecasterStore
    private let configuration: PressureForecaster.Configuration

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSlicerOSTests-\(UUID().uuidString)", isDirectory: true)
        store = ForecasterStore(fileURL: directory.appendingPathComponent("nested/model.json"))

        var configuration = PressureForecaster.Configuration()
        configuration.horizon = 30
        configuration.minimumExamplesPerClass = 5
        self.configuration = configuration
    }

    private func sample(step: Int) -> MemorySample {
        let phase = step % 40
        return MemorySample(
            timestamp: Double(step) * 5,
            usedFraction: 0.5 + Double(phase) * 0.01,
            compressedFraction: 0.1 + Double(phase) * 0.005,
            swapUsedFraction: 0.1 + Double(phase) * 0.01,
            pageoutsPerSecond: Double(phase),
            isPressureElevated: phase >= 34
        )
    }

    private func trainedForecaster(steps: Int = 400) -> PressureForecaster {
        var forecaster = PressureForecaster(configuration: configuration)
        for step in 0..<steps {
            _ = forecaster.observe(sample(step: step))
        }
        return forecaster
    }

    private func writeFile(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: store.fileURL)
    }

    private func expectFreshForecaster() throws {
        let loaded = try store.load(configuration: configuration)
        #expect(loaded.positiveExampleCount == 0)
        #expect(loaded.negativeExampleCount == 0)
        #expect(!loaded.isReady)
    }

    @Test func restoredForecasterContinuesExactlyLikeTheOriginal() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = trainedForecaster()
        #expect(original.isReady)
        try store.save(original)
        var restored = try store.load(configuration: configuration)

        #expect(restored.positiveExampleCount == original.positiveExampleCount)
        #expect(restored.negativeExampleCount == original.negativeExampleCount)
        #expect(restored.pendingExampleCount == original.pendingExampleCount)

        for step in 400..<600 {
            let forecast = restored.observe(sample(step: step))
            #expect(forecast != nil)
            #expect(forecast == original.observe(sample(step: step)))
        }
    }

    @Test func keepsLearningButDropsPendingOutcomesAfterALongRestart() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = trainedForecaster()
        try store.save(original)
        var restored = try store.load(configuration: configuration)

        var later = sample(step: 400)
        later.timestamp += 86_400
        #expect(restored.observe(later) != nil)
        #expect(restored.pendingExampleCount == 1)
        #expect(restored.positiveExampleCount == original.positiveExampleCount)
        #expect(restored.negativeExampleCount == original.negativeExampleCount)
    }

    @Test func startsFreshWithoutAFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try expectFreshForecaster()
    }

    @Test func startsFreshWhenFileIsCorrupted() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(Data("{ not json".utf8))
        try expectFreshForecaster()
    }

    @Test func startsFreshWhenSchemaVersionDiffers() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(trainedForecaster())
        var object = try savedObject()
        object["schemaVersion"] = 999
        try writeFile(JSONSerialization.data(withJSONObject: object))
        try expectFreshForecaster()
    }

    @Test func startsFreshWhenConfigurationDiffers() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(trainedForecaster())
        var otherConfiguration = configuration
        otherConfiguration.horizon = 60
        let loaded = try store.load(configuration: otherConfiguration)
        #expect(loaded.configuration == otherConfiguration)
        #expect(loaded.positiveExampleCount == 0)
    }

    @Test func startsFreshInsteadOfCrashingOnWrongFeatureCount() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(trainedForecaster())
        var object = try savedObject()
        var state = try #require(object["state"] as? [String: Any])
        var model = try #require(state["model"] as? [String: Any])
        model["weights"] = [1.0]
        state["model"] = model
        object["state"] = state
        try writeFile(JSONSerialization.data(withJSONObject: object))
        try expectFreshForecaster()
    }

    @Test func throwsOnReadFailuresOtherThanAMissingFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            _ = try store.load(configuration: configuration)
        }
    }

    @Test func savedFileIsPrivateAndLeavesNoTemporaryFiles() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(trainedForecaster())
        try store.save(trainedForecaster(steps: 500))

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: store.fileURL.deletingLastPathComponent().path
        )
        #expect(files == ["model.json"])
    }

    @Test func defaultFileMatchesTheGitignoredModelPattern() throws {
        let url = try ForecasterStore.defaultFileURL()
        #expect(url.lastPathComponent.hasSuffix(".model.json"))
        #expect(url.path.contains("/Application Support/AppSlicerOS/"))
    }

    private func savedObject() throws -> [String: Any] {
        let data = try Data(contentsOf: store.fileURL)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
