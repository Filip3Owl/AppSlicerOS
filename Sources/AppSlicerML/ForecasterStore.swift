import Foundation

/// Saves and restores a `PressureForecaster` so learning continues across restarts.
public struct ForecasterStore: Sendable {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let state: PressureForecaster
    }

    /// Increase when `PressureForecaster`'s stored format or features change.
    private static let schemaVersion = 1

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/AppSlicerOS/pressure-forecaster.model.json`
    public static func defaultFileURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AppSlicerOS", isDirectory: true)
            .appendingPathComponent("pressure-forecaster.model.json")
    }

    /// Returns the saved forecaster, or a new one when there is no usable state.
    ///
    /// A model is cheap to relearn, so a missing, corrupted, outdated, or differently
    /// configured file must not stop the app. Other read failures, such as missing
    /// permissions, are thrown so that a later save does not replace a valid file.
    public func load(configuration: PressureForecaster.Configuration) throws -> PressureForecaster {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return PressureForecaster(configuration: configuration)
        }

        guard
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.schemaVersion == Self.schemaVersion,
            envelope.state.configuration == configuration,
            envelope.state.hasConsistentState
        else {
            return PressureForecaster(configuration: configuration)
        }
        return envelope.state
    }

    /// Writes atomically, so an interrupted save never leaves a partial file. The file is
    /// private to the current user because it reflects their usage patterns.
    public func save(_ forecaster: PressureForecaster) throws {
        let envelope = Envelope(schemaVersion: Self.schemaVersion, state: forecaster)
        let data = try JSONEncoder().encode(envelope)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
