import ComposeModel
import ComposePlanner
import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import TerminalProgress

/// The only part of the plugin that talks to the runtime.
///
/// Everything above this decides; this carries out. The split is why the planner can be
/// tested without any of this existing.
enum Runtime {
    // MARK: - Reading the world

    /// Every container, network and image the runtime knows about.
    ///
    /// Deliberately everything, not just this project's: the planner checks published ports
    /// against the whole machine, and a host port taken by something unrelated is exactly the
    /// conflict worth catching before anything is created.
    static func snapshot() async throws -> CurrentState {
        do {
            async let containers = ContainerClient().list()
            async let networks = NetworkClient().list()
            async let images = ClientImage.list()
            return CurrentState(
                containers: try await containers.map(state(of:)),
                networks: try await networks.map {
                    NetworkState(name: $0.id, labels: $0.labels.dictionary)
                },
                images: try await images.map(\.reference)
            )
        } catch {
            throw ComposeError(
                "the container runtime is not reachable: \(friendly(error)). "
                    + "Check that `container system start` has been run."
            )
        }
    }

    // `ContainerState` is a name ContainerizationOCI also uses, hence the qualification.
    private static func state(of snapshot: ContainerSnapshot) -> ComposePlanner.ContainerState {
        ComposePlanner.ContainerState(
            name: snapshot.configuration.id,
            labels: snapshot.configuration.labels,
            isRunning: snapshot.status == .running,
            // A published range is one entry with a count, and the planner thinks in single
            // ports, so it is spread out here.
            publishedHostPorts: snapshot.configuration.publishedPorts.flatMap { port in
                (0..<port.count).map { port.hostPort + $0 }
            },
            networkName: snapshot.configuration.networks.first?.network
        )
    }

    // MARK: - Carrying a plan out

    static func execute(_ plan: Plan) async throws {
        let total = plan.operations.count
        for (index, operation) in plan.operations.enumerated() {
            Output.step(index + 1, of: total, operation.summary)
            do {
                try await perform(operation)
            } catch let error as ComposeError {
                throw error
            } catch {
                // A plan stops at the first failure. Some of it has happened and the rest has
                // not, which is worth saying plainly: the next `up` will work out the
                // difference from the containers themselves.
                throw ComposeError(
                    "\(operation.summary) failed: \(friendly(error))\n"
                    + "  \(total - index - 1) later step(s) were not attempted; run `up` again once it is fixed"
                )
            }
        }
    }

    // `Operation` is a name Foundation also uses, hence the qualification.
    private static func perform(_ operation: ComposePlanner.Operation) async throws {
        switch operation {
        case .createNetwork(let operation):
            try await createNetwork(operation)
        case .removeNetwork(let operation):
            try await NetworkClient().delete(id: operation.name)
        case .pullImage(let operation):
            try await pull(operation)
        case .buildImage(let operation):
            try build(operation)
        case .createContainer(let operation):
            try await create(operation)
        case .startContainer(let reference):
            let process = try await ContainerClient().bootstrap(id: reference.containerName, stdio: [nil, nil, nil])
            try await process.start()
        case .stopContainer(let reference):
            try await ContainerClient().stop(id: reference.containerName)
        case .removeContainer(let reference):
            try await ContainerClient().delete(id: reference.containerName, force: true)
        }
    }

    private static func createNetwork(_ operation: NetworkOperation) async throws {
        let configuration = try NetworkConfiguration(
            name: operation.name,
            mode: .nat,
            labels: try ResourceLabels(operation.labels),
            plugin: "container-network-vmnet"
        )
        _ = try await NetworkClient().create(configuration: configuration)
    }

    private static func pull(_ operation: PullOperation) async throws {
        let printer = PullPhasePrinter()
        _ = try await ClientImage.pull(
            reference: operation.imageReference,
            containerSystemConfig: try await ConfigurationLoader.load(),
            progressUpdate: { events in printer.handle(events) }
        )
    }

    /// The one operation that is not carried out in process.
    ///
    /// Building needs the BuildKit builder started, dialled and its result unpacked, and the
    /// CLI is the only thing that does all three. Doing anything else here would be a second
    /// implementation of the hard part.
    private static func build(_ operation: BuildOperation) throws {
        var arguments = [
            "build",
            "--tag", operation.imageReference,
            // Everything on this stack is a linux/arm64 guest, which is why `platform` in a
            // compose file is reported and ignored rather than passed through.
            "--arch", "arm64",
            "--progress", "plain",
        ]
        if let dockerfile = operation.dockerfile {
            let path = dockerfile.hasPrefix("/")
                ? dockerfile
                : (operation.context as NSString).appendingPathComponent(dockerfile)
            arguments += ["--file", path]
        }
        for key in operation.arguments.keys.sorted() {
            arguments += ["--build-arg", "\(key)=\(operation.arguments[key] ?? "")"]
        }
        if let target = operation.target, !target.isEmpty {
            arguments += ["--target", target]
        }
        arguments.append(operation.context)

        let process = Process()
        let binary = containerBinary()
        if binary.contains("/") {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [binary] + arguments
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ComposeError("`container build` exited \(process.terminationStatus)")
        }
    }

    /// Create the host directories a service binds that are not there yet, which is what
    /// compose does and what a file writing `./data/public:/data` expects.
    ///
    /// Without this the runtime is handed a mount whose source does not exist and the failure
    /// arrives much later, as a container that will not bootstrap with `errno 2`.
    ///
    /// - Returns: the paths that had to be created, for reporting.
    @discardableResult
    static func ensureBindSources(of operation: CreateOperation) throws -> [String] {
        var created: [String] = []
        for mount in operation.mounts where !FileManager.default.fileExists(atPath: mount.hostPath) {
            do {
                try FileManager.default.createDirectory(
                    atPath: mount.hostPath,
                    withIntermediateDirectories: true
                )
            } catch {
                throw ComposeError(
                    "`\(mount.hostPath)` is mounted at `\(mount.containerPath)` and does not "
                        + "exist: \(error.localizedDescription)"
                )
            }
            created.append(mount.hostPath)
        }
        return created
    }

    /// The `container` CLI that ran this plugin.
    ///
    /// A plugin lives at `<root>/libexec/container-plugins/<name>/bin/<name>`, so the CLI is
    /// five levels up and back down into `bin`. The fallbacks are for a plugin being run
    /// straight out of a build directory.
    private static func containerBinary() -> String {
        var root = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let sibling = root.appendingPathComponent("bin").appendingPathComponent("container").path
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/container") {
            return "/usr/local/bin/container"
        }
        return "container"
    }

    private static func create(_ operation: CreateOperation) async throws {
        for path in try ensureBindSources(of: operation) {
            Output.note("        created \(path)")
        }
        let systemConfig = try await ConfigurationLoader.load()
        let image = try await ClientImage.fetch(
            reference: operation.imageReference,
            containerSystemConfig: systemConfig
        )
        let platform = ContainerizationOCI.Platform.current
        _ = try await image.getCreateSnapshot(platform: platform)
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        let imageConfig = try await image.config(for: platform).config

        let mounts: [Filesystem] = operation.mounts.map { mount in
            .virtiofs(
                source: mount.hostPath,
                destination: mount.containerPath,
                options: mount.readOnly ? ["ro"] : []
            )
        }
        let ports: [PublishPort] = try operation.ports.map { port in
            try PublishPort(
                hostAddress: try IPAddress(port.hostAddress),
                hostPort: port.hostPort,
                containerPort: port.containerPort,
                proto: PublishProtocol(port.networkProtocol) ?? .tcp,
                count: 1
            )
        }

        let arguments = Planner.processArguments(
            imageEntrypoint: imageConfig?.entrypoint,
            imageCmd: imageConfig?.cmd,
            entrypoint: operation.entrypoint,
            command: operation.command
        )
        guard let executable = arguments.first else {
            throw ComposeError(
                "`\(operation.imageReference)` declares no entrypoint or command, so service "
                    + "`\(operation.service)` has nothing to run; give it a `command`"
            )
        }
        // The file's user over the image's, and root when neither says, as `container run`
        // does. A name is resolved by the guest against the image's /etc/passwd.
        let user: ProcessConfiguration.User = {
            if let raw = operation.user ?? imageConfig?.user, !raw.isEmpty { return .raw(userString: raw) }
            return .id(uid: 0, gid: 0)
        }()
        let process = ProcessConfiguration(
            executable: executable,
            arguments: Array(arguments.dropFirst()),
            environment: (imageConfig?.env ?? []) + operation.environment,
            workingDirectory: operation.workingDirectory ?? imageConfig?.workingDir ?? "/",
            terminal: false,
            user: user
        )

        var configuration = ContainerResource.ContainerConfiguration(
            id: operation.containerName,
            image: image.description,
            process: process
        )
        configuration.mounts = mounts + operation.tmpfs.map { .tmpfs(destination: $0.containerPath, options: $0.options) }
        configuration.publishedPorts = ports
        configuration.labels = operation.labels
        // A compose file can ask for half a core; a VM cannot have one. Round up, because the
        // number is a limit and rounding down would be a quieter kind of wrong.
        if let cpus = operation.cpus {
            configuration.resources.cpus = max(1, Int(cpus.rounded(.up)))
        }
        if let memory = operation.memoryBytes {
            configuration.resources.memoryInBytes = memory
        }
        // Always send a resolver configuration, even an empty one. A container created with
        // none comes up with no /etc/resolv.conf at all: the runtime fills in the network's
        // own nameserver only when a configuration is present and its nameserver list is
        // empty, so leaving this nil skips that and every lookup inside the container falls
        // back to [::1]:53 and is refused. `container run` sends one even with no --dns flag,
        // because its flags default to empty rather than absent.
        //
        // Naming nameservers explicitly matters on a project network, where the gateway does
        // not answer: a service that has to resolve anything needs `dns:` in the file until
        // the runtime serves DNS on networks it did not create itself.
        configuration.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: operation.dns,
            domain: nil,
            searchDomains: operation.dnsSearch,
            options: operation.dnsOptions
        )
        configuration.networks = [
            AttachmentConfiguration(
                network: operation.networkName,
                // The hostname is the container name, not the service name. A compose file
                // expects one service to reach another by service name, but the runtime
                // requires hostnames to be unique across every container on the machine, so
                // two projects with a `db` service could not both exist. Until
                // apple/container#1809 gives networks their own namespace, `<project>-<service>`
                // is the name a service answers to.
                options: AttachmentOptions(hostname: operation.containerName, macAddress: nil, mtu: 1280)
            )
        ]

        try await ContainerClient().create(
            configuration: configuration,
            options: ContainerCreateOptions(autoRemove: false),
            kernel: kernel
        )
    }

    // MARK: - Helpers

    /// Runtime errors arrive wrapped and verbose. Take the message if there is one.
    static func friendly(_ error: any Error) -> String {
        let described = String(describing: error)
        if let range = described.range(of: "message: \"") {
            let rest = described[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                return String(rest[rest.startIndex..<end])
            }
        }
        return error.localizedDescription
    }
}

/// Pulls are slow and silent otherwise. Only phase changes are printed: a progress bar in a
/// plugin that may be writing to a pipe is worse than nothing.
private final class PullPhasePrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func handle(_ events: [ProgressUpdateEvent]) {
        var phase: String?
        for event in events {
            if case .setDescription(let text) = event { phase = text }
        }
        guard let phase, !phase.isEmpty else { return }
        lock.lock()
        let changed = phase != last
        last = phase
        lock.unlock()
        if changed { Output.note("        \(phase)") }
    }
}
