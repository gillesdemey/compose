import ComposeModel
import Yams

/// A file this implementation will not read: malformed YAML, a shape the spec does not allow,
/// or a file written against a version of compose that is no longer the specification.
///
/// Errors are thrown; keys that are merely not honoured come back as findings instead, because
/// the two front ends answer those differently and neither should be answering them here.
public struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Why the file was rejected, kept separate from the message so callers can branch on it.
    public enum Reason: String, Sendable, Equatable {
        /// libYAML could not read the document at all.
        case malformedYAML
        /// A key holds a scalar where a mapping belongs, or similar.
        case wrongShape
        /// A version 2 file, which is understood well enough to be refused clearly.
        case unsupportedSpecVersion
        /// A value that cannot mean anything: a port outside 16 bits, an unparseable size.
        case invalidValue
        /// A reference to a service, network or volume the file never declares.
        case undefinedReference
        /// A required key is absent: no services, or a service with neither image nor build.
        case missingKey
        /// `${VAR:?message}` with the variable unset.
        case requiredVariableUnset
        /// An `env_file`, `include` or `extends` file the disk does not have.
        case unreadableFile
        /// Two files reached through `include` define the same name differently.
        case conflictingDefinition
        /// An `include` or `extends` chain that leads back to where it started.
        case circularReference
    }

    public let reason: Reason
    /// What went wrong, in one sentence, without the location.
    public let problem: String
    /// Where in the file, one-based, when the YAML node carried a mark.
    public let mark: SourceMark?
    /// The dotted path to the offending node: `services.web.ports[0]`.
    public let path: String?

    public init(reason: Reason, problem: String, mark: SourceMark? = nil, path: String? = nil) {
        self.reason = reason
        self.problem = problem
        self.mark = mark
        self.path = path
    }

    /// The line a front end prints: location, path, problem.
    public var description: String {
        var text = ""
        if let mark { text += "\(mark): " }
        text += problem
        if let path { text += " (at \(path))" }
        return text
    }

    /// Wrap a libYAML failure, keeping its mark so the location survives.
    static func yaml(_ error: YamlError, file: String? = nil) -> ParseError {
        switch error {
        case let .scanner(_, problem, mark, _), let .parser(_, problem, mark, _), let .composer(_, problem, mark, _):
            return ParseError(
                reason: .malformedYAML,
                problem: problem,
                mark: SourceMark(line: mark.line, column: mark.column, file: file)
            )
        default:
            let problem = String(describing: error)
            return ParseError(reason: .malformedYAML, problem: file.map { "`\($0)`: \(problem)" } ?? problem)
        }
    }
}

/// A `${VAR}` that expanded to nothing because the variable was not set anywhere.
///
/// Compose substitutes an empty string and carries on, which is the behaviour to match, but
/// an empty string where a password or a tag belonged is worth saying out loud.
public struct InterpolationWarning: Sendable, Equatable, Hashable, Identifiable {
    public let variable: String
    /// The dotted path to the value the variable appeared in.
    public let path: String
    public let mark: SourceMark?

    public init(variable: String, path: String, mark: SourceMark? = nil) {
        self.variable = variable
        self.path = path
        self.mark = mark
    }

    public var id: String { "\(variable)@\(path)" }

    public var message: String {
        var text = ""
        if let mark { text += "\(mark.line):\(mark.column): " }
        text += "`\(variable)` is not set, so `\(path)` used an empty string"
        return text
    }
}

/// Everything a parse produces: the file, what will not be honoured, and what expanded to
/// nothing.
public struct ParseResult: Sendable {
    public let file: ComposeFile
    public let findings: [Finding]
    public let interpolationWarnings: [InterpolationWarning]

    public init(file: ComposeFile, findings: [Finding], interpolationWarnings: [InterpolationWarning]) {
        self.file = file
        self.findings = findings
        self.interpolationWarnings = interpolationWarnings
    }

    /// Findings a caller should not proceed past without asking someone.
    ///
    /// This is a command-line front end's cue to refuse the file: no terminal caller gets to
    /// answer the question, so a key that changes runtime behaviour has to be an error there.
    /// A front end with a window can show the same list and let a person decide. Cosmetic
    /// findings never block: refusing a file over `version: "3.8"` would be absurd.
    public var blockingFindings: [Finding] {
        findings.filter { $0.severity == .behavioural }
    }
}
