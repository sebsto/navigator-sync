import Foundation

/// A projection of one matter's state for the UI.
public nonisolated struct MatterView: Sendable, Identifiable, Equatable {
    public let id: String
    public let code: String
    public let name: String
    public let status: MatterStatus
    public init(id: String, code: String, name: String, status: MatterStatus) {
        self.id = id
        self.code = code
        self.name = name
        self.status = status
    }
}

/// Runs the per-matter sync actors with bounded parallelism. A `maxParallel`
/// gate means at most N matters (hence N subprocesses) sync at once; a cycle
/// that fires while a previous one is still draining does not pile up work
/// because `syncDueMatters` only dispatches matters that are currently due and
/// not already syncing (the `MatterActor` guards re-entry itself).
public actor SchedulerActor {
    private let maxParallel: Int
    public init(maxParallel: Int) {
        self.maxParallel = max(1, maxParallel)
    }

    /// Sync the given matters, at most `maxParallel` at a time. Matters that are
    /// not due (backoff / already syncing) are skipped.
    public func syncDueMatters(_ matters: [MatterActor], now: Date = Date()) async {
        // Filter to due matters first, then run them N at a time.
        var due: [MatterActor] = []
        for actor in matters where await actor.isDue(now: now) {
            due.append(actor)
        }

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            let inFlightCap = min(maxParallel, due.count)
            while next < inFlightCap {
                let actor = due[next]
                group.addTask { await actor.sync(now: now) }
                next += 1
            }
            while await group.next() != nil {
                if next < due.count {
                    let actor = due[next]
                    group.addTask { await actor.sync(now: now) }
                    next += 1
                }
            }
        }
    }
}

/// Façade the UI talks to: owns the matter registry, runs discovery, drives the
/// scheduler, and publishes an immutable snapshot of matter views.
public actor SyncEngine {
    private let navigator: any NavigatorClient
    private let jj: any JJClient
    private var config: SyncConfig
    private let scheduler: SchedulerActor

    private var actorsByCode: [String: MatterActor] = [:]
    private var orderedCodes: [String] = []

    /// Set when the last discovery failed, so the UI can surface it without
    /// stopping existing matters from syncing.
    private(set) var lastDiscoveryError: String?

    public init(navigator: any NavigatorClient, jj: any JJClient, config: SyncConfig) {
        self.navigator = navigator
        self.jj = jj
        self.config = config
        self.scheduler = SchedulerActor(maxParallel: config.maxParallelSyncs)
    }

    /// Discover the user's matters: clone any missing open matter and register a
    /// `MatterActor`. A discovery failure is recorded but does not remove or
    /// stop already-registered matters (Requirement 2.4).
    public func discover() async {
        guard let workFolder = config.workFolder else {
            lastDiscoveryError = "No work folder configured"
            return
        }
        let matters: [MatterDescriptor]
        do {
            matters = try await navigator.listMatters()
            lastDiscoveryError = nil
        } catch {
            lastDiscoveryError = "Could not list matters"
            return   // keep existing matters syncing
        }

        for matter in matters where matter.isOpen {
            guard actorsByCode[matter.code] == nil else { continue }
            let dir = workFolder.appendingPathComponent(matter.code, isDirectory: true)

            let alreadyCloned = await jj.isValidRepo(dir)
            if !alreadyCloned {
                guard let url = matter.repositoryURL else {
                    // Not yet provisioned and nothing cloned: nothing to sync yet.
                    continue
                }
                do {
                    try await jj.clone(remoteURL: url, into: dir)
                } catch {
                    continue   // skip this matter; others still register
                }
            }

            let actor = MatterActor(
                descriptor: matter,
                repo: dir,
                jj: jj,
                bookmark: config.bookmark(forMatterCode: matter.code)
            )
            actorsByCode[matter.code] = actor
            orderedCodes.append(matter.code)
        }
    }

    /// Run one sync wave across all registered matters.
    public func syncNow(now: Date = Date()) async {
        let actors = orderedCodes.compactMap { actorsByCode[$0] }
        await scheduler.syncDueMatters(actors, now: now)
    }

    /// A snapshot of every registered matter for the UI, needs-attention first.
    public func snapshot() async -> [MatterView] {
        var views: [MatterView] = []
        for code in orderedCodes {
            guard let actor = actorsByCode[code] else { continue }
            let d = actor.descriptor
            let status = await actor.currentStatus()
            views.append(MatterView(id: d.id, code: d.code, name: d.name, status: status))
        }
        return views.sorted { lhs, rhs in
            attentionRank(lhs.status) < attentionRank(rhs.status)
        }
    }

    public func registeredCount() -> Int { actorsByCode.count }
    public func discoveryError() -> String? { lastDiscoveryError }

    private func attentionRank(_ s: MatterStatus) -> Int {
        switch s {
        case .needsAttention: return 0
        case .syncing: return 1
        case .offline: return 2
        case .upToDate: return 3
        }
    }
}
