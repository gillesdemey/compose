import ArgumentParser
import ComposeModel
import ComposeParser
import ComposePlanner
import Foundation

/// `container compose`.
///
/// The CLI finds this binary by name, resets SIGINT and SIGTERM to their defaults, and
/// `execvp`s into it with the remaining arguments, so from here down it is an ordinary
/// command-line program that happens to be reached through another one.
@main
struct Compose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Bring a set of services up and down from a compose file.",
        version: composeVersion,
        subcommands: [Up.self, Down.self, Config.self]
    )
}

/// The options every verb takes.
struct CommonOptions: ParsableArguments {
    @Option(
        name: [.short, .customLong("file")],
        help: ArgumentHelp("Path to the compose file", valueName: "path")
    )
    var file: String?

    @Option(
        name: [.short, .customLong("project-name")],
        help: ArgumentHelp(
            "Project name, which by default comes from the file's `name`, then its directory",
            valueName: "name"
        )
    )
    var projectName: String?
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create and start the services in the file, in dependency order."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Work out the plan, print it, and change nothing.")
    var dryRun = false

    @Flag(name: .long, help: "Recreate every container, whether or not its service changed.")
    var forceRecreate = false

    @Option(name: .long, help: "When to pull images: missing, always or never.")
    var pull: PullPolicyArgument = .missing

    @Flag(name: .long, help: "Keep containers whose service has left the file, rather than removing them.")
    var keepOrphans = false

    func run() async throws {
        let project = try ProjectLoader.load(common)
        Report.header(project)
        try ProjectLoader.enforcePolicy(on: project)

        let state = try await Runtime.snapshot()
        let plan: Plan
        do {
            plan = try Planner.up(
                file: project.file,
                project: project.identity,
                state: state,
                options: UpOptions(
                    pullPolicy: pull.policy,
                    forceRecreate: forceRecreate,
                    removeOrphans: !keepOrphans
                )
            )
        } catch let error as PlanError {
            throw ComposeError(error.description)
        }

        Report.decisions(plan)
        guard !plan.isEmpty else {
            Output.line("Everything is already up to date.")
            return
        }
        guard !dryRun else {
            Report.dryRun(plan)
            return
        }
        try await Runtime.execute(plan)
    }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop and remove the project's containers, and the networks it created."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Work out the plan, print it, and change nothing.")
    var dryRun = false

    @Flag(name: .long, help: "Leave the networks this project created in place.")
    var keepNetworks = false

    func run() async throws {
        // `down` reads the file for the service names and the order to stop them in, but the
        // containers themselves are found by label, so a file that has moved on since `up`
        // still takes the whole project down.
        let project = try ProjectLoader.load(common)
        Report.header(project)

        let state = try await Runtime.snapshot()
        let plan: Plan
        do {
            plan = try Planner.down(
                file: project.file,
                project: project.identity,
                state: state,
                options: DownOptions(removeNetworks: !keepNetworks)
            )
        } catch let error as PlanError {
            throw ComposeError(error.description)
        }

        guard !plan.isEmpty else {
            Output.line("Nothing of this project is running.")
            return
        }
        guard !dryRun else {
            Report.dryRun(plan)
            return
        }
        try await Runtime.execute(plan)
    }
}

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the project as it will be run: includes and extends merged, variables substituted, paths resolved."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Print the service names, one per line.")
    var services = false

    func run() async throws {
        let project = try ProjectLoader.load(common)

        // Nothing is about to run, so nothing here refuses. What the file asked for and will
        // not get is still said, on stderr, because it is missing from what is printed.
        for warning in project.result.interpolationWarnings {
            Output.warningToStandardError(warning.message)
        }
        let findings = project.result.findings
        if !findings.isEmpty {
            let count = findings.count
            Output.warningToStandardError(
                "\(count) key\(count == 1 ? " is" : "s are") left out, because this cannot honour \(count == 1 ? "it" : "them")",
                details: findings.map(\.message)
            )
        }

        if services {
            for service in project.file.orderedServices { Output.line(service.name) }
            return
        }
        let yaml = try ComposeFileRenderer.yaml(for: project.file, projectName: project.identity.name)
        FileHandle.standardOutput.write(Data(yaml.utf8))
    }
}

enum PullPolicyArgument: String, ExpressibleByArgument, CaseIterable {
    case missing
    case always
    case never

    var policy: UpOptions.PullPolicy {
        switch self {
        case .missing: return .missing
        case .always: return .always
        case .never: return .never
        }
    }
}
