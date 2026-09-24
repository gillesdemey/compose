import ComposeModel
import Foundation
import Yams

/// One file's say on a service, before any of it is settled.
///
/// A service reached through `extends`, or named by more than one file in an `include` path
/// list, is built from several of these. Unset stays unset here, so that a merge can tell a
/// file that did not mention a key from one that wrote the default.
struct ServiceLayer {
    struct Build {
        /// Already resolved against the directory of the file that wrote it.
        var context: String?
        /// Where a `build:` without a context points: the directory of the file that wrote it.
        var defaultContext: String
        var dockerfile: String?
        var args: [String: String] = [:]
        var target: String?

        init(context: String? = nil, defaultContext: String) {
            self.context = context
            self.defaultContext = defaultContext
        }
    }

    /// Merged field by field, as compose merges it, so every field stays unset until written.
    struct Healthcheck {
        var test: [String]?
        var disabled: Bool?
        var interval: Double?
        var timeout: Double?
        var retries: Int?
        var startPeriod: Double?
        var startInterval: Double?

        /// `nil` when switched off, or when nothing names a test. Compose would fall back to
        /// the image's own HEALTHCHECK there, which this cannot read.
        var settled: Service.Healthcheck? {
            guard disabled != true, let test, !test.isEmpty else { return nil }
            var result = Service.Healthcheck(test: test)
            if let interval { result.interval = interval }
            if let timeout { result.timeout = timeout }
            if let retries { result.retries = retries }
            if let startPeriod { result.startPeriod = startPeriod }
            if let startInterval { result.startInterval = startInterval }
            return result
        }
    }

    /// Every key the layer wrote, so a merge knows which findings a higher layer overrode.
    var keys: Set<String> = []
    var image: String?
    var build: Build?
    var containerName: String?
    var command: [String]?
    var entrypoint: [String]?
    var user: String?
    var workingDirectory: String?
    /// In file order, because a later file in the list wins.
    var fromEnvFiles: [(key: String, value: String)] = []
    var environment: [String: String] = [:]
    var ports: [Service.Port] = []
    var mounts: [Service.Mount] = []
    var labels: [String: String] = [:]
    var networks: [String] = []
    var networksMark: SourceMark?
    var dns: [String] = []
    var dnsSearch: [String] = []
    var dnsOptions: [String] = []
    var resources: Service.Resources?
    var healthcheck: Healthcheck?
    var dependsOn: [Service.Dependency] = []
    var extensions: [String: ExtensionValue] = [:]
    /// What this layer asked for and will not get. Held here rather than reported, because a
    /// higher layer can still replace the key.
    var findings: [Finding] = []
    /// The service's node in the file that wrote the topmost layer.
    var mark: SourceMark?

    /// Keys whose value a higher layer replaces outright. A finding about one of these in a
    /// lower layer stops being true once a higher layer writes the key: `restart: "no"` over
    /// an inherited `restart: always` leaves nothing unhonoured.
    private static let replacedKeys: Set<String> = [
        "image", "container_name", "command", "working_dir", "restart", "user", "entrypoint",
        "platform", "pull_policy", "privileged", "network_mode", "stdin_open", "tty",
    ]

    /// `self` with `over` on top, by the Compose Specification's rules for `extends`, which
    /// are also its rules for merging files.
    func merged(under over: ServiceLayer) -> ServiceLayer {
        var result = over
        result.keys = keys.union(over.keys)
        result.image = over.image ?? image
        result.build = Self.merge(build, over.build)
        result.containerName = over.containerName ?? containerName
        // Replaced, never appended: a command is one thing, not a list of things.
        result.command = over.command ?? command
        result.entrypoint = over.entrypoint ?? entrypoint
        result.user = over.user ?? user
        result.workingDirectory = over.workingDirectory ?? workingDirectory
        result.fromEnvFiles = fromEnvFiles + over.fromEnvFiles
        result.environment = environment.merging(over.environment) { $1 }
        // A port is unique on host address, host port, container port and protocol, which is
        // every field it has, so equal entries are the only ones to fold.
        result.ports = Self.unique(ports + over.ports)
        // A mount is unique on its container path, and the higher layer's wins.
        let replacedTargets = Set(over.mounts.map(\.target))
        result.mounts = mounts.filter { !replacedTargets.contains($0.target) } + over.mounts
        result.labels = labels.merging(over.labels) { $1 }
        result.networks = Self.unique(networks + over.networks)
        result.networksMark = over.networksMark ?? networksMark
        result.dns = dns + over.dns
        result.dnsSearch = dnsSearch + over.dnsSearch
        result.dnsOptions = dnsOptions + over.dnsOptions
        result.resources = Self.merge(resources, over.resources)
        result.healthcheck = Self.merge(healthcheck, over.healthcheck)
        // A mapping keyed by service, so the higher layer's condition wins and the order is
        // the base's, then whatever the higher layer adds.
        let overridden = Dictionary(over.dependsOn.map { ($0.service, $0) }, uniquingKeysWith: { $1 })
        let inherited = dependsOn.map { overridden[$0.service] ?? $0 }
        let inheritedNames = Set(inherited.map(\.service))
        result.dependsOn = inherited + over.dependsOn.filter { !inheritedNames.contains($0.service) }
        result.extensions = extensions.merging(over.extensions) { $1 }
        let replaced = over.keys.intersection(Self.replacedKeys)
        result.findings = findings.filter { finding in
            let key = finding.key.split(separator: ".", maxSplits: 1).first.map(String.init) ?? finding.key
            return !replaced.contains(key)
        } + over.findings
        result.mark = over.mark ?? mark
        return result
    }

    private static func merge(_ base: Build?, _ over: Build?) -> Build? {
        guard let base else { return over }
        guard let over else { return base }
        var result = base
        result.context = over.context ?? base.context
        result.dockerfile = over.dockerfile ?? base.dockerfile
        result.args = base.args.merging(over.args) { $1 }
        result.target = over.target ?? base.target
        return result
    }

    private static func merge(_ base: Service.Resources?, _ over: Service.Resources?) -> Service.Resources? {
        guard let base else { return over }
        guard let over else { return base }
        return Service.Resources(cpus: over.cpus ?? base.cpus, memoryBytes: over.memoryBytes ?? base.memoryBytes)
    }

    private static func merge(_ base: Healthcheck?, _ over: Healthcheck?) -> Healthcheck? {
        guard let base else { return over }
        guard let over else { return base }
        return Healthcheck(
            test: over.test ?? base.test,
            disabled: over.disabled ?? base.disabled,
            interval: over.interval ?? base.interval,
            timeout: over.timeout ?? base.timeout,
            retries: over.retries ?? base.retries,
            startPeriod: over.startPeriod ?? base.startPeriod,
            startInterval: over.startInterval ?? base.startInterval
        )
    }

    private static func unique<T: Hashable>(_ items: [T]) -> [T] {
        var seen: Set<T> = []
        return items.filter { seen.insert($0).inserted }
    }
}

extension FileParser {
    /// A service with its whole `extends` chain folded in, base first.
    ///
    /// `visiting` is the chain walked so far, to refuse one that comes back on itself.
    mutating func serviceLayer(
        name: String,
        node: Node,
        visiting: [(id: String, label: String)] = []
    ) throws -> ServiceLayer {
        let id = "\(filePath ?? "")#\(name)"
        let label = displayName.map { "`\(name)` in `\($0)`" } ?? "`\(name)`"
        if visiting.contains(where: { $0.id == id }) {
            let chain = (visiting.map(\.label) + [label]).joined(separator: " extends ")
            throw ParseError(
                reason: .circularReference,
                problem: "\(chain), which goes round in a circle",
                mark: mark(node),
                path: "services.\(name).extends"
            )
        }

        let (layer, extendsNode) = try parseLayer(name: name, node: node)
        guard let extendsNode else { return layer }
        let path = "services.\(name).extends"
        let target = try parseExtends(extendsNode, path: path)
        let chain = visiting + [(id, label)]

        guard let file = target.file else {
            let baseNode = try serviceNode(target.service, requestedBy: extendsNode, path: path, in: nil)
            return try serviceLayer(name: target.service, node: baseNode, visiting: chain).merged(under: layer)
        }

        let resolved = resolvePath(file, relativeTo: directory)
        let root = try sources.root(
            of: resolved,
            writtenAs: file,
            by: "extends",
            fileSystem: options.fileSystem,
            mark: mark(extendsNode),
            path: path
        )
        var parser = FileParser(
            options: options,
            interpolator: interpolator,
            directory: (resolved as NSString).deletingLastPathComponent,
            displayName: sources.displayName(for: resolved),
            filePath: resolved,
            root: root,
            sources: sources,
            includeChain: includeChain
        )
        let baseNode = try serviceNode(target.service, requestedBy: extendsNode, path: path, in: parser)
        let base = try parser.serviceLayer(name: target.service, node: baseNode, visiting: chain)
        findings += parser.findings
        warnings += parser.warnings
        return base.merged(under: layer)
    }

    /// Compose accepts both the mapping the specification describes and a bare service name.
    private mutating func parseExtends(_ node: Node, path: String) throws -> (service: String, file: String?) {
        guard node.mapping != nil else {
            return (try string(node, path: path), nil)
        }
        var service: String?
        var file: String?
        for (keyNode, valueNode) in try mapping(node, path: path) {
            switch keyNode.scalar?.string ?? "" {
            case "service": service = try string(valueNode, path: "\(path).service")
            case "file": file = try string(valueNode, path: "\(path).file")
            default:
                throw ParseError(
                    reason: .wrongShape,
                    problem: "`extends` takes a `service` and an optional `file`",
                    mark: mark(keyNode),
                    path: path
                )
            }
        }
        guard let service, !service.isEmpty else {
            throw ParseError(reason: .missingKey, problem: "`extends` needs a `service`", mark: mark(node), path: path)
        }
        return (service, file)
    }

    /// The node for `name` under `services:` in `parser`'s file, or in this one when `nil`.
    private func serviceNode(_ name: String, requestedBy node: Node, path: String, in parser: FileParser?) throws -> Node {
        let owner = parser ?? self
        guard let baseNode = owner.root.mapping?["services"]?.mapping?[name] else {
            let place = owner.displayName.map { "`\($0)`" } ?? "this file"
            throw ParseError(
                reason: .undefinedReference,
                problem: "`extends` names service `\(name)`, which \(place) does not declare",
                mark: mark(node),
                path: path
            )
        }
        return baseNode
    }

    /// A merged layer, settled into the service the planner reads.
    mutating func finish(_ layer: ServiceLayer, name: String) throws -> Service {
        guard layer.image != nil || layer.build != nil else {
            throw ParseError(
                reason: .missingKey,
                problem: "service `\(name)` has neither `image` nor `build`",
                mark: layer.mark,
                path: "services.\(name)"
            )
        }
        findings += layer.findings
        if layer.networks.count > 1 {
            findings.append(
                Finding(
                    kind: .unhandledForm,
                    key: "networks",
                    service: name,
                    support: .deferred(
                        severity: .behavioural,
                        reason: "a container joins one network, so only `\(layer.networks[0])` is attached"
                    ),
                    mark: layer.networksMark
                )
            )
        }

        // `env_file` first, then `environment`, because the inline block is the one written
        // next to the service and has to win, whichever layer wrote either.
        var environment: [String: String] = [:]
        for pair in layer.fromEnvFiles { environment[pair.key] = pair.value }
        for (key, value) in layer.environment { environment[key] = value }

        return Service(
            name: name,
            image: layer.image,
            build: layer.build.map {
                Service.Build(
                    context: $0.context ?? $0.defaultContext,
                    dockerfile: $0.dockerfile,
                    args: $0.args,
                    target: $0.target
                )
            },
            containerName: layer.containerName,
            command: layer.command ?? [],
            entrypoint: layer.entrypoint,
            user: layer.user,
            environment: environment,
            workingDirectory: layer.workingDirectory,
            ports: layer.ports,
            mounts: layer.mounts,
            labels: layer.labels,
            networks: layer.networks,
            dns: layer.dns,
            dnsSearch: layer.dnsSearch,
            dnsOptions: layer.dnsOptions,
            resources: layer.resources,
            healthcheck: layer.healthcheck?.settled,
            dependsOn: layer.dependsOn,
            extensions: layer.extensions
        )
    }
}
