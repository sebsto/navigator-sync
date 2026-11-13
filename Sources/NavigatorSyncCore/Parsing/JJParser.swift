import Foundation

/// One row of `jj bookmark list --all-remotes -T '<name>\t<remote>\t<commit>\n'`.
/// `remote` is nil for a local bookmark (the template's remote field is empty).
public nonisolated struct BookmarkRow: Sendable, Equatable {
    public let name: String
    public let remote: String?
    public let commitID: String

    public init(name: String, remote: String?, commitID: String) {
        self.name = name
        self.remote = remote
        self.commitID = commitID
    }
}

/// Pure parsers for the machine-readable `jj` template output the sync engine
/// relies on. Human-formatted output is never parsed; every call site uses an
/// explicit `-T` template with tab/newline delimiters.
public nonisolated enum JJParser {

    /// Parses the conflict probe
    /// `jj log --no-graph -r '@' -T 'if(conflict,"1","0") ++ "\n"'`.
    /// Returns true only when the trimmed output is exactly `1`.
    public static func parseConflict(_ stdout: String) -> Bool {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Parses the bookmark listing
    /// `jj bookmark list --all-remotes -T 'name ++ "\t" ++ remote ++ "\t" ++ normal_target.commit_id().short() ++ "\n"'`.
    ///
    /// Each row is three tab-separated fields: name, remote (empty for a local
    /// bookmark), commit id. Blank lines are ignored; a line that does not have
    /// exactly three fields is skipped rather than treated as an error.
    public static func parseBookmarks(_ stdout: String) -> [BookmarkRow] {
        var rows: [BookmarkRow] = []
        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let name = String(fields[0])
            let remoteField = String(fields[1])
            let commitID = String(fields[2]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !commitID.isEmpty else { continue }
            rows.append(
                BookmarkRow(
                    name: name,
                    remote: remoteField.isEmpty ? nil : remoteField,
                    commitID: commitID
                )
            )
        }
        return rows
    }

    /// Computes the local-vs-remote relationship for `bookmark` against
    /// `remote`, given the parsed bookmark rows and the conflict probe.
    ///
    /// - `localAheadOfRemote` is true when the local bookmark's commit differs
    ///   from the remote-tracking bookmark's commit (there is local work to
    ///   push), or when the remote-tracking row is absent (nothing pushed yet).
    /// - `remoteChangedSinceLastFetch` is reported by the caller after a fetch;
    ///   here it is derived as false when local and remote already match. The
    ///   engine fetches first, so after a fetch a difference means the remote
    ///   moved and local must rebase onto it.
    public static func repoState(
        rows: [BookmarkRow],
        bookmark: String,
        remote: String,
        hasConflict: Bool
    ) -> RepoState {
        let local = rows.first { $0.name == bookmark && $0.remote == nil }
        let tracking = rows.first { $0.name == bookmark && $0.remote == remote }

        let localCommit = local?.commitID
        let remoteCommit = tracking?.commitID

        let ahead: Bool
        let remoteChanged: Bool
        switch (localCommit, remoteCommit) {
        case let (l?, r?):
            ahead = l != r
            remoteChanged = l != r
        case (_?, nil):
            // Nothing on the remote yet: local is ahead, remote unchanged.
            ahead = true
            remoteChanged = false
        case (nil, _?):
            // No local bookmark but a remote exists: remote has content to adopt.
            ahead = false
            remoteChanged = true
        case (nil, nil):
            ahead = false
            remoteChanged = false
        }

        return RepoState(
            hasConflict: hasConflict,
            localAheadOfRemote: ahead,
            remoteChangedSinceLastFetch: remoteChanged
        )
    }
}
