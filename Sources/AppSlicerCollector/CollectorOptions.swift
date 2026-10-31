import Foundation

struct CollectorOptions: Equatable {
    static let usage = """
    Usage: appslicer-collector [options]

    Prints live memory metrics and forecasts, while the model learns from each reading.
    The model is saved on this Mac every 5 minutes and on exit, and each reading is added to
    a local history without app names. Nothing is sent anywhere.

    Options:
      --interval <seconds>  Time between readings, from 0.5 to 30 (default: 2)
      --top <count>         Processes to list, 0 or more (default: 5)
      --count <readings>    Stop after this many readings (default: run until Ctrl-C)
      --model-file <path>   Where to keep the model
                            (default: ~/Library/Application Support/AppSlicerOS/)
      --history-file <path> Where to keep the history (default: same folder as the model)
      --help                Show this message
    """

    enum ParseError: Error, Equatable {
        case helpRequested
        case invalid(String)
    }

    var interval: TimeInterval = 2
    var top = 5
    var count: Int?
    var modelFile: String?
    var historyFile: String?

    init() {}

    init(arguments: [String]) throws {
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--help", "-h":
                throw ParseError.helpRequested
            case "--interval":
                guard let value = remaining.popFirst().flatMap(TimeInterval.init),
                      // The upper limit stays well below the forecaster's maximum sample
                      // gap. Beyond that gap, every reading would discard pending outcomes.
                      value >= 0.5, value <= 30
                else { throw ParseError.invalid("--interval must be a number from 0.5 to 30") }
                interval = value
            case "--top":
                guard let value = remaining.popFirst().flatMap({ Int($0) }), value >= 0 else {
                    throw ParseError.invalid("--top must be a whole number of 0 or more")
                }
                top = value
            case "--count":
                guard let value = remaining.popFirst().flatMap({ Int($0) }), value >= 1 else {
                    throw ParseError.invalid("--count must be a whole number of 1 or more")
                }
                count = value
            case "--model-file":
                guard let value = remaining.popFirst(), !value.isEmpty, !value.hasPrefix("--") else {
                    throw ParseError.invalid("--model-file must be followed by a file path")
                }
                modelFile = value
            case "--history-file":
                guard let value = remaining.popFirst(), !value.isEmpty, !value.hasPrefix("--") else {
                    throw ParseError.invalid("--history-file must be followed by a file path")
                }
                historyFile = value
            default:
                throw ParseError.invalid("unknown option \(argument)")
            }
        }
    }
}
