import Foundation

/// A matter the signed-in user can sync, as returned by the Navigator API
/// (`GET /app/api/projects`). `code` is the stable slug used as the on-disk
/// subfolder name; `repositoryURL` is nil until the Project's forge repository
/// has been provisioned.
public struct MatterDescriptor: Sendable, Identifiable, Equatable {
    public let id: String
    public let code: String
    public let name: String
    public let repositoryURL: String?
    public let status: String   // "open" | "closed" | "archived"

    public init(
        id: String,
        code: String,
        name: String,
        repositoryURL: String?,
        status: String
    ) {
        self.id = id
        self.code = code
        self.name = name
        self.repositoryURL = repositoryURL
        self.status = status
    }

    /// Only open matters are synced.
    public var isOpen: Bool { status == "open" }
}

/// The signed-in identity reported by `navigator site whoami`.
public struct Identity: Sendable, Equatable {
    public let email: String
    public let role: String
    public let tokenExpiry: Date?

    public init(email: String, role: String, tokenExpiry: Date?) {
        self.email = email
        self.role = role
        self.tokenExpiry = tokenExpiry
    }
}

/// Why a matter needs the user's attention. Carried by
/// `MatterStatus.needsAttention`.
public enum AttentionReason: Sendable, Equatable {
    case conflict
    case authFailure
    case pushRejected          // remote moved since last fetch (force-with-lease block)
    case cliMissing(String)
    case repositoryNotProvisioned
    case workingCopyProblem(String)
}

/// The status of one matter, shown in the menu.
public enum MatterStatus: Sendable, Equatable {
    case upToDate(lastSynced: Date)
    case syncing
    case offline
    case needsAttention(reason: AttentionReason)
}

/// A snapshot of a matter's jj repository state, parsed from `jj` template
/// output. Used by the sync engine to decide whether to rebase/push and whether
/// to flag a conflict.
public struct RepoState: Sendable, Equatable {
    public var hasConflict: Bool
    public var localAheadOfRemote: Bool
    public var remoteChangedSinceLastFetch: Bool

    public init(
        hasConflict: Bool,
        localAheadOfRemote: Bool,
        remoteChangedSinceLastFetch: Bool
    ) {
        self.hasConflict = hasConflict
        self.localAheadOfRemote = localAheadOfRemote
        self.remoteChangedSinceLastFetch = remoteChangedSinceLastFetch
    }
}

/// User-configurable sync settings. Defaults match the brief: a 60-second
/// interval, at most 4 concurrent syncs, and `main` as the push target bookmark
/// (Assumption A1), overridable per matter.
public struct SyncConfig: Sendable, Equatable {
    public var workFolder: URL?
    public var intervalSeconds: Int
    public var maxParallelSyncs: Int
    public var defaultBookmark: String
    public var bookmarkOverrides: [String: String]   // matter code -> bookmark
    public var host: String

    public init(
        workFolder: URL? = nil,
        intervalSeconds: Int = 60,
        maxParallelSyncs: Int = 4,
        defaultBookmark: String = "main",
        bookmarkOverrides: [String: String] = [:],
        host: String = "https://www.neonlaw.com"
    ) {
        self.workFolder = workFolder
        self.intervalSeconds = intervalSeconds
        self.maxParallelSyncs = maxParallelSyncs
        self.defaultBookmark = defaultBookmark
        self.bookmarkOverrides = bookmarkOverrides
        self.host = host
    }

    /// The push target bookmark for a given matter: its override if present,
    /// otherwise the default.
    public func bookmark(forMatterCode code: String) -> String {
        bookmarkOverrides[code] ?? defaultBookmark
    }
}
