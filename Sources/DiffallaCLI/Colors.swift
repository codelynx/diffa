import Foundation

/// Simple ANSI color support for terminal output
enum Colors {
    /// Check if colors should be enabled
    static var enabled: Bool {
        // Respect NO_COLOR environment variable
        guard ProcessInfo.processInfo.environment["NO_COLOR"] == nil else {
            return false
        }

        // Check if stdout is a TTY
        return isatty(STDOUT_FILENO) != 0
    }

    /// Apply color to text
    static func colored(_ text: String, color: Color) -> String {
        guard enabled else { return text }
        return "\(color.code)\(text)\(Color.reset.code)"
    }

    /// Success messages (green)
    static func success(_ text: String) -> String {
        colored(text, color: .green)
    }

    /// Error messages (red)
    static func error(_ text: String) -> String {
        colored(text, color: .red)
    }

    /// Warning messages (yellow)
    static func warning(_ text: String) -> String {
        colored(text, color: .yellow)
    }

    /// Info messages (blue)
    static func info(_ text: String) -> String {
        colored(text, color: .blue)
    }

    /// Dim/muted text (gray)
    static func dim(_ text: String) -> String {
        colored(text, color: .gray)
    }

    /// ANSI color codes
    enum Color {
        case reset
        case green
        case red
        case yellow
        case blue
        case gray

        var code: String {
            switch self {
            case .reset: return "\u{001B}[0m"
            case .green: return "\u{001B}[32m"
            case .red: return "\u{001B}[31m"
            case .yellow: return "\u{001B}[33m"
            case .blue: return "\u{001B}[34m"
            case .gray: return "\u{001B}[90m"
            }
        }
    }
}
