/// What a compose key costs to ignore.
///
/// The distinction matters because the two front ends report differently and a user has to
/// judge whether to proceed. Dropping `restart` changes what happens when a container dies;
/// dropping a cosmetic key changes nothing anyone can observe.
public enum KeySeverity: String, Sendable, Comparable, CaseIterable {
    /// Ignoring the key changes nothing observable about the running services.
    case cosmetic
    /// Ignoring the key changes runtime behaviour, and the user will notice eventually.
    case behavioural

    private var rank: Int {
        switch self {
        case .cosmetic: return 0
        case .behavioural: return 1
        }
    }

    public static func < (lhs: KeySeverity, rhs: KeySeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// How this implementation treats a given compose key.
public enum KeySupport: Sendable, Hashable {
    /// Honoured in full.
    case supported
    /// Understood, not implemented yet, and expected to be.
    case deferred(severity: KeySeverity, reason: String)
    /// No path to implementing it until the runtime underneath grows a feature.
    case unsupported(severity: KeySeverity, reason: String)

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    public var severity: KeySeverity? {
        switch self {
        case .supported: return nil
        case .deferred(let severity, _), .unsupported(let severity, _): return severity
        }
    }

    public var reason: String? {
        switch self {
        case .supported: return nil
        case .deferred(_, let reason), .unsupported(_, let reason): return reason
        }
    }

    /// Whether honouring this needs a feature the runtime underneath does not have.
    ///
    /// The difference is the first thing anyone reading a list of what will not happen wants
    /// to know. A key that is merely not implemented here yet is a promise someone can chase;
    /// a key the runtime cannot support is not this project's to fix, and no amount of work
    /// here will change it.
    public var needsRuntimeSupport: Bool {
        if case .unsupported = self { return true }
        return false
    }

    /// Understood, and not implemented here yet.
    public var isDeferred: Bool {
        if case .deferred = self { return true }
        return false
    }
}

/// The v1 coverage table: every compose key this implementation knows the name of, and what
/// it does with it. A key absent from the table is unknown rather than unsupported, which is
/// reported differently because it is as likely to be a typo as a real compose feature.
public enum KeySupportTable {
    /// Keys valid at the top level of a compose file.
    public static let topLevel: [String: KeySupport] = [
        "name": .supported,
        "services": .supported,
        "networks": .supported,
        "volumes": .supported,
        "version": .deferred(
            severity: .cosmetic,
            reason: "the Compose Specification dropped the version key; it is read and ignored"
        ),
        "configs": .unsupported(
            severity: .behavioural,
            reason: "container has no config mounting"
        ),
        "secrets": .unsupported(
            severity: .behavioural,
            reason: "container has no secret mounting"
        ),
        "include": .supported,
    ]

    /// Keys valid under a single service.
    public static let service: [String: KeySupport] = [
        "image": .supported,
        "build": .supported,
        "extends": .supported,
        "container_name": .supported,
        "command": .supported,
        "environment": .supported,
        "env_file": .supported,
        "working_dir": .supported,
        "ports": .supported,
        "volumes": .supported,
        "labels": .supported,
        "networks": .supported,
        "deploy": .supported,
        "depends_on": .supported,
        "entrypoint": .supported,
        "user": .supported,
        "tmpfs": .supported,
        // Probed by `up` for whatever waits on the service with `service_healthy`. Nothing
        // reports health once `up` has returned, and nothing needs to: compose only acts on
        // it while bringing a project up.
        "healthcheck": .supported,
        "pull_policy": .deferred(
            severity: .cosmetic,
            reason: "an image is pulled when it is not already here; `always` and `never` are not honoured"
        ),
        "platform": .deferred(
            severity: .cosmetic,
            reason: "every container on this stack is linux/arm64 today"
        ),
        "profiles": .deferred(
            severity: .behavioural,
            reason: "selecting a subset of services is not implemented yet"
        ),
        // Value-dependent, and handled in the parser rather than read from here: `restart: no`
        // is what happens anyway, so only a policy that asks for more than nothing is reported.
        "restart": .unsupported(
            severity: .behavioural,
            reason: "container has no restart policy; a container that exits stays exited"
        ),
        "cap_add": .unsupported(severity: .behavioural, reason: "capabilities are not settable"),
        "cap_drop": .unsupported(severity: .behavioural, reason: "capabilities are not settable"),
        "devices": .unsupported(severity: .behavioural, reason: "device passthrough is not available"),
        "ulimits": .unsupported(severity: .behavioural, reason: "resource limits are not settable"),
        "secrets": .unsupported(severity: .behavioural, reason: "container has no secret mounting"),
        "configs": .unsupported(severity: .behavioural, reason: "container has no config mounting"),
        "extra_hosts": .unsupported(severity: .behavioural, reason: "the hosts file is not writable at create"),
        "dns": .supported,
        "dns_search": .supported,
        "dns_opt": .supported,
        "privileged": .unsupported(severity: .behavioural, reason: "there is no privileged mode"),
        "network_mode": .unsupported(severity: .behavioural, reason: "only user-defined networks are attachable"),
        "stdin_open": .unsupported(severity: .cosmetic, reason: "attaching to a started container is not planned here"),
        "tty": .unsupported(severity: .cosmetic, reason: "attaching to a started container is not planned here"),
    ]

    /// Extension keys are reserved for tools and carried through untouched.
    public static func isExtensionKey(_ key: String) -> Bool {
        key.hasPrefix("x-")
    }
}

/// A point in a source file, one-based, as libYAML counts them.
public struct SourceMark: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let line: Int
    public let column: Int
    /// The file the point is in, when it is not the file the parse started from: one reached
    /// through `include` or `extends`. Relative to the starting file's directory when it sits
    /// under it, absolute otherwise. `nil` means the starting file, whose name the caller
    /// already has.
    public let file: String?

    public init(line: Int, column: Int, file: String? = nil) {
        self.line = line
        self.column = column
        self.file = file
    }

    public var description: String {
        if let file { return "\(file):\(line):\(column)" }
        return "\(line):\(column)"
    }
}

/// Something in the file this implementation will not act on, recorded rather than dropped.
///
/// Findings are returned from a parse instead of thrown, because the right response differs
/// between front ends: a command refuses a file carrying any of them, since nobody is there to
/// ask, while a front end with a window can show the list and let the user decide.
public struct Finding: Sendable, Equatable, Identifiable, Hashable {
    /// Why a key is being reported.
    public enum Kind: String, Sendable, Hashable {
        /// A key this implementation knows and does not honour.
        case unhandledKey
        /// A key no version of the Compose Specification defines.
        case unknownKey
        /// A key that is honoured, but not in the form this file uses.
        case unhandledForm
    }

    public let kind: Kind
    /// The key as written, dotted for nesting: `deploy.replicas`.
    public let key: String
    /// The service the key sits under, or `nil` for a top-level key.
    public let service: String?
    public let support: KeySupport
    public let mark: SourceMark?
    /// Extra context for `.unhandledForm`, where the key alone does not explain the problem.
    public let detail: String?

    public init(
        kind: Kind,
        key: String,
        service: String? = nil,
        support: KeySupport,
        mark: SourceMark? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.key = key
        self.service = service
        self.support = support
        self.mark = mark
        self.detail = detail
    }

    public var id: String {
        "\(kind.rawValue):\(service ?? "")/\(key)@\(mark?.description ?? "")"
    }

    public var severity: KeySeverity {
        support.severity ?? .cosmetic
    }

    /// A single line naming the key, the service and the line, which is what both front ends
    /// have to show and the plugin has to print.
    public var message: String {
        var text = ""
        if let mark { text += "\(mark): " }
        text += "`\(key)`"
        if let service { text += " in service `\(service)`" }
        switch kind {
        case .unhandledKey:
            text += " is not honoured"
        case .unknownKey:
            text += " is not a compose key"
        case .unhandledForm:
            text += " is not honoured in this form"
        }
        if let reason = detail ?? support.reason { text += ": \(reason)" }
        return text
    }
}
