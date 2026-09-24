import ComposeModel
import Foundation
import Yams

// One service, key by key.

extension FileParser {
    /// One service as a single file writes it, with nothing filled in from anywhere else.
    ///
    /// The `extends` node comes back untouched, for `serviceLayer` to follow. Findings raised
    /// here go into the layer rather than the parse, because a higher layer can still replace
    /// the key they are about.
    mutating func parseLayer(name: String, node: Node) throws -> (layer: ServiceLayer, extends: Node?) {
        var layer = ServiceLayer(mark: mark(node))
        var extendsNode: Node?
        let base = "services.\(name)"
        let findingsBefore = findings.count

        for (keyNode, valueNode) in try mapping(node, path: base) {
            guard let key = keyNode.scalar?.string else {
                throw ParseError(reason: .wrongShape, problem: "service keys must be plain strings", mark: mark(keyNode))
            }
            layer.keys.insert(key)
            if KeySupportTable.isExtensionKey(key) {
                layer.extensions[key] = extensionValue(valueNode)
                continue
            }
            switch key {
            case "extends":
                extendsNode = valueNode
            case "image":
                layer.image = try string(valueNode, path: "\(base).image")
            case "build":
                layer.build = try parseBuild(valueNode, service: name, path: "\(base).build")
            case "container_name":
                let container = try string(valueNode, path: "\(base).container_name")
                try validateName(container, kind: "container", node: valueNode)
                layer.containerName = container
            case "command":
                layer.command = try parseCommand(valueNode, path: "\(base).command")
            case "entrypoint":
                // `null` leaves the image's alone; an empty string or list clears it.
                layer.entrypoint = valueNode.null != nil ? nil : try parseCommand(valueNode, path: "\(base).entrypoint")
            case "user":
                layer.user = try string(valueNode, path: "\(base).user")
            case "tmpfs":
                layer.mounts += try parseTmpfs(valueNode, path: "\(base).tmpfs")
            case "environment":
                for pair in try parseEnvironment(valueNode, path: "\(base).environment") {
                    layer.environment[pair.key] = pair.value
                }
            case "env_file":
                layer.fromEnvFiles = try parseEnvFiles(valueNode, path: "\(base).env_file")
            case "working_dir":
                layer.workingDirectory = try string(valueNode, path: "\(base).working_dir")
            case "ports":
                layer.ports = try parsePorts(valueNode, service: name, path: "\(base).ports")
            case "volumes":
                layer.mounts += try parseMounts(valueNode, service: name, path: "\(base).volumes")
            case "labels":
                layer.labels = try parseLabels(valueNode, service: name, path: "\(base).labels")
            case "networks":
                layer.networks = try parseServiceNetworks(valueNode, service: name, path: "\(base).networks")
                layer.networksMark = mark(valueNode)
            case "dns":
                layer.dns = try parseStringOrList(valueNode, path: "\(base).dns")
            case "dns_search":
                layer.dnsSearch = try parseStringOrList(valueNode, path: "\(base).dns_search")
            case "dns_opt":
                layer.dnsOptions = try parseStringOrList(valueNode, path: "\(base).dns_opt")
            case "deploy":
                layer.resources = try parseDeploy(valueNode, service: name, path: "\(base).deploy")
            case "depends_on":
                layer.dependsOn = try parseDependsOn(valueNode, service: name, path: "\(base).depends_on")
            case "restart":
                // The only restart policy this stack has is the absence of one, so `no` is
                // honoured exactly, by doing nothing. Reporting it would be reporting
                // agreement, and would refuse a file the plugin can run perfectly.
                let policy = try string(valueNode, path: "\(base).restart").lowercased()
                if policy != "no", !policy.isEmpty {
                    note(
                        key: "restart",
                        service: name,
                        node: valueNode,
                        support: .unsupported(
                            severity: .behavioural,
                            reason: "`\(policy)` needs a restart policy container does not have; "
                                + "a container that exits stays exited"
                        )
                    )
                }
            default:
                if let support = KeySupportTable.service[key] {
                    note(key: key, service: name, node: valueNode, support: support)
                } else {
                    noteUnknown(key: key, service: name, node: keyNode)
                }
            }
        }

        layer.findings = Array(findings[findingsBefore...])
        findings.removeSubrange(findingsBefore...)
        return (layer, extendsNode)
    }

    // MARK: - build

    private mutating func parseBuild(_ node: Node, service: String, path: String) throws -> ServiceLayer.Build {
        if node.mapping == nil {
            let context = try string(node, path: path)
            return ServiceLayer.Build(context: resolvePath(context, relativeTo: directory), defaultContext: directory)
        }
        var build = ServiceLayer.Build(defaultContext: directory)
        for (keyNode, valueNode) in try mapping(node, path: path) {
            let key = keyNode.scalar?.string ?? ""
            switch key {
            case "context":
                build.context = resolvePath(
                    try string(valueNode, path: "\(path).context"),
                    relativeTo: directory
                )
            case "dockerfile":
                build.dockerfile = try string(valueNode, path: "\(path).dockerfile")
            case "args":
                var args: [String: String] = [:]
                for pair in try parseEnvironment(valueNode, path: "\(path).args") { args[pair.key] = pair.value }
                build.args = args
            case "target":
                build.target = try string(valueNode, path: "\(path).target")
            default:
                if KeySupportTable.isExtensionKey(key) { continue }
                note(
                    key: "build.\(key)",
                    service: service,
                    node: valueNode,
                    support: .unsupported(
                        severity: .cosmetic,
                        reason: "the image build service takes a context, a Dockerfile, arguments and a target"
                    )
                )
            }
        }
        return build
    }

    // MARK: - command

    private mutating func parseCommand(_ node: Node, path: String) throws -> [String] {
        if node.null != nil { return [] }
        if node.sequence != nil {
            var arguments: [String] = []
            for (index, element) in try sequence(node, path: path).enumerated() {
                arguments.append(try string(element, path: "\(path)[\(index)]"))
            }
            return arguments
        }
        return Self.shellSplit(try string(node, path: path))
    }

    // MARK: - environment

    /// Both forms: a mapping of names to values, and a list of `NAME=value` or bare `NAME`.
    /// A name with no value takes whatever the shell has, and is dropped when the shell has
    /// nothing, which is what compose does and the only reading that lets a file be portable.
    private mutating func parseEnvironment(_ node: Node, path: String) throws -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        if node.null != nil { return pairs }
        if let mapping = node.mapping {
            for (keyNode, valueNode) in mapping {
                guard let key = keyNode.scalar?.string else {
                    throw ParseError(reason: .wrongShape, problem: "`\(path)` names must be plain strings", mark: mark(keyNode))
                }
                if valueNode.null != nil {
                    if let inherited = interpolator.variables[key] { pairs.append((key, inherited)) }
                } else {
                    pairs.append((key, try string(valueNode, path: "\(path).\(key)")))
                }
            }
            return pairs
        }
        for (index, element) in try sequence(node, path: path).enumerated() {
            let entry = try string(element, path: "\(path)[\(index)]")
            if let separator = entry.firstIndex(of: "=") {
                let key = String(entry[entry.startIndex..<separator])
                pairs.append((key, String(entry[entry.index(after: separator)...])))
            } else if let inherited = interpolator.variables[entry] {
                pairs.append((entry, inherited))
            }
        }
        return pairs
    }

    /// `env_file` is read here rather than at execution time so that a plan carries values, not
    /// paths, and so two runs of `up` over an unchanged file hash the same.
    private mutating func parseEnvFiles(_ node: Node, path: String) throws -> [(key: String, value: String)] {
        var entries: [(path: String, required: Bool)] = []
        if node.sequence != nil {
            for (index, element) in try sequence(node, path: path).enumerated() {
                if element.mapping != nil {
                    var file = ""
                    var required = true
                    for (keyNode, valueNode) in try mapping(element, path: "\(path)[\(index)]") {
                        switch keyNode.scalar?.string ?? "" {
                        case "path": file = try string(valueNode, path: "\(path)[\(index)].path")
                        case "required": required = valueNode.bool ?? true
                        default: break
                        }
                    }
                    entries.append((file, required))
                } else {
                    entries.append((try string(element, path: "\(path)[\(index)]"), true))
                }
            }
        } else {
            entries.append((try string(node, path: path), true))
        }

        var pairs: [(key: String, value: String)] = []
        for entry in entries {
            let resolved = resolvePath(entry.path, relativeTo: directory)
            guard options.fileSystem.fileExists(atPath: resolved) else {
                if entry.required {
                    throw ParseError(
                        reason: .unreadableFile,
                        problem: "`\(entry.path)` is named by `env_file` and does not exist",
                        mark: mark(node),
                        path: path
                    )
                }
                continue
            }
            let text: String
            do {
                text = try options.fileSystem.contentsOfFile(atPath: resolved)
            } catch {
                throw ParseError(
                    reason: .unreadableFile,
                    problem: "`\(entry.path)` could not be read: \(error.localizedDescription)",
                    mark: mark(node),
                    path: path
                )
            }
            pairs.append(contentsOf: DotEnv.parse(text))
        }
        return pairs
    }

    // MARK: - labels

    mutating func parseLabels(_ node: Node, service: String?, path: String) throws -> [String: String] {
        var labels: [String: String] = [:]
        if node.null != nil { return labels }
        if let mapping = node.mapping {
            for (keyNode, valueNode) in mapping {
                guard let key = keyNode.scalar?.string else { continue }
                labels[key] = valueNode.null != nil ? "" : try string(valueNode, path: "\(path).\(key)")
            }
            return labels
        }
        for (index, element) in try sequence(node, path: path).enumerated() {
            let entry = try string(element, path: "\(path)[\(index)]")
            if let separator = entry.firstIndex(of: "=") {
                labels[String(entry[entry.startIndex..<separator])] = String(entry[entry.index(after: separator)...])
            } else {
                labels[entry] = ""
            }
        }
        return labels
    }

    // MARK: - ports

    private mutating func parsePorts(_ node: Node, service: String, path: String) throws -> [Service.Port] {
        var ports: [Service.Port] = []
        for (index, element) in try sequence(node, path: path).enumerated() {
            let elementPath = "\(path)[\(index)]"
            if element.mapping != nil {
                ports.append(contentsOf: try parseLongPort(element, service: service, path: elementPath))
            } else {
                ports.append(
                    contentsOf: try parseShortPort(
                        try string(element, path: elementPath),
                        node: element,
                        service: service,
                        path: elementPath
                    )
                )
            }
        }
        return ports
    }

    /// `[HOST_IP:][HOST:]CONTAINER[/PROTOCOL]`, where either side may be a range.
    private mutating func parseShortPort(
        _ text: String,
        node: Node,
        service: String,
        path: String
    ) throws -> [Service.Port] {
        var body = text
        var networkProtocol = Service.PortProtocol.tcp
        if let slash = body.lastIndex(of: "/") {
            let suffix = String(body[body.index(after: slash)...]).lowercased()
            guard let parsed = Service.PortProtocol(rawValue: suffix) else {
                throw ParseError(
                    reason: .invalidValue,
                    problem: "`\(text)` names protocol `\(suffix)`, which is not tcp or udp",
                    mark: mark(node),
                    path: path
                )
            }
            networkProtocol = parsed
            body = String(body[body.startIndex..<slash])
        }

        var hostIP: String?
        if body.hasPrefix("[") {
            // A bracketed IPv6 host address, which is why the split below cannot simply be on
            // every colon.
            guard let close = body.firstIndex(of: "]"), body.index(after: close) < body.endIndex else {
                throw ParseError(reason: .invalidValue, problem: "`\(text)` is not a usable port mapping", mark: mark(node), path: path)
            }
            hostIP = String(body[body.index(after: body.startIndex)..<close])
            body = String(body[body.index(close, offsetBy: 2)...])
        }

        var parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if hostIP == nil, parts.count == 3 {
            hostIP = parts.removeFirst()
        }
        guard parts.count == 1 || parts.count == 2 else {
            throw ParseError(reason: .invalidValue, problem: "`\(text)` is not a usable port mapping", mark: mark(node), path: path)
        }

        let containerText = parts.count == 2 ? parts[1] : parts[0]
        let hostText = parts.count == 2 ? parts[0] : nil
        guard let containerRange = Self.portRange(containerText) else {
            throw ParseError(reason: .invalidValue, problem: "`\(containerText)` is not a port or port range", mark: mark(node), path: path)
        }

        guard let hostText else {
            noteForm(
                key: "ports",
                service: service,
                node: node,
                severity: .behavioural,
                reason: "`\(text)` asks for any free host port, and nothing here can allocate one, "
                    + "so the port is not published"
            )
            return containerRange.map {
                Service.Port(hostIP: hostIP, hostPort: nil, containerPort: $0, networkProtocol: networkProtocol)
            }
        }
        guard let hostRange = Self.portRange(hostText) else {
            throw ParseError(reason: .invalidValue, problem: "`\(hostText)` is not a port or port range", mark: mark(node), path: path)
        }
        guard hostRange.count == containerRange.count else {
            throw ParseError(
                reason: .invalidValue,
                problem: "`\(text)` maps \(hostRange.count) host ports onto \(containerRange.count) container ports",
                mark: mark(node),
                path: path
            )
        }
        return zip(hostRange, containerRange).map { host, container in
            Service.Port(hostIP: hostIP, hostPort: host, containerPort: container, networkProtocol: networkProtocol)
        }
    }

    private mutating func parseLongPort(_ node: Node, service: String, path: String) throws -> [Service.Port] {
        var target: String?
        var published: String?
        var hostIP: String?
        var networkProtocol = Service.PortProtocol.tcp
        for (keyNode, valueNode) in try mapping(node, path: path) {
            let key = keyNode.scalar?.string ?? ""
            switch key {
            case "target": target = try string(valueNode, path: "\(path).target")
            case "published": published = try string(valueNode, path: "\(path).published")
            case "host_ip": hostIP = try string(valueNode, path: "\(path).host_ip")
            case "protocol":
                let raw = try string(valueNode, path: "\(path).protocol").lowercased()
                guard let parsed = Service.PortProtocol(rawValue: raw) else {
                    throw ParseError(reason: .invalidValue, problem: "`\(raw)` is not tcp or udp", mark: mark(valueNode), path: path)
                }
                networkProtocol = parsed
            default:
                if KeySupportTable.isExtensionKey(key) { continue }
                note(
                    key: "ports.\(key)",
                    service: service,
                    node: valueNode,
                    support: .unsupported(severity: .cosmetic, reason: "a published port here is a host port and a container port")
                )
            }
        }
        guard let target else {
            throw ParseError(reason: .missingKey, problem: "a port mapping needs a `target`", mark: mark(node), path: path)
        }
        var text = ""
        if let hostIP { text += "\(hostIP):" }
        if let published { text += "\(published):" }
        text += target
        return try parseShortPort(text + "/\(networkProtocol.rawValue)", node: node, service: service, path: path)
    }

    // MARK: - volumes

    private mutating func parseMounts(_ node: Node, service: String, path: String) throws -> [Service.Mount] {
        var mounts: [Service.Mount] = []
        for (index, element) in try sequence(node, path: path).enumerated() {
            let elementPath = "\(path)[\(index)]"
            let mount: Service.Mount?
            if element.mapping != nil {
                mount = try parseLongMount(element, service: service, path: elementPath)
            } else {
                mount = try parseShortMount(
                    try string(element, path: elementPath),
                    node: element,
                    service: service,
                    path: elementPath
                )
            }
            guard let mount else { continue }
            switch mount.source {
            case .bind, .tmpfs:
                break
            case .named(let name):
                noteForm(
                    key: "volumes",
                    service: service,
                    node: element,
                    severity: .behavioural,
                    reason: "`\(name)` is a named volume, and nothing here creates one yet; the mount is dropped"
                )
                continue
            case .anonymous:
                noteForm(
                    key: "volumes",
                    service: service,
                    node: element,
                    severity: .behavioural,
                    reason: "an anonymous volume at `\(mount.target)` needs volume support, which is not here yet; "
                        + "the mount is dropped"
                )
                continue
            }
            mounts.append(mount)
        }
        return mounts
    }

    /// `[SOURCE:]TARGET[:MODE]`, where a source starting with a path separator, a dot or a
    /// tilde is a bind and anything else names a volume.
    private mutating func parseShortMount(
        _ text: String,
        node: Node,
        service: String,
        path: String
    ) throws -> Service.Mount? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return Service.Mount(source: .anonymous, target: parts[0])
        case 2, 3:
            let modes = parts.count == 3 ? parts[2].split(separator: ",").map(String.init) : []
            let unknownModes = modes.filter { $0 != "ro" && $0 != "rw" }
            if !unknownModes.isEmpty {
                note(
                    key: "volumes",
                    service: service,
                    node: node,
                    support: .unsupported(
                        severity: .cosmetic,
                        reason: "mount option\(unknownModes.count == 1 ? "" : "s") "
                            + unknownModes.map { "`\($0)`" }.joined(separator: ", ")
                            + " mean nothing on this stack"
                    )
                )
            }
            let source = parts[0]
            let isPath = source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
            return Service.Mount(
                source: isPath ? .bind(resolvePath(source, relativeTo: directory)) : .named(source),
                target: parts[1],
                readOnly: modes.contains("ro")
            )
        default:
            throw ParseError(reason: .invalidValue, problem: "`\(text)` is not a usable volume", mark: mark(node), path: path)
        }
    }

    private mutating func parseLongMount(_ node: Node, service: String, path: String) throws -> Service.Mount? {
        var type = "volume"
        var source: String?
        var target: String?
        var readOnly = false
        var tmpfsOptions: [String] = []
        for (keyNode, valueNode) in try mapping(node, path: path) {
            let key = keyNode.scalar?.string ?? ""
            switch key {
            case "type": type = try string(valueNode, path: "\(path).type")
            case "source": source = try string(valueNode, path: "\(path).source")
            case "target": target = try string(valueNode, path: "\(path).target")
            case "read_only": readOnly = valueNode.bool ?? false
            case "tmpfs": tmpfsOptions = try parseTmpfsSettings(valueNode, service: service, path: "\(path).tmpfs")
            default:
                if KeySupportTable.isExtensionKey(key) { continue }
                note(
                    key: "volumes.\(key)",
                    service: service,
                    node: valueNode,
                    support: .unsupported(severity: .cosmetic, reason: "a mount here is a host path, a container path and a read-only flag")
                )
            }
        }
        guard let target else {
            throw ParseError(reason: .missingKey, problem: "a volume needs a `target`", mark: mark(node), path: path)
        }
        switch type {
        case "bind":
            guard let source else {
                throw ParseError(reason: .missingKey, problem: "a bind mount needs a `source`", mark: mark(node), path: path)
            }
            return Service.Mount(
                source: .bind(resolvePath(source, relativeTo: directory)),
                target: target,
                readOnly: readOnly
            )
        case "volume":
            return Service.Mount(
                source: source.map { Service.Mount.Source.named($0) } ?? .anonymous,
                target: target,
                readOnly: readOnly
            )
        case "tmpfs":
            if source != nil {
                throw ParseError(reason: .invalidValue, problem: "a tmpfs mount has no `source`", mark: mark(node), path: path)
            }
            return Service.Mount(source: .tmpfs(options: tmpfsOptions), target: target, readOnly: readOnly)
        default:
            note(
                key: "volumes.type",
                service: service,
                node: node,
                support: .unsupported(severity: .behavioural, reason: "a `\(type)` mount at `\(target)` is not available on this stack")
            )
            return nil
        }
    }

    /// The service-level `tmpfs:`, a path or a list of them, each with options after a colon
    /// as `--tmpfs` takes them: `/run:size=64m,noexec`.
    private mutating func parseTmpfs(_ node: Node, path: String) throws -> [Service.Mount] {
        try parseStringOrList(node, path: path).map { entry in
            let parts = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let target = String(parts[0])
            guard target.hasPrefix("/") else {
                throw ParseError(reason: .invalidValue, problem: "`\(entry)` is not an absolute container path", mark: mark(node), path: path)
            }
            let options = parts.count == 2 ? parts[1].split(separator: ",").map(String.init) : []
            // `ro` and `rw` are the read-only flag every other mount has, not tmpfs options.
            return Service.Mount(
                source: .tmpfs(options: options.filter { $0 != "ro" && $0 != "rw" }),
                target: target,
                readOnly: options.contains("ro")
            )
        }
    }

    /// `tmpfs:` under a long-form mount: a size in bytes or with a unit, and an octal mode.
    private mutating func parseTmpfsSettings(_ node: Node, service: String, path: String) throws -> [String] {
        var options: [String] = []
        for (keyNode, valueNode) in try mapping(node, path: path) {
            let key = keyNode.scalar?.string ?? ""
            switch key {
            case "size": options.append("size=\(try string(valueNode, path: "\(path).size"))")
            case "mode": options.append("mode=\(try string(valueNode, path: "\(path).mode"))")
            default:
                if KeySupportTable.isExtensionKey(key) { continue }
                noteUnknown(key: "volumes.tmpfs.\(key)", service: service, node: keyNode)
            }
        }
        return options
    }

    // MARK: - resolver

    /// `dns`, `dns_search` and `dns_opt` each take a bare string or a list of them, which is
    /// the short and long form compose uses throughout.
    mutating func parseStringOrList(_ node: Node, path: String) throws -> [String] {
        if node.null != nil { return [] }
        if node.sequence != nil {
            return try sequence(node, path: path).enumerated().map { index, element in
                try string(element, path: "\(path)[\(index)]")
            }
        }
        return [try string(node, path: path)]
    }

    // MARK: - networks

    private mutating func parseServiceNetworks(_ node: Node, service: String, path: String) throws -> [String] {
        var networks: [String] = []
        if node.null != nil { return networks }
        if let mapping = node.mapping {
            for (keyNode, valueNode) in mapping {
                guard let key = keyNode.scalar?.string else { continue }
                networks.append(key)
                if valueNode.null == nil, let settings = valueNode.mapping, !settings.isEmpty {
                    note(
                        key: "networks.\(key)",
                        service: service,
                        node: valueNode,
                        support: .deferred(
                            severity: .behavioural,
                            reason: "per-network settings such as aliases and fixed addresses are not applied"
                        )
                    )
                }
            }
        } else {
            for (index, element) in try sequence(node, path: path).enumerated() {
                networks.append(try string(element, path: "\(path)[\(index)]"))
            }
        }
        return networks
    }

    // MARK: - deploy

    private mutating func parseDeploy(_ node: Node, service: String, path: String) throws -> Service.Resources? {
        var resources = Service.Resources()
        for (keyNode, valueNode) in try mapping(node, path: path) {
            let key = keyNode.scalar?.string ?? ""
            switch key {
            case "resources":
                for (sectionNode, sectionValue) in try mapping(valueNode, path: "\(path).resources") {
                    let section = sectionNode.scalar?.string ?? ""
                    switch section {
                    case "limits":
                        for (limitNode, limitValue) in try mapping(sectionValue, path: "\(path).resources.limits") {
                            let limit = limitNode.scalar?.string ?? ""
                            let limitPath = "\(path).resources.limits.\(limit)"
                            switch limit {
                            case "cpus":
                                let raw = try string(limitValue, path: limitPath)
                                guard let cpus = Double(raw), cpus > 0 else {
                                    throw ParseError(reason: .invalidValue, problem: "`\(raw)` is not a cpu count", mark: mark(limitValue), path: limitPath)
                                }
                                resources.cpus = cpus
                            case "memory":
                                let raw = try string(limitValue, path: limitPath)
                                guard let bytes = Self.memoryBytes(raw), bytes > 0 else {
                                    throw ParseError(reason: .invalidValue, problem: "`\(raw)` is not a memory size", mark: mark(limitValue), path: limitPath)
                                }
                                resources.memoryBytes = bytes
                            default:
                                note(
                                    key: "deploy.resources.limits.\(limit)",
                                    service: service,
                                    node: limitValue,
                                    support: .unsupported(severity: .cosmetic, reason: "a container takes a cpu count and a memory size")
                                )
                            }
                        }
                    case "reservations":
                        note(
                            key: "deploy.resources.reservations",
                            service: service,
                            node: sectionValue,
                            support: .unsupported(severity: .cosmetic, reason: "limits are allocations here; nothing is reserved separately")
                        )
                    default:
                        note(
                            key: "deploy.resources.\(section)",
                            service: service,
                            node: sectionValue,
                            support: .unsupported(severity: .cosmetic, reason: "not part of what a container is created with")
                        )
                    }
                }
            case "replicas":
                note(
                    key: "deploy.replicas",
                    service: service,
                    node: valueNode,
                    support: .unsupported(severity: .behavioural, reason: "one service is one container; nothing here scales a service")
                )
            default:
                if KeySupportTable.isExtensionKey(key) { continue }
                note(
                    key: "deploy.\(key)",
                    service: service,
                    node: valueNode,
                    support: .unsupported(severity: .cosmetic, reason: "`deploy` is read only for its resource limits")
                )
            }
        }
        return resources.isEmpty ? nil : resources
    }

    // MARK: - depends_on

    private mutating func parseDependsOn(_ node: Node, service: String, path: String) throws -> [String] {
        if node.null != nil { return [] }
        if let mapping = node.mapping {
            var dependencies: [String] = []
            for (keyNode, valueNode) in mapping {
                guard let key = keyNode.scalar?.string else { continue }
                dependencies.append(key)
                guard valueNode.null == nil, let settings = valueNode.mapping else { continue }
                let condition = settings["condition"]?.scalar?.string ?? "service_started"
                if condition != "service_started" {
                    noteForm(
                        key: "depends_on",
                        service: service,
                        node: valueNode,
                        severity: .behavioural,
                        reason: "`\(key)` is waited on with `\(condition)`, and without health reporting the only "
                            + "condition that can be honoured is `service_started`"
                    )
                }
            }
            return dependencies
        }
        var dependencies: [String] = []
        for (index, element) in try sequence(node, path: path).enumerated() {
            dependencies.append(try string(element, path: "\(path)[\(index)]"))
        }
        return dependencies
    }
}
