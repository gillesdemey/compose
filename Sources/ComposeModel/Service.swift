/// One entry under `services:`, with everything the file asked for already resolved:
/// interpolation applied, `env_file` merged into `environment`, short forms expanded.
///
/// Nothing here is optional for the sake of round-tripping the YAML. A field is present when
/// this implementation can act on it, which is why the type is small next to the spec.
public struct Service: Sendable, Hashable, Identifiable {
    /// A `build:` section, as much of it as the image build service can take.
    public struct Build: Sendable, Hashable {
        /// Path to the build context, relative to the project directory unless absolute.
        public var context: String
        /// Dockerfile path relative to the context. `nil` means the default `Dockerfile`.
        public var dockerfile: String?
        public var args: [String: String]
        public var target: String?

        public init(context: String, dockerfile: String? = nil, args: [String: String] = [:], target: String? = nil) {
            self.context = context
            self.dockerfile = dockerfile
            self.args = args
            self.target = target
        }
    }

    public enum PortProtocol: String, Sendable, Hashable, CaseIterable {
        case tcp
        case udp
    }

    /// A single published port. Ranges in the file are expanded into one of these per port.
    public struct Port: Sendable, Hashable, CustomStringConvertible {
        public var hostIP: String?
        /// `nil` when the file published a container port without naming a host port, which
        /// compose reads as "any free port". Nothing here can allocate one, so the parser
        /// records a finding and the planner does not publish it.
        public var hostPort: UInt16?
        public var containerPort: UInt16
        public var networkProtocol: PortProtocol

        public init(hostIP: String? = nil, hostPort: UInt16?, containerPort: UInt16, networkProtocol: PortProtocol = .tcp) {
            self.hostIP = hostIP
            self.hostPort = hostPort
            self.containerPort = containerPort
            self.networkProtocol = networkProtocol
        }

        public var description: String {
            var text = ""
            if let hostIP { text += "\(hostIP):" }
            text += "\(hostPort.map(String.init) ?? "")"
            text += ":\(containerPort)/\(networkProtocol.rawValue)"
            return text
        }
    }

    /// One entry under a service's `volumes:`.
    public struct Mount: Sendable, Hashable, CustomStringConvertible {
        public enum Source: Sendable, Hashable {
            /// A path on the host, already resolved against the project directory.
            case bind(String)
            /// A named volume declared at the top level. Deferred: nothing creates these yet.
            case named(String)
            /// No source at all, which compose fills in with a volume it invents.
            case anonymous
            /// Memory-backed, gone when the container stops. The options are the mount options
            /// as the guest's `mount` takes them: `size=64m`, `mode=1777`, `noexec`.
            case tmpfs(options: [String])
        }

        public var source: Source
        public var target: String
        public var readOnly: Bool

        public init(source: Source, target: String, readOnly: Bool = false) {
            self.source = source
            self.target = target
            self.readOnly = readOnly
        }

        public var description: String {
            let prefix: String
            switch source {
            case .bind(let path): prefix = path
            case .named(let name): prefix = name
            case .anonymous: prefix = ""
            // Bracketed, because a named volume may be called `tmpfs` and must not describe,
            // and so hash, the same.
            case .tmpfs(let options): prefix = "<tmpfs\(options.isEmpty ? "" : " " + options.joined(separator: ","))>"
            }
            return "\(prefix):\(target)\(readOnly ? ":ro" : "")"
        }
    }

    /// `deploy.resources.limits`, the only part of `deploy` that maps onto anything.
    public struct Resources: Sendable, Hashable {
        /// Fractional, as compose writes it. The execution side decides how to round.
        public var cpus: Double?
        public var memoryBytes: UInt64?

        public init(cpus: Double? = nil, memoryBytes: UInt64? = nil) {
            self.cpus = cpus
            self.memoryBytes = memoryBytes
        }

        public var isEmpty: Bool { cpus == nil && memoryBytes == nil }
    }

    public var id: String { name }

    /// The key this service sits under in `services:`.
    public var name: String
    public var image: String?
    public var build: Build?
    public var containerName: String?
    public var command: [String]
    /// `nil` keeps the image's entrypoint. Empty clears it, which is not the same thing.
    public var entrypoint: [String]?
    /// `name|uid[:gid]`, as the guest resolves it. `nil` keeps the image's user.
    public var user: String?
    public var environment: [String: String]
    public var workingDirectory: String?
    public var ports: [Port]
    public var mounts: [Mount]
    public var labels: [String: String]
    /// Networks by the key they carry in the top-level `networks:` block, in file order.
    public var networks: [String]
    /// Nameservers, in the order the resolver should try them. Empty leaves the choice to the
    /// runtime, which fills in the network's own resolver.
    public var dns: [String]
    public var dnsSearch: [String]
    public var dnsOptions: [String]
    public var resources: Resources?
    /// Service names this one must start after, already checked to exist.
    public var dependsOn: [String]
    public var extensions: [String: ExtensionValue]

    public init(
        name: String,
        image: String? = nil,
        build: Build? = nil,
        containerName: String? = nil,
        command: [String] = [],
        entrypoint: [String]? = nil,
        user: String? = nil,
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        ports: [Port] = [],
        mounts: [Mount] = [],
        labels: [String: String] = [:],
        networks: [String] = [],
        dns: [String] = [],
        dnsSearch: [String] = [],
        dnsOptions: [String] = [],
        resources: Resources? = nil,
        dependsOn: [String] = [],
        extensions: [String: ExtensionValue] = [:]
    ) {
        self.name = name
        self.image = image
        self.build = build
        self.containerName = containerName
        self.command = command
        self.entrypoint = entrypoint
        self.user = user
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.ports = ports
        self.mounts = mounts
        self.labels = labels
        self.networks = networks
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.dnsOptions = dnsOptions
        self.resources = resources
        self.dependsOn = dependsOn
        self.extensions = extensions
    }
}

extension Service {
    /// A deterministic rendering of everything that affects the container this service
    /// becomes. Two services that would produce the same container render identically,
    /// whatever order the file wrote their keys in, which is what makes the hash stamped on a
    /// container a usable answer to "has this service changed since?".
    ///
    /// The service name is in it and the dependency list is not: reordering `depends_on`
    /// changes the plan, not the container.
    public var canonicalDescription: String {
        var lines: [String] = []
        lines.append("service=\(name)")
        if let image { lines.append("image=\(image)") }
        if let build {
            lines.append("build.context=\(build.context)")
            if let dockerfile = build.dockerfile { lines.append("build.dockerfile=\(dockerfile)") }
            if let target = build.target { lines.append("build.target=\(target)") }
            for key in build.args.keys.sorted() {
                lines.append("build.arg.\(key)=\(build.args[key] ?? "")")
            }
        }
        if let containerName { lines.append("container_name=\(containerName)") }
        if !command.isEmpty { lines.append("command=\(command.joined(separator: "\u{1}"))") }
        // Both only when set, so a container made before either was read keeps its hash.
        if let entrypoint { lines.append("entrypoint=[\(entrypoint.joined(separator: "\u{1}"))]") }
        if let user { lines.append("user=\(user)") }
        for key in environment.keys.sorted() {
            lines.append("env.\(key)=\(environment[key] ?? "")")
        }
        if let workingDirectory { lines.append("working_dir=\(workingDirectory)") }
        for port in ports.map(\.description).sorted() { lines.append("port=\(port)") }
        for mount in mounts.map(\.description).sorted() { lines.append("mount=\(mount)") }
        for key in labels.keys.sorted() { lines.append("label.\(key)=\(labels[key] ?? "")") }
        for network in networks.sorted() { lines.append("network=\(network)") }
        // Resolver settings are ordered as written: a nameserver list is a preference order,
        // and sorting it would make two different configurations hash the same.
        for nameserver in dns { lines.append("dns=\(nameserver)") }
        for domain in dnsSearch { lines.append("dns_search=\(domain)") }
        for option in dnsOptions { lines.append("dns_opt=\(option)") }
        if let resources {
            if let cpus = resources.cpus { lines.append("cpus=\(cpus)") }
            if let memory = resources.memoryBytes { lines.append("memory=\(memory)") }
        }
        for key in extensions.keys.sorted() {
            lines.append("x.\(key)=\(extensions[key]?.canonicalDescription ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}
