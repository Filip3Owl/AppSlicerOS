import Foundation

struct CollectorOptions: Equatable {
    static let usage = """
    Usage: appslicer-collector [options]

    Prints live memory metrics. Nothing is stored or sent anywhere.

    Options:
      --interval <seconds>  Time between readings, at least 0.5 (default: 2)
      --top <count>         Processes to list, 0 or more (default: 5)
      --count <readings>    Stop after this many readings (default: run until Ctrl-C)
      --help                Show this message
    """

    enum ParseError: Error, Equatable {
        case helpRequested
        case invalid(String)
    }

    var interval: TimeInterval = 2
    var top = 5
    var count: Int?

    init() {}

    init(arguments: [String]) throws {
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--help", "-h":
                throw ParseError.helpRequested
            case "--interval":
                guard let value = remaining.popFirst().flatMap(TimeInterval.init),
                      value.isFinite, value >= 0.5
                else { throw ParseError.invalid("--interval must be a number of at least 0.5") }
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
            default:
                throw ParseError.invalid("unknown option \(argument)")
            }
        }
    }
}
