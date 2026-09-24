import ComposeModel
import Foundation
import Yams

/// A resolved `ComposeFile` written back out as compose YAML, the way `docker compose config`
/// shows a project: every `include` and `extends` merged, variables substituted, `env_file`
/// merged in, paths absolute, short forms expanded, and the implicit default network written
/// down.
///
/// It shows what this implementation will act on, which is less than the file asked for: a
/// key reported as a finding is not in the model, so it is not in the output either. Keys
/// come out in the order compose uses, so the two outputs can be compared with `diff`.
public enum ComposeFileRenderer {
    public static func yaml(for file: ComposeFile, projectName: String) throws -> String {
        var root: [(String, Node)] = [("name", string(projectName))]

        let services = file.orderedServices
        if !services.isEmpty {
            root.append(("services", mapping(services.map { ($0.name, node(for: $0)) })))
        }

        var networks = file.networks
        if services.contains(where: \.networks.isEmpty), networks["default"] == nil {
            networks["default"] = NetworkSpec(key: "default")
        }
        if !networks.isEmpty {
            root.append(("networks", mapping(networks.keys.sorted().map { key in
                let spec = networks[key]!
                // No `driver:`. It is read and reported, and container picks the driver itself.
                return (key, resource(
                    name: spec.resolvedName(projectName: projectName),
                    driver: nil,
                    isExternal: spec.isExternal,
                    labels: spec.labels
                ))
            })))
        }

        if !file.volumes.isEmpty {
            root.append(("volumes", mapping(file.volumes.keys.sorted().map { key in
                let spec = file.volumes[key]!
                return (key, resource(
                    name: spec.resolvedName(projectName: projectName),
                    driver: spec.driver,
                    isExternal: spec.isExternal,
                    labels: spec.labels
                ))
            })))
        }

        root.append(contentsOf: extensions(file.extensions))
        return try Yams.serialize(node: mapping(root))
    }

    private static func node(for service: Service) -> Node {
        var pairs: [(String, Node)] = []
        if let build = service.build {
            var fields: [(String, Node)] = [("context", string(build.context))]
            if let dockerfile = build.dockerfile { fields.append(("dockerfile", string(dockerfile))) }
            if !build.args.isEmpty { fields.append(("args", stringMap(build.args))) }
            if let target = build.target { fields.append(("target", string(target))) }
            pairs.append(("build", mapping(fields)))
        }
        if !service.command.isEmpty { pairs.append(("command", strings(service.command))) }
        if let containerName = service.containerName { pairs.append(("container_name", string(containerName))) }
        if let resources = service.resources, !resources.isEmpty {
            var limits: [(String, Node)] = []
            if let cpus = resources.cpus { limits.append(("cpus", number(cpus))) }
            if let memory = resources.memoryBytes { limits.append(("memory", string(String(memory)))) }
            pairs.append(("deploy", mapping([("resources", mapping([("limits", mapping(limits))]))])))
        }
        if !service.dependsOn.isEmpty {
            // The list form is all this reads, and it means what compose means by it: start
            // after, and fail if the dependency is not in the project.
            pairs.append(("depends_on", mapping(service.dependsOn.sorted().map { name in
                (name, mapping([("condition", string("service_started")), ("required", boolean(true))]))
            })))
        }
        if !service.dns.isEmpty { pairs.append(("dns", strings(service.dns))) }
        if !service.dnsOptions.isEmpty { pairs.append(("dns_opt", strings(service.dnsOptions))) }
        if !service.dnsSearch.isEmpty { pairs.append(("dns_search", strings(service.dnsSearch))) }
        if let entrypoint = service.entrypoint { pairs.append(("entrypoint", strings(entrypoint))) }
        if !service.environment.isEmpty { pairs.append(("environment", stringMap(service.environment))) }
        if let image = service.image { pairs.append(("image", string(image))) }
        if !service.labels.isEmpty { pairs.append(("labels", stringMap(service.labels))) }
        let networks = service.networks.isEmpty ? ["default"] : service.networks
        pairs.append(("networks", mapping(networks.map { ($0, null) })))
        if !service.ports.isEmpty { pairs.append(("ports", .sequence(.init(service.ports.map(node(for:)))))) }
        // Every tmpfs mount goes in the service-level list, whichever form the file used: the
        // long form has no place for options other than a size and a mode.
        let tmpfs = service.mounts.compactMap { mount -> String? in
            guard case .tmpfs(let options) = mount.source else { return nil }
            let all = options + (mount.readOnly ? ["ro"] : [])
            return all.isEmpty ? mount.target : "\(mount.target):\(all.joined(separator: ","))"
        }
        if !tmpfs.isEmpty { pairs.append(("tmpfs", strings(tmpfs))) }
        if let user = service.user { pairs.append(("user", string(user))) }
        let volumes = service.mounts.filter { if case .tmpfs = $0.source { return false } else { return true } }
        if !volumes.isEmpty { pairs.append(("volumes", .sequence(.init(volumes.map(node(for:)))))) }
        if let workingDirectory = service.workingDirectory { pairs.append(("working_dir", string(workingDirectory))) }
        pairs.append(contentsOf: extensions(service.extensions))
        return mapping(pairs)
    }

    private static func node(for port: Service.Port) -> Node {
        // No `mode:`. compose writes `ingress`, its default, but this reads the key as a finding,
        // and the output has to read back here without one.
        var fields: [(String, Node)] = []
        if let hostIP = port.hostIP { fields.append(("host_ip", string(hostIP))) }
        fields.append(("target", integer(Int(port.containerPort))))
        if let hostPort = port.hostPort { fields.append(("published", string(String(hostPort)))) }
        fields.append(("protocol", string(port.networkProtocol.rawValue)))
        return mapping(fields)
    }

    private static func node(for mount: Service.Mount) -> Node {
        var fields: [(String, Node)]
        switch mount.source {
        case .bind(let path): fields = [("type", string("bind")), ("source", string(path))]
        case .named(let name): fields = [("type", string("volume")), ("source", string(name))]
        case .anonymous: fields = [("type", string("volume"))]
        case .tmpfs: fields = [("type", string("tmpfs"))]
        }
        fields.append(("target", string(mount.target)))
        if mount.readOnly { fields.append(("read_only", boolean(true))) }
        return mapping(fields)
    }

    private static func resource(name: String, driver: String?, isExternal: Bool, labels: [String: String]) -> Node {
        var fields: [(String, Node)] = [("name", string(name))]
        if let driver { fields.append(("driver", string(driver))) }
        if isExternal { fields.append(("external", boolean(true))) }
        if !labels.isEmpty { fields.append(("labels", stringMap(labels))) }
        return mapping(fields)
    }

    private static func extensions(_ values: [String: ExtensionValue]) -> [(String, Node)] {
        values.keys.sorted().map { ($0, node(for: values[$0]!)) }
    }

    private static func node(for value: ExtensionValue) -> Node {
        switch value {
        case .string(let text): return string(text)
        case .number(let number): return self.number(number)
        case .boolean(let flag): return boolean(flag)
        case .null: return null
        case .list(let values): return .sequence(.init(values.map(node(for:))))
        case .map(let values): return mapping(values.keys.sorted().map { ($0, node(for: values[$0]!)) })
        }
    }

    // MARK: Scalars

    private static func mapping(_ pairs: [(String, Node)]) -> Node {
        .mapping(.init(pairs.map { (scalar($0.0), $0.1) }))
    }

    private static func stringMap(_ values: [String: String]) -> Node {
        mapping(values.keys.sorted().map { ($0, string(values[$0]!)) })
    }

    private static func strings(_ values: [String]) -> Node {
        .sequence(.init(values.map(string)))
    }

    /// A value, written so that reading the output back as a compose file gives this value
    /// again: `$` doubled, because values are interpolated and this one already has been.
    private static func string(_ value: String) -> Node {
        scalar(value.replacingOccurrences(of: "$", with: "$$"))
    }

    /// Quoted whenever the plain form would read back as something other than this string:
    /// an environment value of `"true"` or `"8080"` has to stay a string.
    private static func scalar(_ text: String) -> Node {
        // Yams quotes exactly the strings that would not read back as strings; compose quotes
        // with double quotes, so the same decision is kept and only the style changed.
        let represented = text.represented()
        return .scalar(represented.style == .singleQuoted ? .init(text, Tag(.str), .doubleQuoted) : represented)
    }

    private static func integer(_ value: Int) -> Node {
        .scalar(.init(String(value), Tag(.int)))
    }

    private static func number(_ value: Double) -> Node {
        if value.rounded() == value, abs(value) < 1e15 { return integer(Int(value)) }
        return .scalar(.init(String(value), Tag(.float)))
    }

    private static func boolean(_ value: Bool) -> Node {
        .scalar(.init(value ? "true" : "false", Tag(.bool)))
    }
}

private var null: Node { Node.scalar(.init("null", Tag(.null))) }
