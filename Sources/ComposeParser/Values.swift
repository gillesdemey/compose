import ComposeModel
import Foundation
import Yams

// Node access, findings, and the small value formats compose embeds in strings.

extension FileParser {
    // MARK: - Nodes

    func mark(_ node: Node) -> SourceMark? {
        node.mark.map { SourceMark(line: $0.line, column: $0.column, file: displayName) }
    }

    func mapping(_ node: Node, path: String) throws -> Node.Mapping {
        guard let mapping = node.mapping else {
            throw ParseError(
                reason: .wrongShape,
                problem: path.isEmpty
                    ? "a compose file must be a mapping of top-level keys"
                    : "`\(path)` must be a mapping",
                mark: mark(node),
                path: path.isEmpty ? nil : path
            )
        }
        return mapping
    }

    func sequence(_ node: Node, path: String) throws -> [Node] {
        guard node.sequence != nil else {
            throw ParseError(reason: .wrongShape, problem: "`\(path)` must be a list", mark: mark(node), path: path)
        }
        return node.array()
    }

    /// A scalar, interpolated. Anything that is not a scalar is the wrong shape for a value.
    mutating func string(_ node: Node, path: String) throws -> String {
        guard let scalar = node.scalar?.string else {
            throw ParseError(
                reason: .wrongShape,
                problem: "`\(path)` must be a single value",
                mark: mark(node),
                path: path
            )
        }
        return try interpolator.expand(scalar, path: path, mark: mark(node), warnings: &warnings)
    }

    func validateName(_ name: String, kind: String, node: Node) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ParseError(
                reason: .wrongShape,
                problem: "`\(name)` is not a usable \(kind) name; use letters, digits, dots, dashes and underscores",
                mark: mark(node)
            )
        }
    }

    // MARK: - Findings

    mutating func note(key: String, service: String? = nil, node: Node, support: KeySupport) {
        findings.append(
            Finding(kind: .unhandledKey, key: key, service: service, support: support, mark: mark(node))
        )
    }

    mutating func noteUnknown(key: String, service: String? = nil, node: Node) {
        findings.append(
            Finding(
                kind: .unknownKey,
                key: key,
                service: service,
                support: .unsupported(
                    severity: .behavioural,
                    reason: "it may be a typo, or a key this implementation has never heard of"
                ),
                mark: mark(node)
            )
        )
    }

    mutating func noteForm(
        key: String,
        service: String? = nil,
        node: Node,
        severity: KeySeverity,
        reason: String
    ) {
        findings.append(
            Finding(
                kind: .unhandledForm,
                key: key,
                service: service,
                support: .deferred(severity: severity, reason: reason),
                mark: mark(node)
            )
        )
    }

    // MARK: - Extension values

    /// `x-` values are carried through as written. A quoted scalar stays a string even when it
    /// looks like a number, so that `x-thing: "1.0"` hashes the same on every run.
    func extensionValue(_ node: Node) -> ExtensionValue {
        if let mapping = node.mapping {
            var values: [String: ExtensionValue] = [:]
            for (keyNode, valueNode) in mapping {
                guard let key = keyNode.scalar?.string else { continue }
                values[key] = extensionValue(valueNode)
            }
            return .map(values)
        }
        if node.sequence != nil {
            return .list(node.array().map(extensionValue))
        }
        guard let scalar = node.scalar else { return .null }
        if scalar.style == .singleQuoted || scalar.style == .doubleQuoted {
            return .string(scalar.string)
        }
        if node.null != nil { return .null }
        if let value = node.bool { return .boolean(value) }
        if let value = node.float { return .number(value) }
        return .string(scalar.string)
    }

    // MARK: - Embedded value formats

    /// A `command:` or `entrypoint:` written as one string, split the way a shell would split
    /// it, honouring quotes. The list form never comes through here and never needs to.
    static func shellSplit(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var hasContent = false
        for character in text {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                hasContent = true
            case " ", "\t", "\n":
                if hasContent || !current.isEmpty {
                    arguments.append(current)
                    current = ""
                    hasContent = false
                }
            default:
                current.append(character)
                hasContent = true
            }
        }
        if hasContent || !current.isEmpty { arguments.append(current) }
        return arguments
    }

    /// Compose sizes: a number with an optional unit suffix, binary multiples throughout.
    static func memoryBytes(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let units: [(suffix: String, multiplier: Double)] = [
            ("gb", 1_073_741_824), ("mb", 1_048_576), ("kb", 1024),
            ("g", 1_073_741_824), ("m", 1_048_576), ("k", 1024), ("b", 1),
        ]
        for unit in units where trimmed.hasSuffix(unit.suffix) {
            let number = String(trimmed.dropLast(unit.suffix.count))
            guard let value = Double(number), value >= 0 else { return nil }
            return UInt64(value * unit.multiplier)
        }
        guard let value = Double(trimmed), value >= 0 else { return nil }
        return UInt64(value)
    }

    /// One side of a port mapping: a single port, or a range written `start-end`.
    static func portRange(_ text: String) -> ClosedRange<UInt16>? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            guard let port = UInt16(parts[0]) else { return nil }
            return port...port
        case 2:
            guard let lower = UInt16(parts[0]), let upper = UInt16(parts[1]), lower <= upper else { return nil }
            return lower...upper
        default:
            return nil
        }
    }
}
