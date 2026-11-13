# Navigator Sync — Design

## Overview

Navigator Sync is a SwiftUI `MenuBarExtra` app for macOS 14+ (Apple silicon)
that keeps a local work folder in sync with every Jujutsu matter repository of
the signed-in Navigator user. It shells out to the `jj` and `navigator` CLIs as
subprocesses behind Swift protocols, drives sync with Swift concurrency (one
actor per matter plus a scheduler actor), and surfaces per-matter status in the
menu. Both CLIs are installed and their interfaces verified on the build host
(`jj` 0.47.1, `navigator` 26.11.10). Subprocess execution uses Apple's
open-source **`swift-subprocess`** package (not `Foundation.Process`), per the
user's requirement.

This document covers the project layout decision, the component architecture,
the concurrency model, the data/state flow, `jj` command and template contracts,
error handling, and the testing approach. Assumptions A1–A7 from
`requirements.md` are referenced at the point where each is encapsulated.

### Verified environment facts (recorded at spec time)

Checked on the build host before writing this design:

- `jj` installed via Homebrew is **0.47.1** (`/opt/homebrew/bin/jj`).
- `jj log -T <template>` and `jj bookmark list -T <template>` emit stable,
  delimiter-controlled output. `change_id.short()`, `commit_id.short()`,
  `description.first_line()`, and the boolean keyword `conflict` are all
  available and used below.
- `jj git push --bookmark <name> --remote <remote>` pushes a specific bookmark
  with a built-in force-with-lease-style safety check: the remote only moves if
  it matches what `jj` last fetched, otherwise the push is rejected (this is how
  we detect "needs attention: remote moved / rejected").
- `jj git fetch` defaults to remote `origin` when one remote exists.
- The **`navigator` CLI IS available** and installed on the build host:
  `brew install neon-law/navigator/navigator`, version **26.11.10**
  (`/opt/homebrew/bin/navigator`). Assumption A2 is now **confirmed** (see the
  "Navigator CLI & API contract" section). The relevant surface:
  - `navigator site login --host <HOST>` authenticates; the token is stored at
    `~/.navigator.json`. `navigator site whoami` reports the stored identity and
    token expiry; `navigator site logout` forgets it.
  - `navigator project drift --dir <DIR> --json` reconciles the local checkouts
    in `<DIR>` (one per Project) against the live Project rows and emits a JSON
    report — this is the discovery + status-diff source.
  - `navigator project watch --dir <DIR> --host <HOST>` watches open Projects,
    fetches remote bookmarks, and downloads document revisions into `<DIR>`.
  - Behind the CLI is a documented REST API. `GET /app/api/projects`
    ("List the caller's matters") returns `Project` rows; each carries `id`,
    `code` (stable slug, e.g. `acme-llc-formation`), `name`,
    `status` (`open`/`closed`/`archived`), and `repository_url` (the Project's
    one source repository as a whole forge URL, or `null` before it is
    provisioned). Auth is a JWT bearer token or the `navigator_session` cookie.

## House style — aligned with `sebsto/wispr`

The same author (sebsto) ships `wispr`, a macOS menu-bar SwiftUI app with an
onboarding wizard — the closest existing precedent (read from the repo, not
assumed). Navigator Sync follows its conventions:

- **Package setup:** `swift-tools-version: 6.2` with a shared `swiftSettings`
  applied to **every** target: `.swiftLanguageMode(.v6)`,
  `.enableUpcomingFeature("MemberImportVisibility")`, and
  **`.defaultIsolation(MainActor.self)`**. Default-MainActor isolation means UI
  and coordinators are MainActor without annotation; `actor` is reserved for
  genuine background/shared-mutable work (here: the per-matter sync and the
  scheduler). This is the idiom to match (Requirement 11).
- **Target split:** a `Core` library (shared types, clients, engine, parsing —
  the testable logic) + a thin app executable + a test target importing both.
  Mirrors the `NavigatorSyncCore` / `NavigatorSync` plan exactly.
- **Menu bar:** wispr uses **`NSStatusItem` + `NSMenu`** (not `MenuBarExtra`)
  with `NSApplication.setActivationPolicy(.accessory)` via
  `@NSApplicationDelegateAdaptor`, because `MenuBarExtra` cannot render dynamic
  status icons. See the menu-bar decision below.
- **Windows (onboarding/settings) opened imperatively** from the app delegate
  with `NSWindow` + `NSHostingController` (SwiftUI `Window`/`Settings` scenes do
  not reliably open in an `.accessory` app). The onboarding window uses
  `.floating` level + `NSApp.activate()` so it stays above System Settings while
  the user grants prerequisites.
- **Onboarding pattern:** an `OnboardingStep` enum (`CaseIterable`, `rawValue`
  ordering), a step indicator (dots + "Step X of N"), direction-aware slide+fade
  transitions gated on Reduce Motion, a Back/Continue/Skip nav bar with
  `Continue` disabled until the step's prerequisite is met, and
  **resume-from-last-step** persisted in settings (a force-quit mid-setup
  resumes; an already-satisfied step is skipped on resume). Adopted directly.
- **Theming:** a single `@MainActor @Observable` theme engine is the source of
  truth for semantic colors/materials, reading Reduce Motion, Reduce
  Transparency, and Increase Contrast and exposing adapted colors
  (`primaryTextColor`, `secondaryTextColor`, `borderColor`, `successColor`,
  `accentColor`), read by views via `.environment`. Mirrored rather than
  hardcoding colors (Requirement 13.3–13.5).
- **Icons:** a centralized `SFSymbols` enum of symbol-name constants — never
  emoji, never inline literals at call sites (Requirement 13.2).
- **Controls:** custom `ButtonStyle`s (capsule primary, ghost secondary) with
  `minHeight: 44`, press-scale feedback, `@ScaledMetric` sizing for Dynamic
  Type, and `.accessibilityLabel`/`.accessibilityHint` on every control
  (Requirement 13.5).
- **Concurrency idioms:** structured concurrency only — no `Task.detached`, no
  GCD/Combine. Long-lived observation is a cancellable `Task` driving a
  `withObservationTracking` loop; streaming uses `AsyncStream`.
- **Testing:** Swift Testing (`@Test`, `#expect`), fakes/stubs over mocking
  frameworks (confirms Requirement 9.4).
- **Comments:** doc comments say what the type does and why it exists now — no
  development history — consistent with the saved house rule.

### Bugs from `sebsto/wispr` PR history to NOT reproduce

Mined from wispr's merged PRs (ASR/model/local-AI fixes excluded as out of
scope). Each is a concurrency, code-style, or UI mistake already paid for once;
the design avoids it by construction.

Concurrency:
- **No `Task.detached` to move work off `@MainActor`** (wispr #96). It cuts the
  task off from the caller's priority, task-local values, and cancellation. To
  leave the main actor, `await` into an `actor` (our `MatterActor` /
  `SchedulerActor`), never `Task.detached`. Matches the house "structured
  concurrency only" rule.
- **Own every fire-and-forget `Task`; cancel on terminate** (wispr #26, #9).
  Long-lived tasks (the scheduler loop, any observation loop) are stored on the
  owner and cancelled in `applicationWillTerminate` / on teardown, not spawned
  unowned. Our `SchedulerActor` holds its timer task and stops it explicitly.
- **Make repeated operations idempotent** (wispr #71). wispr re-ran expensive
  work when the target was already current. Our sync already short-circuits a
  matter with nothing to do (Requirement 3.4) — keep that: no fetch/push churn
  when local == remote.

Code style:
- **No force-unwrap / force-cast in production** (wispr #26). Use `guard let` /
  typed `throws`. Our parsers return typed values or throw on malformed
  `jj -T` output — never `!` on a split result.
- **No static-function utility enums where an instance/protocol fits** (wispr
  #26). Clients are protocol instances (`JJClient`, `NavigatorClient`), not
  caseless enums of statics — this is also what makes them fakeable.
- **Granular persistence:** each setting persists its own `UserDefaults` key in
  `didSet`, not a re-serialize-everything-on-any-change blob (wispr #26).
- **Inject `UserDefaults`** into the settings store rather than reaching for
  `.standard`, so tests use a clean suite (wispr #26).
- **Fixed `ForEach` ranges / stable ids** in SwiftUI lists (wispr #26) — matter
  rows key on the stable matter `id`, never an array index.

UI / AppKit integration:
- **Create windows with `NSWindow(contentViewController:)`**, never
  `NSWindow()` then assign `contentViewController` separately — the latter
  crashes (SIGTRAP) when the SwiftUI hosting view triggers a premature
  constraint pass (wispr #47). The onboarding and settings windows use the
  one-shot initializer.
- **Accessory-app windows need explicit front/focus:** set `.floating` level and
  call `NSApp.activate()` so the onboarding/settings window appears on top with
  focus (wispr #23, and the floating-level note in #2/the app delegate).
- **Disable `NSMenu` automatic item enablement** and drive enabled/disabled
  state explicitly, or AppKit re-enables items you meant to keep disabled (wispr
  #99). Our "Sync now" per matter is explicitly disabled while that matter is
  already syncing.
- **Keep the theme engine AppKit-free**; isolate appearance/accessibility
  monitoring (KVO on effective appearance, workspace notifications) in a
  separate monitor type (wispr #86). Our theme type is pure; a small monitor
  feeds it.
- **Prefer the Accessibility framework over `NSAccessibility.post`** for
  announcements on macOS 14+ (wispr #86).

## Project layout decision: SwiftPM, not an Xcode project

**Decision: Swift Package Manager**, with an executable target that builds the
`.app` via a thin SwiftUI `App` entry point.

Justification:
- The brief values testability and a clean README build. SPM gives
  `swift build` / `swift test` out of the box with no `.xcodeproj` to keep in
  sync, which is better for an open-source MVP that others clone and build.
- The sync engine, CLI adapters, and parsers are plain Swift with no UIKit/AppKit
  storyboards; they live in a library target (`NavigatorSyncCore`) that the test
  target imports directly. The UI is a thin `MenuBarExtra` executable target
  (`NavigatorSync`) depending on that library.
- `MenuBarExtra` / `NSStatusItem` and the Swift 6 concurrency we need are fully
  supported from a SwiftPM executable target with `// swift-tools-version:6.2`
  and a shared `swiftSettings` on every target — `.swiftLanguageMode(.v6)`,
  `.enableUpcomingFeature("MemberImportVisibility")`,
  `.defaultIsolation(MainActor.self)` — matching wispr, so the whole package
  builds under complete concurrency checking with MainActor-by-default
  isolation (Requirement 11).

Trade-off: a SwiftPM-built menu bar app produces a bare executable, not a
code-signed `.app` bundle with an `Info.plist` by default. For the MVP we run
the executable directly (`swift run`) and document a minimal `Info.plist` /
`LSUIElement` note in the README so it runs as an agent (no Dock icon). Signing
and bundling are explicitly out of scope. Note the onboarding wizard
(Requirement 12) needs a real foreground window at first launch even though the
steady-state app is a menu-bar agent. Following wispr, that window is created
**imperatively** from the app delegate with `NSWindow` + `NSHostingController`
at `.floating` level (plus `NSApp.activate()`), not a SwiftUI `Window` scene —
SwiftUI scenes do not reliably open in an `.accessory` app, and the floating
level keeps the wizard above System Settings while the user grants permissions.

### Menu bar: `NSStatusItem` (confirmed) — `MenuBarExtra` can't meet the requirement

The brief asks for a SwiftUI `MenuBarExtra`. Requirement 5 needs the menu-bar
element itself to reflect overall state — a distinct icon/badge/tint when any
matter needs attention. `MenuBarExtra`'s label is static-ish and cannot render a
dynamic, state-driven status icon the way an `NSStatusItem.button` image can;
this is the same limitation wispr's CLAUDE.md records. **Decision (confirmed by
the user): use `NSStatusItem` + `NSMenu`**, driven by an `@MainActor @Observable`
controller, with rich menu content (matter rows, status, actions) hosted as pure
SwiftUI via `NSHostingView`/`NSMenuItem`. This follows the rule "follow wispr if
the requirement isn't possible with `MenuBarExtra`." The choice is contained in
the app target and does not touch the `Core` library or the engine.

### Package structure

```
Package.swift
Sources/
  NavigatorSyncCore/        # library: engine, clients, models, parsing (testable)
    Models/                 # Matter, MatterStatus, SyncConfig
    Clients/                # JJClient, NavigatorClient protocols + Subprocess impls
    Parsing/                # jj template parsers
    Engine/                 # MatterActor, SchedulerActor, SyncEngine
    Support/                # CLILocator, CommandRunner (swift-subprocess), Logger
  NavigatorSync/            # executable: @main App, MenuBarExtra, onboarding wizard, Settings
    Onboarding/             # SetupCoordinator + wizard step views (pure SwiftUI)
    Menu/                   # MenuBarExtra content, matter rows, status views
    Settings/               # SettingsView
Tests/
  NavigatorSyncCoreTests/   # fakes + unit tests for engine and parsers
README.md
LICENSE-MIT
LICENSE-APACHE
```

## Components

### 1. CLI abstraction layer (protocols + subprocess adapters)

Everything that touches a CLI goes through a protocol so tests inject fakes
(Requirement 9). Methods are `async` and `throws`.

```swift
protocol JJClient: Sendable {
    func fetch(repo: URL) async throws
    func rebaseLocalOnto(bookmark: String, repo: URL) async throws
    func push(bookmark: String, remote: String, repo: URL) async throws -> PushOutcome
    func status(repo: URL) async throws -> RepoState   // parsed from templates
    func isValidRepo(_ repo: URL) async -> Bool
}

protocol NavigatorClient: Sendable {
    func whoami() async throws -> Identity               // confirms sign-in (A3)
    func listMatters() async throws -> [MatterDescriptor] // GET /app/api/projects
    func clone(_ matter: MatterDescriptor, into dir: URL) async throws
}
```

- `SubprocessJJClient` and `SubprocessNavigatorClient` are the real adapters.
  They build argument arrays (never shell strings — no injection surface) and run
  through a single `CommandRunner` built on **`swift-subprocess`** (see the
  dedicated section below) that captures stdout/stderr/exit code with a timeout.
- `SubprocessNavigatorClient` wraps the confirmed `navigator` CLI commands
  (Assumption A2, now verified — see "Navigator CLI & API contract" below):
  - `whoami()` → `navigator site whoami --host <HOST>` (non-zero / "no stored
    logins" → surface a sign-in-required state, A3).
  - `listMatters()` → `GET /app/api/projects` (authorized for the signed-in
    user's own role; returns their matters, or an empty list), mapping each
    row's `code`/`id`/`name`/`repository_url`/`status` to a `MatterDescriptor`
    (open matters only). `navigator project drift --json` is not used here (it
    needs an elevated firm role — 403 for a client).
  - `clone(_:into:)` → clone the matter's `repository_url` into
    `<workFolder>/<code>` using `jj git clone <repository_url> <dir>` (we keep
    cloning in the `jj` layer so the local repo is a first-class `jj` repo our
    sync path understands).
  The host (`https://www.neonlaw.com` by default, configurable) is a single
  setting, isolating the one coordinate most likely to differ per deployment.

### 1a. Subprocess execution (`CommandRunner` on `swift-subprocess`)

Per the user's requirement, all process execution uses Apple's open-source
**`swift-subprocess`** package (not `Foundation.Process`). It is built on Swift
concurrency, returns `Sendable` results, and gives first-class async output
capture, timeouts, and cancellation teardown — a direct fit for the actor-based
engine.

- **Dependency:** `.package(url: "https://github.com/swiftlang/swift-subprocess.git", .upToNextMinor(from: "0.4.0"))`
  (1.0 line requires Swift 6.2 / Xcode 26, which the project already targets);
  the `Core` library target depends on
  `.product(name: "Subprocess", package: "swift-subprocess")`. The
  `SubprocessFoundation` trait (default) is fine.
- **`CommandRunner`** is a thin `Sendable` wrapper exposing one method the
  clients call:

  ```swift
  struct CommandResult: Sendable {
      var exitCode: Int32
      var standardOutput: String   // captured, bounded
      var standardError: String    // captured, bounded
  }

  protocol CommandRunning: Sendable {
      func run(
          executable: URL,           // absolute path from CLILocator
          arguments: [String],       // argv array — never a shell string
          workingDirectory: URL?,    // the matter repo for jj calls
          environment: [String: String]?,
          timeout: Duration
      ) async throws -> CommandResult
  }
  ```

- **Real implementation** calls `swift-subprocess`:

  ```swift
  let result = try await run(
      .path(FilePath(executable.path)),
      arguments: Arguments(arguments),
      environment: environment.map { .inherit.updating($0) } ?? .inherit,
      workingDirectory: workingDirectory.map { FilePath($0.path) },
      output: .string(limit: outputByteCap),
      error: .string(limit: outputByteCap)
  )
  // result.terminationStatus → exitCode; result.standardOutput / .standardError
  ```

  We use the **collected-output** form (`.string(limit:)`) for the short,
  bounded `jj -T` / `navigator` outputs, with an explicit byte `limit` so a
  runaway process can't blow up memory (the package throws if output exceeds the
  limit). The `limit` doubles as privacy hygiene — we only ever keep bounded,
  classified diagnostics, never file bodies (Requirement 8).
- **Timeout & cancellation:** each call runs inside a timeout; on cancellation
  (e.g. app quit, or the scheduler cancelling a wave) `swift-subprocess`'s
  `PlatformOptions.teardownSequence` sends `SIGTERM` then `SIGKILL`, so a hung
  `jj`/`navigator` never lingers. This is why we don't hand-roll `Process`
  teardown.
- **Testability:** `CommandRunning` is a protocol; the real runner is the only
  place `swift-subprocess` is imported. `JJClient`/`NavigatorClient` fakes don't
  even need it — but a `FakeCommandRunner` also exists for adapter-level tests
  that exercise argument construction without launching anything.
- **Injection safety:** arguments are always passed as an `Arguments` array
  built from `[String]`; no `/bin/sh -c`, no string interpolation into a command
  line, so matter codes/paths with spaces or shell metacharacters are safe.

#### Subprocess concurrency (thread-safe output, interruption, timeout)

The three concurrency questions, answered against the `swift-subprocess` API and
Swift 6 structured-concurrency rules. The guiding principle: **don't hand-roll
pipe draining or signal handling — the library owns the thread-safe parts; we
own the structured-concurrency scaffolding around it.**

- **Thread-safe stdout/stderr collection.** For our calls the output is short
  and bounded (`jj -T` templates, `navigator` JSON), so we use the
  **collected-output** form and let the library do the concurrent, race-free pipe
  draining internally:
  ```swift
  let result = try await run(
      .path(FilePath(exe)), arguments: Arguments(argv),
      workingDirectory: wd.map(FilePath.init),
      output: .string(limit: cap), error: .string(limit: cap))
  // result.standardOutput, result.standardError are already fully collected
  ```
  This sidesteps the classic `Foundation.Process` deadlock (parent blocks reading
  one pipe while the child blocks writing the other): `swift-subprocess` reads
  both concurrently. We never touch a shared mutable buffer, so there is no data
  race to guard — the result is a `Sendable` value handed back across the `await`.
  **If** we ever need to stream (we don't for the MVP), the correct pattern is a
  `withThrowingTaskGroup` draining `execution.standardOutput` and
  `execution.standardError` on **separate child tasks** — because a
  `SubprocessOutputSequence`/`AsyncStream` is single-consumer, reading both on one
  loop would serialize and risk a full-pipe stall. We note this so a future
  streaming need doesn't get it wrong; the MVP stays with collected output.
- **Interrupting a process.** Interruption is driven by **Swift task
  cancellation**, not manual signal code. `swift-subprocess` ties the child's
  lifetime to the awaiting task: when that task is cancelled it runs
  `PlatformOptions.teardownSequence`. We configure:
  ```swift
  var platformOptions = PlatformOptions()
  platformOptions.teardownSequence = [
      .send(signal: .interrupt, allowedDurationToNextStep: .seconds(2)),
      .gracefulShutDown(allowedDurationToNextStep: .seconds(3)), // SIGTERM
  ]   // sequence always ends by sending a kill signal
  ```
  So cancelling the task that owns a `jj`/`navigator` call sends SIGINT → SIGTERM
  → SIGKILL on a timer, and a hung CLI never lingers. Cancellation sources, all
  structured: the owning `MatterActor`'s sync task is cancelled when the app quits
  or the user removes a matter; the `SchedulerActor` cancels an in-flight wave via
  the task group's `cancelAll()` when a newer "Sync now" supersedes it.
- **Timeout.** Each call is wrapped in the task-group timeout pattern (one child
  runs the subprocess, one runs `Task.sleep(for: timeout)` and throws
  `TimeoutError`; the first to finish wins and `group.cancelAll()` cancels the
  loser). Because the loser is the subprocess child, its cancellation triggers the
  teardown sequence above — the timeout doesn't just abandon a running process, it
  actively tears it down. `cancelAll()` is mandatory here (per the concurrency
  skill): without it the losing task runs to scope exit.
- **Isolation / Sendability.** `CommandRunner` is a `Sendable` struct with no
  mutable state; `CommandResult` is a `Sendable` value type. The runner is called
  from inside `MatterActor`/`SchedulerActor` (actors), and the `run(...)` call is
  a normal `await` suspension — no `nonisolated(unsafe)`, no `DispatchQueue`, no
  `Task.detached`. Under the package's `.defaultIsolation(MainActor.self)`, the
  runner's method is explicitly `nonisolated` async so it does not hop to the main
  actor to launch a process (we don't want subprocess I/O on `@MainActor`).
- **Concurrency limit interaction.** The `SchedulerActor` already caps concurrent
  syncs at `maxParallelSyncs` (default 4) via its task-group gate; each running
  task owns exactly one subprocess at a time, so at most N child processes exist
  at once — bounded by construction, not by hoping the OS copes.

These patterns come straight from the Swift Concurrency skill the user provided
(task cancellation, the task-group timeout with `cancelAll()`, single-consumer
`AsyncStream`, structured over detached) applied to the `swift-subprocess` API.

### 2. CLI discovery (`CLILocator`)

Implements Requirement 7 / Assumption A5. Resolves `jj` and `navigator` by:
1. searching `PATH`, then 2. checking `/opt/homebrew/bin/<name>`. Returns a
resolved absolute path or a `missing(cli:)` error carrying an install hint
("brew install jj" / Neon Law's install instructions). The UI shows this as a
blocking banner and disables syncs that need the missing CLI.

### 3. Models and state

```swift
struct MatterDescriptor: Sendable, Identifiable {  // from NavigatorClient
    let id: String            // live Project id
    let code: String          // stable slug → subfolder name (A7), e.g. acme-llc-formation
    let name: String          // display name
    let repositoryURL: String?// Project.repository_url; nil = not yet provisioned
    let status: String        // open / closed / archived — sync open only
}

struct Identity: Sendable, Equatable {   // from `navigator site whoami`
    let subject: String
    let tokenExpiry: Date?
}

enum MatterStatus: Sendable, Equatable {
    case upToDate(lastSynced: Date)
    case syncing
    case offline
    case needsAttention(reason: AttentionReason)
}

enum AttentionReason: Sendable, Equatable {
    case conflict
    case authFailure
    case pushRejected        // remote moved since fetch (force-with-lease block)
    case cliMissing(String)
    case workingCopyProblem(String)
}

struct RepoState: Sendable {          // parsed jj status snapshot
    let hasConflict: Bool
    let localAheadOfRemote: Bool
    let remoteChangedSinceLastFetch: Bool
}

struct SyncConfig: Sendable {
    var workFolder: URL?
    var interval: Duration = .seconds(60)
    var maxParallelSyncs: Int = 4           // Requirement 4.1
    var defaultBookmark: String = "main"    // Assumption A1
    var bookmarkOverrides: [String: String] = [:]  // matterID → bookmark (A1)
}
```

`SyncConfig` persists via `UserDefaults` (JSON-encoded); the work-folder path is
stored as a security-scoped bookmark so the sandbox-free MVP can still reopen it
after relaunch.

### 4. Sync engine — concurrency model

Swift 6 language mode with **complete** strict concurrency checking and zero
warnings (Requirement 11). Structured concurrency throughout: actors,
`async`/`await`, and task groups for fan-out. No `nonisolated(unsafe)`, no
`Task.detached`, no `DispatchQueue`, no other escape hatch to silence a
diagnostic (house rule). Any shared mutable state not owned by an actor uses
`Synchronization.Mutex`. Three actors:

**`MatterActor`** — one instance per matter. Owns that matter's state machine and
serializes its sync so two syncs of the same matter never overlap
(Requirement 4.2). A `sync()` call does:
1. set status `.syncing`, publish.
2. `jj git fetch` (A6).
3. read `RepoState` via templates; if `hasConflict` → `.needsAttention(.conflict)`
   and stop (detect-and-flag only; no resolution — out of scope).
4. `rebaseLocalOnto(defaultBookmark or override)` (A1).
5. if `localAheadOfRemote` (or remote unchanged skip, Requirement 3.4) →
   `push(bookmark:remote:)`; map a rejected push to `.pushRejected`, an auth
   error to `.authFailure`.
6. on success → `.upToDate(Date())`; reset backoff.
7. on any error → classify (offline vs needs-attention) and apply exponential
   backoff (Requirement 4.3): next-eligible time = now + min(cap, base·2^failures).

**`SchedulerActor`** — owns the timer and a bounded worker pool. Every
`interval` it asks the engine for matters due to sync (respecting per-matter
backoff and skipping those already syncing), then dispatches them through an
`AsyncSemaphore`-style gate of `maxParallelSyncs` (Requirement 4.1). If a tick
fires while the previous batch is still draining, it coalesces: it does not
enqueue a matter that is already queued or running (Requirement 4.4). "Sync now"
calls the same dispatch path immediately (Requirement 3.5, 6.2).

**`SyncEngine`** (actor) — the façade the UI talks to. Holds the registry of
`MatterActor`s, runs discovery, owns `SchedulerActor`, and publishes an immutable
`[MatterView]` snapshot the SwiftUI layer renders. Discovery (Requirement 2):
diff `navigator listMatters()` against subfolders; clone missing ones; register a
`MatterActor` per valid repo; a discovery failure is surfaced but does not stop
syncing existing matters (Requirement 2.4).

State flows **engine → UI** via an `AsyncStream<[MatterView]>` (or an
`@Observable` snapshot holder updated on the main actor); the UI never mutates
engine state directly, it only sends intents ("sync now", "set work folder").

Scale note (Assumption A4): with 200 matters and `maxParallelSyncs = 4`, a cycle
processes matters in waves; skipping up-to-date matters (Requirement 3.4) and
backoff keep steady-state work small. The actor-per-matter model is cheap
(actors are not threads); 200 actors is fine.

### 5. UI (pure SwiftUI: onboarding wizard + `MenuBarExtra`)

The entire UI is **pure SwiftUI** (Requirement 13.1). AppKit is touched only for
two system calls SwiftUI has no native equivalent for — `NSOpenPanel` (folder
picker) and `NSWorkspace.open` (reveal in Finder) — invoked from SwiftUI code.
Status uses SF Symbols, never emoji; colors come from the system palette so light
and dark mode both read correctly; every status pairs a symbol + text label so it
never relies on color alone (Requirement 13.2–13.4). Interactive controls carry
accessibility labels and support Dynamic Type / VoiceOver (Requirement 13.5). All
user-facing text is written for a non-technical lawyer (Requirements 12.8, 13.6).

**First-run onboarding wizard (Requirement 12).** A `SetupCoordinator`
(`@Observable`, main-actor) drives an ordered wizard shown in its own window at
launch whenever setup is incomplete; the menu/sync do not start until it reports
ready. Steps:
1. **Welcome** — one-paragraph plain-language overview of what the app does.
2. **Work folder** — explains "the folder on your Mac where your matters are
   kept", opens `NSOpenPanel`, persists the choice (Requirement 1).
3. **Tools check** — runs `CLILocator` for `jj` and `navigator`; shows each as
   Found / Missing in plain words. For a missing tool it shows the exact install
   command (`brew install jj`, `brew install neon-law/navigator/navigator`) with
   a copy button and a "Check again" button — no terminal knowledge required
   (Requirement 12.3).
4. **Sign-in check** — runs `navigator site whoami`; shows "Signed in as
   <email>" or plain guidance to run `navigator site login` (with copy + "Check
   again"), treating login as the CLI's job (A3, Requirement 12.4).
5. **Ready** — confirms setup is complete, persists a `setupComplete` flag, and
   hands off to the menu.

Each step that is not satisfied **blocks advancing** and always offers a concrete
next action (Requirement 12.5). The readiness checks are the same functions the
running app uses, so a prerequisite that later breaks (work folder gone, token
expired) re-surfaces the relevant guidance, and the wizard is re-openable from
the menu (Requirements 12.6–12.7). The wizard's checks are pure/injectable
(fake `CLILocator` + fake `NavigatorClient`), so each step's pass/block logic is
unit-testable without a display (Requirement 9).

**Menu bar (`NSStatusItem` + `NSMenu`, per the decision above).**
- Menu lists matters with a status symbol + name, grouped so needs-attention
  sorts to the top. Per matter: "Open in Finder" (Requirement 6.1, via
  `NSWorkspace.open`) and "Sync now".
- The status item's icon reflects overall state (a needs-attention badge/tint
  when any matter needs attention) — the dynamic-icon case `MenuBarExtra` can't
  serve.
- Top-level: overall state line, a global "Sync now", "Settings…", and
  "Re-run setup…" (reopens the wizard).
- `SettingsView`: work-folder picker (`NSOpenPanel`, Requirement 1), parallelism
  and interval, default bookmark (A1). Missing-CLI and missing-folder banners
  (Requirements 7, 1.4) — these reuse the wizard's readiness checks.

## `jj` command & template contracts (Assumption A6)

All reads use templates with explicit `\t` / `\n` delimiters and `--no-graph`;
human output is never parsed.

- Fetch: `jj git fetch --remote <remote>`.
- After clone, the remote bookmark is **non-tracking**; the sync path must run
  `jj bookmark track <bookmark>@<remote>` once so local/remote track each other
  (verified live on the fake dataset — a fresh `jj git clone` lists
  `<bookmark>@origin` as non-tracking and a push without tracking errors with
  "Non-tracking remote bookmark … exists"). The `MatterActor` does this on first
  registration of a cloned repo.
- Working-copy / conflict probe:
  `jj log --no-graph -r '@' -T 'if(conflict,"1","0") ++ "\n"'`.
- Bookmark vs remote position (ahead/behind, remote moved):
  `jj bookmark list --all-remotes -T '<name>\t<target commit_id>\t<remote>\n'`
  then compare local `<bookmark>` target to `<bookmark>@<remote>` target.
- Rebase onto target: `jj rebase -b @ -d <bookmark>@<remote>` (rebase local work
  onto the freshly fetched remote position).
- Push: `jj git push --bookmark <bookmark> --remote <remote>`. Non-zero exit with
  a "remote moved"/safety-check message → `.pushRejected`; auth text → `.authFailure`.

Each parser takes raw stdout and returns a typed value; parsers are pure
functions so they unit-test directly (Requirement 9.2).

## Navigator CLI & API contract (Assumption A2 — confirmed)

Verified against `navigator` 26.11.10 and the OpenAPI spec at
`/app/api/openapi.json`.

- **Sign-in (A3):** `navigator site login --host <HOST>` runs the OAuth flow and
  stores a token at `~/.navigator.json`. The app does not perform login itself;
  it calls `navigator site whoami --host <HOST>` and, if there is no stored login
  or the token has expired, shows a "sign in with `navigator site login`" state
  instead of erroring per matter. This keeps credential handling entirely in the
  CLI (out of scope to reimplement).
- **Discovery:** the primary source is the REST endpoint
  `GET /app/api/projects` ("List the caller's matters"), which is authorized for
  the signed-in user's own role and returns only the matters visible to them
  (**verified live**: a `client`-role token returns `200 []` when no matters are
  assigned — an empty list is a normal state, not an error). Each `Project` row
  carries: `id`, `code` (stable slug → subfolder name, A7), `name`,
  `status` (`open`/`closed`/`archived` — we sync `open` only), and
  `repository_url` (forge URL, or `null` before the repo is provisioned → skip
  with a "not yet provisioned" note, never an error).
  `navigator project drift --dir <DIR> --json` is **NOT** used as the discovery
  source: it requires an elevated firm/lawyer role and returns `403 Forbidden`
  for a `client` user (**verified live**). It remains an optional
  firm-role-only reconciliation aid, not a dependency.
- **Clone:** clone `repository_url` into `<workFolder>/<code>` via the `jj` layer
  (`jj git clone`) so every local matter is a real `jj` repo the sync path drives.

### Why not just run `navigator project watch`?

`navigator project watch --dir <DIR>` already fetches remote bookmarks and
downloads document revisions, which overlaps with part of this app. We do **not**
delegate the whole MVP to it because: (a) it is a long-running foreground process,
not a per-matter status model, so it cannot give the menu the "needs attention /
offline / syncing" per-matter states the brief requires; (b) it does not push
local work back; (c) the brief explicitly asks for the actor-per-matter +
scheduler design with bounded parallelism and backoff. We use `project drift`
for discovery/status and drive `jj` directly for fetch/rebase/push, which keeps
the status model and the push path under the app's control. `project watch`
remains a documented fallback if we later want the CLI to own fetching.

## Error handling

- **CLI missing** → `CLILocator` error → blocking banner, no sync attempts
  (Req 7.2).
- **Not signed in / discovery fails** → surfaced in menu; existing matters keep
  syncing (Req 2.4).
- **Conflict** → `.needsAttention(.conflict)`, flagged, never auto-resolved.
- **Push rejected (remote moved)** → `.pushRejected`; next cycle re-fetches and
  retries after backoff.
- **Auth failure** → `.authFailure` (Assumption A3: we don't manage creds, only
  surface). 
- **Network down** → `.offline` (distinct from needs-attention, Req 5.4).
- **Repeated failures** → exponential backoff per matter (Req 4.3), isolated so
  other matters keep syncing (Req 5.2 "never silently stuck").
- All failures carry a short reason string for the menu. **No file contents are
  logged; no telemetry** (Requirement 8): the logger redacts to command name,
  matter id, exit code, and a classified reason — never diff/file bodies.

## Testing approach

Tests use the **Swift Testing** framework (`import Testing`, `@Test`,
`#expect`/`#require`), not XCTest (Requirement 9.4). The `NavigatorSyncCore`
library is the unit under test; the thin `NavigatorSync` executable (UI wiring)
is kept minimal precisely so the testable logic lives in the library.

- **Fakes**: `FakeJJClient` and `FakeNavigatorClient` implement the protocols
  with scriptable outcomes (return canned `RepoState`, throw specific errors,
  record calls). No subprocess, no network (Requirement 9.3). Fakes are `actor`
  or `Sendable` so they satisfy the `Sendable` protocol requirement.
- **Parser tests**: feed recorded `jj -T` sample strings (happy path, empty repo,
  conflict marker, malformed line) and assert the typed result via `#expect`
  (Requirement 9.2). Parameterized `@Test(arguments:)` cases cover the input
  matrix.
- **Engine tests**: drive `MatterActor` through each path — clean sync →
  upToDate; conflict → needsAttention(.conflict); push rejected → .pushRejected;
  thrown network error → offline + backoff advances; already-syncing guard
  prevents re-entry (Requirements 3, 4, 5).
- **Scheduler tests**: inject a controllable clock; assert at most
  `maxParallelSyncs` run at once, that up-to-date matters are skipped, and that a
  tick during draining coalesces (Requirement 4).
- **Discovery tests**: fake `listMatters` returning a new matter → a clone is
  requested and a `MatterActor` registered; a discovery throw leaves existing
  matters running (Requirement 2).

Tests run via `swift test` with no external binaries, so CI needs neither `jj`
nor `navigator`.

### Local fake dataset (manual / integration testing)

For end-to-end testing against a real `jj` (no live site, no login, no network),
`fixtures/make-fake-dataset.sh` builds a self-contained dataset under
`/tmp/navfake` (verified working on `jj` 0.47.1):
- `remotes/<code>.git` — bare git repos acting as each matter's Forgejo remote,
  seeded with `navigator.yaml` + `README.md` on a `trunk` bookmark.
- `matters.json` — the exact `GET /app/api/projects` response shape (`id`,
  `code`, `name`, `status`, `repository_url` → `file://…/remotes/<code>.git`),
  so a fake `NavigatorClient` can serve it.
- `work/` — the folder to point the app's work folder at.

The two-clone propagation loop (edit in clone A → push → fetch+rebase in clone B
→ B sees the edit) was verified on this dataset, confirming the Definition of
Done's cross-clone requirement. This dataset is for manual/integration runs; the
unit-test suite uses in-memory fakes and recorded `jj -T` strings, no disk.

### Coverage gate (Requirement 9.5)

Coverage is measured with `swift test --enable-code-coverage` and the line rate
for `NavigatorSyncCore` is extracted via `xcrun llvm-cov report` against the test
binary and profdata. The target is **≥ 80% line coverage** on the core library.
A small shell helper (`scripts/coverage.sh`) runs the tests, computes the rate,
and fails non-zero below the threshold so it can gate CI and be run locally; the
README documents it. The UI executable target is excluded from the gate because
`MenuBarExtra`/`NSOpenPanel` wiring is not unit-testable without a display — all
logic worth testing is in the library, which keeps the 80% meaningful.

## Open items carried to implementation

- Confirm the real push target policy with Neon Law (open question). The current
  design pushes local work to `defaultBookmark` (`main`) with per-matter
  overrides; `project watch` does **not** push, so the push path is ours. This is
  one config value + the `jj git push --bookmark` call to change (A1).
- Discovery source is settled: REST `GET /app/api/projects` (verified authorized
  for a client user; `project drift` is 403 for that role and is not used). The
  exact JSON field names could only be read from the `Project` schema in the
  OpenAPI spec, not a live row, because the available test account has no matters
  assigned (`200 []`). Re-verify field names against a real populated row when a
  firm/lawyer account or a seeded matter is available (e.g. the `quickstart`
  sample firm). The decoder is isolated behind `NavigatorClient`.
- Tune backoff cap and default interval after a real multi-matter run (A4).
