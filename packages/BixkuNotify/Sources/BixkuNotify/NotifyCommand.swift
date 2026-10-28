import BixkuDock
import Foundation

/// Arguments of the `bixku-notify` command line helper. Kept in the library so the
/// parsing is tested; the executable only runs `open` on the resulting URL.
public struct NotifyCommand: Equatable, Sendable {
    public static let usage = """
        Usage: bixku-notify --title TEXT [--body TEXT] [--subtitle TEXT] [--app NAME]
                            [--category CATEGORY] [--thread ID] [--print]

        Sends a notification to the running Bixku Utilities Dock module by opening a
        bixku://notify URL. With --print the URL is written to stdout instead of opened.

        Categories: \(NotificationCategory.allCases.map(\.rawValue).joined(separator: ", "))
        """

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case helpRequested
        case missingValue(String)
        case unknownOption(String)
        case invalidCategory(String)
        case invalidNotification(NotifyURLError)

        public var description: String {
            switch self {
            case .helpRequested: return NotifyCommand.usage
            case .missingValue(let option): return "option \(option) needs a value"
            case .unknownOption(let option): return "unknown option \(option)"
            case .invalidCategory(let value): return "unknown category \(value)"
            case .invalidNotification(let error): return error.description
            }
        }
    }

    public var url: URL
    /// Print the URL instead of opening it.
    public var printOnly: Bool

    /// Default sender name, so the digest does not list "Unknown app".
    public static let defaultApp = "bixku-notify"

    public static func parse(_ arguments: [String]) -> Result<NotifyCommand, ParseError> {
        var title: String?
        var body: String?
        var subtitle: String?
        var app: String? = defaultApp
        var category: NotificationCategory?
        var thread: String?
        var printOnly = false

        var iterator = arguments.makeIterator()
        while let option = iterator.next() {
            switch option {
            case "-h", "--help":
                return .failure(.helpRequested)
            case "--print":
                printOnly = true
            case "--title", "--body", "--subtitle", "--app", "--category", "--thread":
                guard let value = iterator.next() else { return .failure(.missingValue(option)) }
                switch option {
                case "--title": title = value
                case "--body": body = value
                case "--subtitle": subtitle = value
                case "--app": app = value
                case "--thread": thread = value
                default:
                    guard let parsed = NotificationCategory(rawValue: value.lowercased()) else {
                        return .failure(.invalidCategory(value))
                    }
                    category = parsed
                }
            default:
                return .failure(.unknownOption(option))
            }
        }

        guard let url = NotifyURL.make(
            title: title ?? "", body: body, subtitle: subtitle, app: app, category: category, thread: thread
        ) else { return .failure(.invalidNotification(.malformed)) }

        // Same validation the app applies, so mistakes show up here and not silently there.
        if case .failure(let error) = NotifyURL.parse(url) {
            return .failure(.invalidNotification(error))
        }
        return .success(NotifyCommand(url: url, printOnly: printOnly))
    }
}
