import Foundation

/// The command-line tools Navigator Sync depends on.
public nonisolated enum CLIName: String, Sendable, CaseIterable {
    case jj
    case navigator

    /// The one-line install command shown to the user when the tool is missing.
    public var installHint: String {
        switch self {
        case .jj: return "brew install jj"
        case .navigator: return "brew install neon-law/navigator/navigator"
        }
    }
}

/// Failure to locate a required CLI.
public nonisolated enum CLILocatorError: Error, Sendable, Equatable {
    /// The named CLI was found neither on `PATH` nor in the Homebrew fallback.
    /// `installHint` is the command the user can run to install it.
    case missing(cli: CLIName, installHint: String)
}

/// Resolves the absolute path of a required CLI by searching `PATH` and then the
/// Apple-silicon Homebrew location.
///
/// Lookup order (Requirement 7 / Assumption A5):
/// 1. each directory in the `PATH` environment variable, in order;
/// 2. `/opt/homebrew/bin/<name>` as a fallback.
///
/// The `PATH` string and the file-existence probe are injected so the resolver
/// can be unit tested without depending on the host's real installation.
public nonisolated struct CLILocator: Sendable {
    /// Colon-separated search path (the value of `PATH`).
    private let searchPath: String
    /// Returns true when an executable file exists at the given absolute path.
    private let exists: @Sendable (String) -> Bool

    /// The Homebrew fallback directory for Apple silicon.
    public static let homebrewBin = "/opt/homebrew/bin"

    public init(
        searchPath: String,
        exists: @escaping @Sendable (String) -> Bool
    ) {
        self.searchPath = searchPath
        self.exists = exists
    }

    /// A locator backed by the current process environment and the file system.
    public static func live() -> CLILocator {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return CLILocator(searchPath: path) { candidate in
            var isDirectory: ObjCBool = false
            let present = FileManager.default.fileExists(
                atPath: candidate,
                isDirectory: &isDirectory
            )
            return present && !isDirectory.boolValue
        }
    }

    /// Resolves the absolute path of `cli`, or throws `.missing`.
    public func locate(_ cli: CLIName) throws -> URL {
        let name = cli.rawValue

        // 1. Search each non-empty PATH segment in order.
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = joinPath(String(directory), name)
            if exists(candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        // 2. Homebrew fallback.
        let fallback = joinPath(Self.homebrewBin, name)
        if exists(fallback) {
            return URL(fileURLWithPath: fallback)
        }

        throw CLILocatorError.missing(cli: cli, installHint: cli.installHint)
    }

    private func joinPath(_ directory: String, _ name: String) -> String {
        if directory.hasSuffix("/") {
            return directory + name
        }
        return directory + "/" + name
    }
}
