import Foundation

/// Everything the plugin prints.
///
/// A CLI in a script has nobody to ask, so the rules are simple: what is about to happen goes
/// to stdout as it happens, and anything that stops the run goes to stderr. Colour only when a
/// terminal is on the other end.
enum Output {
    private static let isTerminal = isatty(STDOUT_FILENO) == 1

    private static func styled(_ text: String, _ code: String) -> String {
        isTerminal ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ text: String) -> String { styled(text, "1") }
    static func dim(_ text: String) -> String { styled(text, "2") }
    static func red(_ text: String) -> String { styled(text, "31") }
    static func yellow(_ text: String) -> String { styled(text, "33") }

    /// Written rather than printed: stdout is block buffered when it is a pipe, and a plugin
    /// that reports each step as it happens has to report it as it happens.
    static func line(_ text: String = "") {
        FileHandle.standardOutput.write(Data("\(text)\n".utf8))
    }

    /// A note about the file that does not stop the run.
    static func note(_ text: String) {
        line(dim(text))
    }

    static func warning(_ text: String) {
        line("\(yellow("warning:")) \(text)")
    }

    /// One step of a plan, numbered so a long run reads as progress.
    static func step(_ index: Int, of total: Int, _ text: String) {
        let width = String(total).count
        let number = String(index).leftPadded(to: width)
        line("\(dim("[\(number)/\(total)]")) \(text)")
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data("\(red("error:")) \(text)\n".utf8))
    }

    /// Errors that carry a list of reasons, which is most of the interesting ones.
    static func error(_ text: String, details: [String]) {
        error(text)
        for detail in details {
            FileHandle.standardError.write(Data("  \(detail)\n".utf8))
        }
    }

    /// A warning for a command whose stdout is data, such as `config`, where anything else
    /// written there would corrupt what a pipe receives.
    static func warningToStandardError(_ text: String, details: [String] = []) {
        FileHandle.standardError.write(Data("\(yellow("warning:")) \(text)\n".utf8))
        for detail in details {
            FileHandle.standardError.write(Data("  \(detail)\n".utf8))
        }
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }

    func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

/// An error already written for a person to read. Thrown once the message is settled, so that
/// nothing below the command layer has to know how errors are printed.
struct ComposeError: Error, CustomStringConvertible, LocalizedError {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var description: String { text }
    var errorDescription: String? { text }
}
