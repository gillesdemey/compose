import ComposeModel

/// `depends_on` as a graph, and the only thing that decides what order services are touched in.
///
/// The order is deterministic for a given file: ties are broken by name, so two runs over an
/// unchanged file produce the same plan, which is what makes plans worth asserting on in tests.
public struct DependencyGraph: Sendable {
    /// Service names with every dependency ahead of the service that depends on it.
    public let startOrder: [String]

    private let dependenciesByService: [String: [String]]

    public init(services: [String: Service]) throws {
        var dependencies: [String: [String]] = [:]
        for (name, service) in services {
            // A service may not depend on itself, and a dependency the file never declares was
            // already refused by the parser.
            dependencies[name] = service.dependsOn.map(\.service).filter { $0 != name && services[$0] != nil }.sorted()
        }
        self.dependenciesByService = dependencies
        self.startOrder = try Self.topologicalOrder(of: dependencies)
    }

    /// The reverse of the start order, which is the order to stop things in.
    public var stopOrder: [String] {
        startOrder.reversed()
    }

    public func dependencies(of service: String) -> [String] {
        dependenciesByService[service] ?? []
    }

    /// Depth-first, visiting in name order, so the result is stable. A back edge is a cycle and
    /// the path back to it is the cycle worth naming in the error.
    private static func topologicalOrder(of dependencies: [String: [String]]) throws -> [String] {
        enum Visit { case inProgress, done }
        var visits: [String: Visit] = [:]
        var order: [String] = []
        var stack: [String] = []

        func visit(_ name: String) throws {
            switch visits[name] {
            case .done:
                return
            case .inProgress:
                let start = stack.firstIndex(of: name) ?? 0
                throw PlanError.dependencyCycle(Array(stack[start...]) + [name])
            case nil:
                visits[name] = .inProgress
                stack.append(name)
                for dependency in dependencies[name] ?? [] {
                    try visit(dependency)
                }
                stack.removeLast()
                visits[name] = .done
                order.append(name)
            }
        }

        for name in dependencies.keys.sorted() {
            try visit(name)
        }
        return order
    }
}
