# Navigator Sync — Implementation Plan (tasks)

Small, ordered, testable tasks. Each lists the requirements it covers. Tests use
**Swift Testing** (`@Test`/`#expect`); the `NavigatorSyncCore` library targets
≥80% line coverage (Requirement 9). Build with `swift build`; test with
`swift test`. After each task: build, run tests, mark done.

Dependency note: the `Core` library (tasks 1–9) has no UI and is fully unit
testable with fakes — these are the parallelizable units. The app target (tasks
10–13) is sequential and built/verified in the parent. Task 1 must land first
(everyone imports the package); tasks 2–9 are then largely independent.

---

## Task 1 — Package skeleton & CI  (Req 10, 11, 9.4)
- `Package.swift`: tools 6.2, `.macOS(.v14)`, shared `swiftSettings`
  (`.swiftLanguageMode(.v6)`, `.enableUpcomingFeature("MemberImportVisibility")`,
  `.defaultIsolation(MainActor.self)`), `swift-subprocess` dependency on `Core`.
- Targets: `NavigatorSyncCore` (library), `NavigatorSync` (executable),
  `NavigatorSyncCoreTests` (test).
- `LICENSE-MIT`, `LICENSE-APACHE`, `README.md`, `scripts/coverage.sh`.
- A trivial `@Test` so `swift test` is green.
- **Done when:** `swift build` and `swift test` pass; coverage script runs.

## Task 2 — Models  (Req 1, 2, 5, A1, A7)
- `MatterDescriptor` (id, code, name, repositoryURL?, status), `Identity`,
  `MatterStatus`, `AttentionReason`, `RepoState`, `SyncConfig`.
- All `Sendable`, `Equatable` where useful.
- **Tests:** status equality/transitions; `SyncConfig` defaults (interval 60s,
  maxParallelSyncs 4, defaultBookmark `main`).

## Task 3 — `CommandRunner` on swift-subprocess  (Req 7.3, 8, 11.4, 11.5, A8)
- `CommandRunning` protocol + `SubprocessCommandRunner` (collected output,
  byte-capped), `CommandResult`.
- Timeout via task-group pattern + `cancelAll()`; `teardownSequence`
  SIGINT→SIGTERM→SIGKILL.
- `FakeCommandRunner` (scriptable exit/stdout/stderr, records argv).
- **Tests:** fake-level argv construction; a real runner smoke test against
  `/bin/echo` and a timeout test against `/bin/sleep` asserting teardown. No
  secrets/file bodies in any captured string.

## Task 4 — `CLILocator`  (Req 7, A5)
- Resolve `jj` / `navigator` on `PATH` then `/opt/homebrew/bin`; `missing(cli:)`
  error carrying the install hint.
- **Tests:** found via an injected PATH; missing → error with hint; homebrew
  fallback path.

## Task 5 — `jj` template parsers  (Req 3, 5, 9.2, A6)
- Pure functions: parse `jj log -T 'if(conflict,…)'`, `jj bookmark list
  --all-remotes -T …` into `RepoState` (hasConflict, localAheadOfRemote,
  remoteChangedSinceLastFetch).
- **Tests:** recorded sample strings — clean, conflict, empty repo, malformed
  line, multi-remote — each asserting the typed result (table-driven `@Test`).

## Task 6 — `SubprocessJJClient`  (Req 3, 5, A6)
- Implement `JJClient` over `CommandRunner`+`CLILocator`: fetch, bookmark-track,
  rebase onto `<bm>@origin`, push `--bookmark`, status (via task 5 parsers),
  isValidRepo, clone. Map push-rejected/auth/conflict to typed outcomes.
- **Tests:** with `FakeCommandRunner` assert exact argv per operation and that a
  rejected-push stderr maps to `.pushRejected`, auth stderr to `.authFailure`.

## Task 7 — `SubprocessNavigatorClient` + REST  (Req 2, 7, A2, A3)
- `whoami()` → `navigator site whoami`; `listMatters()` → `GET /app/api/projects`
  decoding `Project` rows (open only), host configurable; `clone` delegates to
  `JJClient`.
- **Tests:** decode a recorded `[]` and a populated fixture payload; whoami
  signed-in vs not; 403/empty handled as states not crashes.

## Task 8 — `MatterActor`  (Req 3, 4.2, 4.3, 5)
- One actor/matter: state machine (idle→syncing→upToDate/offline/needsAttention),
  the fetch→track→conflict-check→rebase→push sequence, skip-when-nothing-to-sync,
  per-matter exponential backoff, no re-entrant sync.
- **Tests:** clean sync→upToDate; conflict→needsAttention(.conflict);
  push-rejected→.pushRejected; thrown network→offline + backoff advances;
  already-syncing guard.

## Task 9 — `SchedulerActor` + `SyncEngine`  (Req 2, 3, 4)
- Scheduler: interval timer, bounded parallelism (`maxParallelSyncs`), coalescing,
  "sync now", owned cancellable task (cancel on teardown).
- Engine façade: discovery (diff listMatters vs subfolders → clone missing,
  register actors; discovery failure keeps existing syncing), publishes an
  immutable snapshot stream to the UI.
- **Tests:** injected clock → at most N concurrent; up-to-date skipped;
  coalescing on overlapping ticks; discovery adds a new matter; discovery throw
  leaves existing matters running. **Coverage gate check here: ≥80% on Core.**

## Task 10 — App shell & theme  (Req 11, 13)
- `@main` App, `.accessory` policy via `@NSApplicationDelegateAdaptor`; theme
  engine (`@MainActor @Observable`, Reduce Motion/Transparency/Increase Contrast);
  centralized `SFSymbols`; capsule/ghost `ButtonStyle`s.
- **Done when:** app launches to a menu-bar item.

## Task 11 — Onboarding wizard  (Req 1, 7, 12, 13)
- `OnboardingStep` enum + `SetupCoordinator`; steps welcome → work folder
  (`NSOpenPanel`) → tools check (CLILocator, copy-command + re-check) → sign-in
  check (whoami, re-check) → ready; blocking, resume-from-last-step; window via
  `NSWindow(contentViewController:)` at `.floating`.
- **Tests:** step pass/block logic with fake CLILocator + fake NavigatorClient
  (no display).

## Task 12 — Menu bar UI  (Req 5, 6, 13)
- `NSStatusItem` controller with dynamic status icon; matter rows (symbol+label,
  needs-attention first), per-matter "Open in Finder" + "Sync now", global "Sync
  now", "Settings…", "Re-run setup…". Disable a matter's "Sync now" while syncing
  (wispr #99). Bind to the engine's snapshot stream.
- **Done when:** menu reflects live status; actions work against the fake dataset.

## Task 13 — Settings + persistence  (Req 1, 4, A1)
- `SettingsView` (work folder, interval, parallelism, default bookmark);
  `SyncConfig` persisted per-key to `UserDefaults` (injected); work folder as a
  security-scoped bookmark.
- **Tests:** round-trip persistence with an injected defaults suite.

## Task 14 — Integration against the fake dataset  (DoD)
- Wire it end to end; run `fixtures/make-fake-dataset.sh`; verify clone, status,
  two-clone propagation within two cycles, a flagged matter stays flagged while
  others sync.
- **Done when:** DoD bullets pass; README setup/build/run verified; the
  "what works / assumed / left for v1" summary written.

---

### Parallelization map (how subagents are used)
- **Must be first, in parent:** Task 1 (defines the package everyone compiles
  against) and it is pushed so clones see it.
- **Parallelizable (independent Core units, after Task 1):** Tasks 4, 5 are fully
  independent; 2 is a shared dep so it lands first (parent). 3 is independent of
  4/5. 6 depends on 3+5; 7 depends on 3; 8 depends on 2+6; 9 depends on 8.
- **Sequential, in parent (shared app target + one clone, UI not unit-drivable
  headless):** Tasks 10–14.
- Every subagent clones the repo ITSELF (a subagent cannot see the parent's
  scratch clone) and pushes a branch; the parent verifies each branch/PR on the
  forge before trusting completion and integrates.
