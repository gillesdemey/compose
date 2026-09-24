import ComposeModel

/// One thing to do, described completely enough that whoever runs it needs nothing else.
///
/// Operations name what to do, never how. A front end runs them against the runtime; none of
/// them reads the compose file again, and the tests run none of them at all.
public enum Operation: Sendable, Equatable {
    case createNetwork(NetworkOperation)
    case removeNetwork(NetworkOperation)
    case buildImage(BuildOperation)
    case pullImage(PullOperation)
    case createContainer(CreateOperation)
    case startContainer(ContainerReference)
    case stopContainer(ContainerReference)
    case removeContainer(ContainerReference)
    /// Hold the rest of the plan until a dependency is healthy or has finished, for a
    /// `depends_on` condition that asks for more than started.
    case waitForService(WaitOperation)

    /// The service this operation is part of, for per-service progress.
    public var service: String? {
        switch self {
        case .createNetwork, .removeNetwork:
            return nil
        case .buildImage(let operation):
            return operation.service
        case .pullImage(let operation):
            return operation.service
        case .createContainer(let operation):
            return operation.service
        case .startContainer(let reference), .stopContainer(let reference), .removeContainer(let reference):
            return reference.service
        case .waitForService(let operation):
            return operation.service
        }
    }

    /// One line, in the present tense, for a terminal or a progress row.
    public var summary: String {
        switch self {
        case .createNetwork(let operation): return "create network \(operation.name)"
        case .removeNetwork(let operation): return "remove network \(operation.name)"
        case .buildImage(let operation): return "build \(operation.imageReference) from \(operation.context)"
        case .pullImage(let operation): return "pull \(operation.imageReference)"
        case .createContainer(let operation): return "create container \(operation.containerName)"
        case .startContainer(let reference): return "start \(reference.containerName)"
        case .stopContainer(let reference): return "stop \(reference.containerName)"
        case .removeContainer(let reference): return "remove \(reference.containerName)"
        case .waitForService(let operation):
            switch operation.condition {
            case .healthy: return "wait for \(operation.containerName) to be healthy"
            case .completedSuccessfully: return "wait for \(operation.containerName) to finish successfully"
            }
        }
    }
}

public struct NetworkOperation: Sendable, Equatable {
    public let name: String
    public let labels: [String: String]

    public init(name: String, labels: [String: String] = [:]) {
        self.name = name
        self.labels = labels
    }
}

public struct BuildOperation: Sendable, Equatable {
    public let service: String
    /// The tag the built image takes, which is what the container is then created from.
    public let imageReference: String
    /// Absolute path to the build context.
    public let context: String
    /// Dockerfile path relative to the context, or `nil` for the default.
    public let dockerfile: String?
    public let arguments: [String: String]
    public let target: String?

    public init(
        service: String,
        imageReference: String,
        context: String,
        dockerfile: String? = nil,
        arguments: [String: String] = [:],
        target: String? = nil
    ) {
        self.service = service
        self.imageReference = imageReference
        self.context = context
        self.dockerfile = dockerfile
        self.arguments = arguments
        self.target = target
    }
}

public struct PullOperation: Sendable, Equatable {
    public let service: String
    public let imageReference: String

    public init(service: String, imageReference: String) {
        self.service = service
        self.imageReference = imageReference
    }
}

/// A container, and everything it is created with.
///
/// The fields line up with what the create surface underneath already takes. Anything a
/// compose file asked for that is not here was reported as a finding at parse time rather than
/// quietly lost here.
public struct CreateOperation: Sendable, Equatable {
    public struct Mount: Sendable, Equatable {
        public let hostPath: String
        public let containerPath: String
        public let readOnly: Bool

        public init(hostPath: String, containerPath: String, readOnly: Bool) {
            self.hostPath = hostPath
            self.containerPath = containerPath
            self.readOnly = readOnly
        }
    }

    /// A service-level or `type: tmpfs` mount: memory in the guest, nothing on the host.
    public struct Tmpfs: Sendable, Equatable {
        public let containerPath: String
        /// As the guest's `mount` takes them, `ro` included when the mount is read-only.
        public let options: [String]

        public init(containerPath: String, options: [String]) {
            self.containerPath = containerPath
            self.options = options
        }
    }

    public struct Port: Sendable, Equatable {
        /// The host interface to publish on. `0.0.0.0` unless the file named one, which is a
        /// difference worth keeping: a port bound to `127.0.0.1` is not on the network.
        public let hostAddress: String
        public let hostPort: UInt16
        public let containerPort: UInt16
        public let networkProtocol: String

        public init(
            hostAddress: String = "0.0.0.0",
            hostPort: UInt16,
            containerPort: UInt16,
            networkProtocol: String
        ) {
            self.hostAddress = hostAddress
            self.hostPort = hostPort
            self.containerPort = containerPort
            self.networkProtocol = networkProtocol
        }
    }

    public let service: String
    public let containerName: String
    public let imageReference: String
    /// Sorted `KEY=value`, which is the shape the create call wants and a stable one to assert
    /// on.
    public let environment: [String]
    public let command: [String]
    /// `nil` keeps the image's.
    public let entrypoint: [String]?
    /// `nil` keeps the image's.
    public let user: String?
    public let workingDirectory: String?
    public let mounts: [Mount]
    public let tmpfs: [Tmpfs]
    public let ports: [Port]
    public let networkName: String
    public let labels: [String: String]
    /// Nameservers in preference order. Empty means the runtime picks, which it only does when
    /// a resolver configuration is present at all.
    public let dns: [String]
    public let dnsSearch: [String]
    public let dnsOptions: [String]
    public let cpus: Double?
    public let memoryBytes: UInt64?

    public init(
        service: String,
        containerName: String,
        imageReference: String,
        environment: [String],
        command: [String],
        entrypoint: [String]? = nil,
        user: String? = nil,
        workingDirectory: String?,
        mounts: [Mount],
        tmpfs: [Tmpfs] = [],
        ports: [Port],
        networkName: String,
        labels: [String: String],
        dns: [String] = [],
        dnsSearch: [String] = [],
        dnsOptions: [String] = [],
        cpus: Double?,
        memoryBytes: UInt64?
    ) {
        self.service = service
        self.containerName = containerName
        self.imageReference = imageReference
        self.environment = environment
        self.command = command
        self.entrypoint = entrypoint
        self.user = user
        self.workingDirectory = workingDirectory
        self.mounts = mounts
        self.tmpfs = tmpfs
        self.ports = ports
        self.networkName = networkName
        self.labels = labels
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.dnsOptions = dnsOptions
        self.cpus = cpus
        self.memoryBytes = memoryBytes
    }
}

/// A container an operation acts on, named rather than described.
public struct ContainerReference: Sendable, Equatable {
    public let containerName: String
    /// `nil` for a container that carries the project label but no longer has a service in the
    /// file, which is exactly the orphan case.
    public let service: String?

    public init(containerName: String, service: String? = nil) {
        self.containerName = containerName
        self.service = service
    }
}

/// A dependency the plan waits on before it starts what depends on it.
public struct WaitOperation: Sendable, Equatable {
    public enum Condition: Sendable, Equatable {
        /// Run the probe inside the container until it passes, or fails too often.
        case healthy(Service.Healthcheck)
        /// Wait for the container's process to exit, and fail unless it exits 0.
        case completedSuccessfully
    }

    /// The service waited on.
    public let service: String
    public let containerName: String
    public let condition: Condition
    /// The first service in the plan that waits, for the error when the wait fails.
    public let waitingService: String

    public init(service: String, containerName: String, condition: Condition, waitingService: String) {
        self.service = service
        self.containerName = containerName
        self.condition = condition
        self.waitingService = waitingService
    }
}
