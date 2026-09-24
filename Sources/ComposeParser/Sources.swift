import ComposeModel
import Foundation
import Yams

/// Every file one parse reads beyond the first, each read and composed once.
///
/// A class because every file's parser shares it: a base file several services extend, or a
/// file two includes name, is read the first time and reused after.
final class SourceCache {
    /// The starting file's directory, which names of other files are given relative to.
    let rootDirectory: String
    private var roots: [String: Node] = [:]

    init(rootDirectory: String) {
        self.rootDirectory = rootDirectory
    }

    /// Short when the file sits under the starting directory, which it nearly always does.
    func displayName(for path: String) -> String {
        let prefix = rootDirectory.hasSuffix("/") ? rootDirectory : rootDirectory + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// The document in `path`, which `key` named as `written` at `mark`.
    func root(
        of path: String,
        writtenAs written: String,
        by key: String,
        fileSystem: any ComposeFileSystem,
        mark: SourceMark?,
        path location: String
    ) throws -> Node {
        if let root = roots[path] { return root }
        guard fileSystem.fileExists(atPath: path) else {
            throw ParseError(
                reason: .unreadableFile,
                problem: "`\(written)` is named by `\(key)` and does not exist",
                mark: mark,
                path: location
            )
        }
        let text: String
        do {
            text = try fileSystem.contentsOfFile(atPath: path)
        } catch {
            throw ParseError(
                reason: .unreadableFile,
                problem: "`\(written)` could not be read: \(error.localizedDescription)",
                mark: mark,
                path: location
            )
        }
        let composed: Node?
        do {
            composed = try Yams.compose(yaml: text)
        } catch let error as YamlError {
            throw ParseError.yaml(error, file: displayName(for: path))
        }
        guard let composed, composed.mapping != nil else {
            throw ParseError(
                reason: .wrongShape,
                problem: "`\(written)`, named by `\(key)`, is not a compose file",
                mark: mark,
                path: location
            )
        }
        roots[path] = composed
        return composed
    }
}

/// One file as read: services still in layers, so that a later file in an include's path
/// list can be merged over them, and what that file included kept apart until it is settled.
struct LayeredFile {
    var name: String?
    var services: [(name: String, layer: ServiceLayer)] = []
    var networks: [String: NetworkSpec] = [:]
    var volumes: [String: VolumeSpec] = [:]
    var extensions: [String: ExtensionValue] = [:]
    /// Where each network and volume is declared, keyed `networks.<name>`, `volumes.<name>`.
    var marks: [String: SourceMark] = [:]
    var included: [FileFragment] = []

    /// `files` merged in order, each over the ones before it, which is how an include with a
    /// list of paths reads them.
    static func merge(_ files: [LayeredFile]) -> LayeredFile {
        var result = LayeredFile()
        for file in files {
            result.name = file.name ?? result.name
            for (name, layer) in file.services {
                if let index = result.services.firstIndex(where: { $0.name == name }) {
                    result.services[index].layer = result.services[index].layer.merged(under: layer)
                } else {
                    result.services.append((name, layer))
                }
            }
            // A network or volume is a handful of settings rather than a list, and the later
            // file's declaration replaces the earlier one whole.
            result.networks.merge(file.networks) { $1 }
            result.volumes.merge(file.volumes) { $1 }
            result.extensions.merge(file.extensions) { $1 }
            result.marks.merge(file.marks) { $1 }
            result.included += file.included
        }
        return result
    }
}

/// A settled part of the project: one file with everything it included.
struct FileFragment {
    var file: ComposeFile
    /// Where each definition came from, keyed `services.<name>`, `networks.<name>` and
    /// `volumes.<name>`, for errors that have to point at one.
    var marks: [String: SourceMark] = [:]
}

extension FileParser {
    /// `file`'s services settled, then everything it included copied in beside them.
    mutating func fragment(from file: LayeredFile) throws -> FileFragment {
        var fragment = FileFragment(
            file: ComposeFile(
                name: file.name,
                networks: file.networks,
                volumes: file.volumes,
                extensions: file.extensions
            ),
            marks: file.marks
        )
        for (name, layer) in file.services {
            fragment.file.services[name] = try finish(layer, name: name)
            fragment.marks["services.\(name)"] = layer.mark
        }
        for included in file.included {
            try absorb(included, into: &fragment)
        }
        return fragment
    }

    /// Copy what an include brought in.
    ///
    /// Compose resolves two definitions of one name by keeping whichever it met first, and
    /// says nothing. The service that runs would then depend on the order of an `include`
    /// list, silently, so a clash is refused instead. The same definition twice is no clash:
    /// that is one file reached along two paths.
    private func absorb(_ included: FileFragment, into fragment: inout FileFragment) throws {
        func check<T: Equatable>(_ kind: String, _ name: String, _ existing: T?, _ incoming: T) throws {
            guard let existing, existing != incoming else { return }
            let key = "\(kind)s.\(name)"
            throw ParseError(
                reason: .conflictingDefinition,
                problem: "\(kind) `\(name)` is defined at \(Self.describe(fragment.marks[key])) "
                    + "and differently at \(Self.describe(included.marks[key])); "
                    + "`include` copies definitions and does not merge them, so rename one or remove one",
                mark: included.marks[key],
                path: key
            )
        }
        for (name, service) in included.file.services {
            try check("service", name, fragment.file.services[name], service)
            fragment.file.services[name] = service
        }
        for (name, network) in included.file.networks {
            try check("network", name, fragment.file.networks[name], network)
            fragment.file.networks[name] = network
        }
        for (name, volume) in included.file.volumes {
            try check("volume", name, fragment.file.volumes[name], volume)
            fragment.file.volumes[name] = volume
        }
        fragment.marks.merge(included.marks) { existing, _ in existing }
    }

    private static func describe(_ mark: SourceMark?) -> String {
        guard let mark else { return "an unknown place" }
        return mark.file == nil ? "line \(mark.line)" : "`\(mark)`"
    }

    // MARK: - include

    /// Each entry is read as a project of its own: relative paths resolve against its
    /// directory, and its variables come from its own `.env`, with this project's variables
    /// over them.
    mutating func parseIncludes(_ node: Node) throws -> [FileFragment] {
        var fragments: [FileFragment] = []
        for (index, element) in try sequence(node, path: "include").enumerated() {
            let path = "include[\(index)]"
            var files: [String] = []
            var projectDirectory: String?
            var envFiles: [String]?
            if element.mapping == nil {
                files = [try string(element, path: path)]
            } else {
                for (keyNode, valueNode) in try mapping(element, path: path) {
                    let key = keyNode.scalar?.string ?? ""
                    switch key {
                    case "path": files = try parseStringOrList(valueNode, path: "\(path).path")
                    case "project_directory": projectDirectory = try string(valueNode, path: "\(path).project_directory")
                    case "env_file": envFiles = try parseStringOrList(valueNode, path: "\(path).env_file")
                    default:
                        if KeySupportTable.isExtensionKey(key) { continue }
                        noteUnknown(key: "include.\(key)", node: keyNode)
                    }
                }
            }
            guard !files.isEmpty else {
                throw ParseError(reason: .missingKey, problem: "an `include` entry needs a `path`", mark: mark(element), path: path)
            }

            let resolvedFiles = files.map { resolvePath($0, relativeTo: directory) }
            let entryDirectory = projectDirectory.map { resolvePath($0, relativeTo: directory) }
                ?? (resolvedFiles[0] as NSString).deletingLastPathComponent
            let entryInterpolator = try includeInterpolator(
                envFiles: envFiles,
                directory: entryDirectory,
                node: element,
                path: path
            )

            var layered: [LayeredFile] = []
            for (written, file) in zip(files, resolvedFiles) {
                if includeChain.contains(file) {
                    let chain = (includeChain + [file]).map { sources.displayName(for: $0) }
                    throw ParseError(
                        reason: .circularReference,
                        problem: "\(chain.map { "`\($0)`" }.joined(separator: " includes ")), which goes round in a circle",
                        mark: mark(element),
                        path: path
                    )
                }
                let root = try sources.root(
                    of: file,
                    writtenAs: written,
                    by: "include",
                    fileSystem: options.fileSystem,
                    mark: mark(element),
                    path: path
                )
                var parser = FileParser(
                    options: options,
                    interpolator: entryInterpolator,
                    directory: entryDirectory,
                    displayName: sources.displayName(for: file),
                    filePath: file,
                    root: root,
                    sources: sources,
                    includeChain: includeChain + [file]
                )
                layered.append(try parser.load())
                findings += parser.findings
                warnings += parser.warnings
            }
            fragments.append(try fragment(from: LayeredFile.merge(layered)))
        }
        return fragments
    }

    /// An include's `env_file` list, or the `.env` in its project directory, with this
    /// project's variables laid over it. Checked against `docker compose`: the shell beats
    /// this project's `.env`, which beats the included project's.
    private func includeInterpolator(
        envFiles: [String]?,
        directory entryDirectory: String,
        node: Node,
        path: String
    ) throws -> Interpolator {
        let entries = envFiles.map { $0.map { (written: $0, file: resolvePath($0, relativeTo: directory), required: true) } }
            ?? [(written: ".env", file: resolvePath(".env", relativeTo: entryDirectory), required: false)]
        var variables: [String: String] = [:]
        for entry in entries {
            guard options.fileSystem.fileExists(atPath: entry.file) else {
                if entry.required {
                    throw ParseError(
                        reason: .unreadableFile,
                        problem: "`\(entry.written)` is named by `include` and does not exist",
                        mark: mark(node),
                        path: "\(path).env_file"
                    )
                }
                continue
            }
            let text: String
            do {
                text = try options.fileSystem.contentsOfFile(atPath: entry.file)
            } catch {
                throw ParseError(
                    reason: .unreadableFile,
                    problem: "`\(entry.written)` could not be read: \(error.localizedDescription)",
                    mark: mark(node),
                    path: "\(path).env_file"
                )
            }
            for pair in DotEnv.parse(text) { variables[pair.key] = pair.value }
        }
        variables.merge(interpolator.variables) { $1 }
        return Interpolator(variables: variables)
    }
}
