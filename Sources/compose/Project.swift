import ArgumentParser
import ComposeModel
import ComposeParser
import ComposePlanner
import Foundation

/// A compose file, found, read and understood, plus what it asked for and will not get.
struct LoadedProject {
    let path: String
    let identity: ProjectIdentity
    let result: ParseResult

    var file: ComposeFile { result.file }
}

enum ProjectLoader {
    /// The names compose looks for, in the order it looks for them.
    static let candidateNames = [
        "compose.yaml",
        "compose.yml",
        "docker-compose.yaml",
        "docker-compose.yml",
    ]

    static func load(_ options: CommonOptions) throws -> LoadedProject {
        let path = try locate(options.file)
        let result: ParseResult
        do {
            result = try ComposeFileParser.parse(contentsOfFile: path)
        } catch let error as ParseError {
            // An error inside an included or extended file already names that file.
            throw ComposeError(error.mark?.file == nil ? "\(path):\(error.description)" : error.description)
        } catch {
            throw ComposeError("\(path) could not be read: \(error.localizedDescription)")
        }
        let directory = (path as NSString).deletingLastPathComponent
        let identity = ProjectIdentity.resolve(
            explicitName: options.projectName,
            file: result.file,
            projectDirectory: directory.isEmpty ? FileManager.default.currentDirectoryPath : directory
        )
        return LoadedProject(path: path, identity: identity, result: result)
    }

    /// What this does about keys it will not honour.
    ///
    /// It refuses the file. A command in a script has nobody to ask, and a database that never
    /// comes back after a crash because `restart: always` was quietly dropped is worse than a
    /// command that would not run.
    ///
    /// Only behavioural findings refuse. Cosmetic ones are printed and stepped over: nobody
    /// should be blocked by an obsolete `version` key.
    ///
    /// `down` never calls this. Refusing to stop containers over a key nothing is about to act
    /// on would leave someone with no way to clean up.
    ///
    /// `ignoring` is the way past it, one key at a time and one run at a time: what those keys
    /// ask for is left undone, and every such finding is still printed, as a warning, so the
    /// decision is in the output of every run it applies to.
    static func enforcePolicy(on project: LoadedProject, ignoring ignored: [String] = []) throws {
        for warning in project.result.interpolationWarnings {
            Output.warning(warning.message)
        }
        for finding in project.result.findings where finding.severity == .cosmetic {
            Output.note("note: \(finding.message)")
        }

        let all = project.result.blockingFindings
        let waived = all.filter { finding in ignored.contains { finding.isAbout(key: $0) } }
        for key in ignored where !all.contains(where: { $0.isAbout(key: key) }) {
            Output.warning("`--ignore \(key)` matches nothing this file asks for")
        }
        if !waived.isEmpty {
            let count = waived.count
            Output.warning(
                "ignoring \(count) thing\(count == 1 ? "" : "s") this cannot do, as asked; "
                    + "\(count == 1 ? "it is" : "they are") left undone"
            )
            for finding in waived { Output.line("  \(finding.message)") }
        }

        let blocking = all.filter { !waived.contains($0) }
        guard blocking.isEmpty else {
            let count = blocking.count
            Output.error(
                "\(project.path) asks for \(count) thing\(count == 1 ? "" : "s") this cannot do",
                details: blocking.map(\.message)
            )
            Output.error(
                "nothing was created. Remove or change those keys, or pass `--ignore <key>` "
                    + "to run without them, and run again."
            )
            throw ExitCode.failure
        }
    }

    private static func locate(_ explicit: String?) throws -> String {
        let fileManager = FileManager.default
        if let explicit {
            guard fileManager.fileExists(atPath: explicit) else {
                throw ComposeError("`\(explicit)` does not exist")
            }
            return explicit
        }
        let directory = fileManager.currentDirectoryPath
        for name in candidateNames {
            let path = (directory as NSString).appendingPathComponent(name)
            if fileManager.fileExists(atPath: path) { return path }
        }
        throw ComposeError(
            "no compose file in \(directory); looked for \(candidateNames.joined(separator: ", "))"
        )
    }
}
