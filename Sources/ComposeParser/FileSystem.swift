import Foundation

/// The parser's entire contact with the disk: `.env`, `env_file`, and the files `include`
/// and `extends` name.
///
/// It is a protocol so that a test can hand the parser a file set without writing anything to
/// a temporary directory, and so that an application embedding this can read files through
/// whatever it already uses for scoped access rather than through `FileManager` directly.
public protocol ComposeFileSystem: Sendable {
    func fileExists(atPath path: String) -> Bool
    func contentsOfFile(atPath path: String) throws -> String
}

/// The real filesystem.
public struct DiskFileSystem: ComposeFileSystem {
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func contentsOfFile(atPath path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }
}

/// Resolve a path written in a compose file against the project directory, the way compose
/// resolves everything relative: to the directory the file lives in, not the working
/// directory of whoever ran the command.
func resolvePath(_ path: String, relativeTo projectDirectory: String) -> String {
    if path.hasPrefix("~") {
        return (path as NSString).expandingTildeInPath
    }
    if path.hasPrefix("/") {
        return (path as NSString).standardizingPath
    }
    let base = URL(fileURLWithPath: projectDirectory, isDirectory: true)
    return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
}
