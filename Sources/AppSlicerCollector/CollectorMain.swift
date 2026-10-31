import AppSlicerHistory
import AppSlicerMetrics
import AppSlicerML
import Foundation

@main
struct CollectorMain {
    @MainActor
    static func main() {
        do {
            let options = try CollectorOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            try CollectorRunner(options: options).start()
        } catch CollectorOptions.ParseError.helpRequested {
            Console.write(CollectorOptions.usage + "\n", to: .standardOutput)
            exit(0)
        } catch CollectorOptions.ParseError.invalid(let message) {
            Console.write("error: \(message)\n\n\(CollectorOptions.usage)\n", to: .standardError)
            exit(64)
        } catch {
            Console.write("error: could not start the collector: \(error)\n", to: .standardError)
            exit(1)
        }
        dispatchMain()
    }
}

enum Console {
    static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data(text.utf8))
    }
}

/// Runs entirely on the main queue, so readings, saves, and signals never overlap.
@MainActor
private final class CollectorRunner {
    private static let saveInterval: TimeInterval = 300

    private let options: CollectorOptions
    private let systemReader: SystemMemoryReader
    private let processReader = ProcessMemoryReader()
    private let modelFile: URL
    private let timeFormatter = DateFormatter()
    private var session: LiveForecastSession
    private var history: HistoryRecorder
    private var historyIsFailing = false
    private let historyFile: URL
    private var previous: MemorySnapshot?
    private var readings = 0
    private var sources: [any DispatchSourceProtocol] = []

    init(options: CollectorOptions) throws {
        self.options = options
        systemReader = try SystemMemoryReader()
        modelFile = try options.modelFile.map { URL(fileURLWithPath: $0) } ?? ForecasterStore.defaultFileURL()
        session = try LiveForecastSession(
            store: ForecasterStore(fileURL: modelFile),
            saveInterval: Self.saveInterval,
            now: Date()
        )
        historyFile = try options.historyFile.map { URL(fileURLWithPath: $0) } ?? HistoryStore.defaultFileURL()
        history = HistoryRecorder(store: try HistoryStore(fileURL: historyFile))
        timeFormatter.dateFormat = "HH:mm:ss"
    }

    func start() {
        Console.write(
            "model file: \(modelFile.path)\nhistory file: \(historyFile.path)\n\n",
            to: .standardOutput
        )
        observe(signalNumber: SIGINT)
        observe(signalNumber: SIGTERM)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: options.interval,
            leeway: .milliseconds(Int(options.interval * 100))
        )
        timer.setEventHandler { [self] in
            MainActor.assumeIsolated { takeReading() }
        }
        timer.resume()
        sources.append(timer)
    }

    private func observe(signalNumber: Int32) {
        // Ignoring the default action lets the dispatch source handle the signal instead.
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { [self] in
            MainActor.assumeIsolated { () -> Void in finish(exitCode: 0) }
        }
        source.resume()
        sources.append(source)
    }

    private func takeReading() {
        do {
            let snapshot = try systemReader.read()
            let report = options.top > 0 ? try processReader.readTopProcesses(limit: options.top) : nil
            let rate = previous.flatMap { snapshot.pageoutsPerSecond(since: $0) }
            let forecast = session.observe(snapshot: snapshot, pageoutsPerSecond: rate)
            let output = ReportFormatter.format(
                time: timeFormatter.string(from: snapshot.timestamp),
                snapshot: snapshot,
                pageoutsPerSecond: rate,
                forecast: forecast,
                report: report
            )
            Console.write(output + "\n\n", to: .standardOutput)
            previous = snapshot
            readings += 1
            saveIfDue()
            record(snapshot, pageoutsPerSecond: rate)
        } catch {
            Console.write("error: could not read memory metrics: \(error)\n", to: .standardError)
            finish(exitCode: 1)
        }

        if let count = options.count, readings >= count {
            finish(exitCode: 0)
        }
    }

    /// A failed periodic save only delays persistence, so the collector keeps running.
    private func saveIfDue() {
        do {
            try session.saveIfDue(now: Date())
        } catch {
            Console.write("warning: could not save the model: \(error)\n", to: .standardError)
        }
    }

    /// A failed write loses one reading, so the collector keeps running. It warns once per
    /// failure period, because readings can arrive every few seconds.
    private func record(_ snapshot: MemorySnapshot, pageoutsPerSecond: Double?) {
        do {
            try history.record(snapshot, pageoutsPerSecond: pageoutsPerSecond, now: snapshot.timestamp)
            historyIsFailing = false
        } catch {
            if !historyIsFailing {
                Console.write("warning: could not update the history: \(error)\n", to: .standardError)
            }
            historyIsFailing = true
        }
    }

    private func finish(exitCode: Int32) -> Never {
        do {
            try session.save()
            exit(exitCode)
        } catch {
            Console.write("error: could not save the model: \(error)\n", to: .standardError)
            exit(1)
        }
    }
}
