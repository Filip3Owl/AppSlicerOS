import AppSlicerMetrics
import Foundation

@main
struct CollectorMain {
    static func main() {
        do {
            let options = try CollectorOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            try run(options)
        } catch CollectorOptions.ParseError.helpRequested {
            write(CollectorOptions.usage + "\n", to: .standardOutput)
        } catch CollectorOptions.ParseError.invalid(let message) {
            write("error: \(message)\n\n\(CollectorOptions.usage)\n", to: .standardError)
            exit(64)
        } catch {
            write("error: could not read memory metrics: \(error)\n", to: .standardError)
            exit(1)
        }
    }

    private static func run(_ options: CollectorOptions) throws {
        let systemReader = try SystemMemoryReader()
        let processReader = ProcessMemoryReader()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        var previous: MemorySnapshot?
        var readings = 0
        while options.count.map({ readings < $0 }) ?? true {
            if readings > 0 {
                Thread.sleep(forTimeInterval: options.interval)
            }
            let snapshot = try systemReader.read()
            let report = options.top > 0 ? try processReader.readTopProcesses(limit: options.top) : nil
            let output = ReportFormatter.format(
                time: timeFormatter.string(from: snapshot.timestamp),
                snapshot: snapshot,
                pageoutsPerSecond: previous.flatMap { snapshot.pageoutsPerSecond(since: $0) },
                report: report
            )
            write(output + "\n\n", to: .standardOutput)
            previous = snapshot
            readings += 1
        }
    }

    private static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data(text.utf8))
    }
}
