import Foundation

/// Owns the sync lifecycle of a single matter. An `actor` so one matter never
/// runs two syncs at once and its status transitions are race-free.
public actor MatterActor {
    public let descriptor: MatterDescriptor
    public let repo: URL
    private let jj: any JJClient
    private let remote: String
    private let bookmark: String

    private(set) var status: MatterStatus
    private var consecutiveFailures = 0
    private var nextEligible: Date = .distantPast
    private var isSyncing = false
    private var tracked = false

    /// Backoff: base 2s, doubled per failure, capped at 5 minutes.
    private let backoffBase: TimeInterval = 2
    private let backoffCap: TimeInterval = 300

    public init(
        descriptor: MatterDescriptor,
        repo: URL,
        jj: any JJClient,
        remote: String = "origin",
        bookmark: String
    ) {
        self.descriptor = descriptor
        self.repo = repo
        self.jj = jj
        self.remote = remote
        self.bookmark = bookmark
        self.status = .offline
    }

    public func currentStatus() -> MatterStatus { status }

    /// Whether this matter is due to sync now (not already syncing, past its
    /// backoff window).
    public func isDue(now: Date = Date()) -> Bool {
        !isSyncing && now >= nextEligible
    }

    /// Runs one sync cycle: fetch → (track once) → status → conflict? →
    /// rebase → push. Idempotent-safe; guards against re-entry.
    public func sync(now: Date = Date()) async {
        guard !isSyncing else { return }
        isSyncing = true
        status = .syncing
        defer { isSyncing = false }

        do {
            try await jj.fetch(repo: repo, remote: remote)

            if !tracked {
                try await jj.trackBookmark(bookmark, remote: remote, repo: repo)
                tracked = true
            }

            let state = try await jj.status(bookmark: bookmark, remote: remote, repo: repo)
            if state.hasConflict {
                status = .needsAttention(reason: .conflict)
                recordFailure(now: now)   // back off; don't hammer a conflicted repo
                return
            }

            // Rebase local work onto the freshly fetched remote position when the
            // remote moved; skip when nothing changed either side.
            if state.remoteChangedSinceLastFetch {
                try await jj.rebaseLocalOnto(bookmark: bookmark, remote: remote, repo: repo)
            }

            if state.localAheadOfRemote {
                let outcome = try await jj.push(bookmark: bookmark, remote: remote, repo: repo)
                switch outcome {
                case .pushed, .nothingToPush:
                    succeed(now: now)
                case .rejected:
                    status = .needsAttention(reason: .pushRejected)
                    recordFailure(now: now)
                case .authFailure:
                    status = .needsAttention(reason: .authFailure)
                    recordFailure(now: now)
                }
            } else {
                // Nothing to push; up to date.
                succeed(now: now)
            }
        } catch is JJError {
            // A jj command failed. Treat as needs-attention (not a transient
            // network blip) and back off.
            status = .needsAttention(reason: .workingCopyProblem("sync command failed"))
            recordFailure(now: now)
        } catch {
            // Anything else (e.g. the process could not be launched / network):
            // mark offline and back off so other matters keep going.
            status = .offline
            recordFailure(now: now)
        }
    }

    private func succeed(now: Date) {
        status = .upToDate(lastSynced: now)
        consecutiveFailures = 0
        nextEligible = now
    }

    private func recordFailure(now: Date) {
        consecutiveFailures += 1
        let delay = min(backoffCap, backoffBase * pow(2, Double(consecutiveFailures - 1)))
        nextEligible = now.addingTimeInterval(delay)
    }

    // Exposed for tests.
    func failureCount() -> Int { consecutiveFailures }
    func nextEligibleDate() -> Date { nextEligible }
}
