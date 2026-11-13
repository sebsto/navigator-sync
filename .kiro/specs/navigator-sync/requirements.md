# Navigator Sync — Requirements

## Introduction

Navigator Sync is a macOS menu bar app that keeps a local work folder in sync
with all the matter repositories (each a Jujutsu / `jj` repo hosted on a Forgejo
server) that belong to the signed-in Neon Law Navigator user. It removes the need
for lawyers and AI agents to run `jj` or `git` by hand: the app discovers the
user's matters, clones the missing ones, and syncs each one on a short interval,
surfacing clear per-matter status.

This is an MVP time-boxed to 1–2 days. Proving the end-to-end approach matters
more than polish. Conflict resolution, signing/notarization, and a review
workflow are explicitly out of scope.

## Assumptions (from open questions — isolate so each is easy to change)

These are stated here and again at the point of use in `design.md`. Each is
encapsulated behind a config value or a protocol so it can change in one place.

- **A1 — Push target.** Each matter pushes to a single configurable bookmark,
  defaulting to `main`. Per-user branches or a pull-request flow are not built;
  the push target is a per-matter setting (global default + optional override).
- **A2 — Navigator CLI interface (CONFIRMED + live-verified).** The `navigator`
  CLI (`brew install neon-law/navigator/navigator`, verified v26.11.10) provides:
  `navigator site login --host <HOST>` for sign-in (token at `~/.navigator.json`)
  and `navigator site whoami` (verified: reports identity, role, and token
  expiry). Discovery uses the REST endpoint `GET /app/api/projects` ("List the
  caller's matters"), verified authorized for a signed-in `client` user (returns
  their matters, or `200 []` when none are assigned). `navigator project drift`
  is **not** a discovery dependency: it needs an elevated firm/lawyer role and
  returns `403 Forbidden` for a `client` user (verified live). `Project` rows
  carry `id`, `code`, `name`, `status`, and `repository_url`; cloning uses the
  `repository_url` via `jj git clone`. `NavigatorClient` wraps these; the host
  (`https://www.neonlaw.com` default) is the only per-deployment coordinate and
  is a single setting.
- **A3 — Forgejo authentication.** The user's existing `git` and `jj`
  configuration already handles Forgejo auth (SSH key or HTTPS token). The app
  does not manage credentials; it only detects and surfaces auth failures.
- **A4 — Scale.** Up to ~200 matters per Mac and ~70 users. The scheduler is
  designed for 200 matters with bounded parallelism, even though the MVP is
  tested with a few.
- **A5 — CLI discovery.** Both CLIs are found on `PATH` and, failing that, in
  `/opt/homebrew/bin`. A missing CLI is a clear, actionable error, not a crash.
- **A6 — `jj` sync semantics.** "Sync" per matter means: `jj git fetch`, rebase
  local work onto the updated remote bookmark, then `jj git push` to the
  configured bookmark. Machine-readable state is read with `jj log -T <template>`
  and `jj bookmark list -T <template>`; human-formatted output is never parsed.
- **A8 — Subprocess mechanism.** All CLI process execution uses Apple's
  open-source `swift-subprocess` package (async/await, Sendable results,
  bounded output capture, timeout + teardown), not `Foundation.Process`. It is
  wrapped in one `CommandRunner` behind a protocol so the clients and tests stay
  independent of it (per the user's requirement).
- **A7 — A matter is one directory.** One subfolder per matter under the work
  folder; the subfolder name is derived from a stable matter identifier.

## Requirements

### Requirement 1 — Choose the work folder

**User Story:** As a Navigator user, I want to pick a local work folder, so that
all my matters are cloned and synced in one place I control.

#### Acceptance Criteria
1. WHEN the app launches for the first time THEN the system SHALL open a settings
   screen prompting the user to choose a work folder.
2. WHEN the user selects a folder THEN the system SHALL persist that path across
   app restarts.
3. IF no work folder is configured THEN the system SHALL NOT start syncing and
   SHALL show a "choose a work folder" state in the menu.
4. WHEN a work folder is configured but does not exist on disk THEN the system
   SHALL flag this as needs-attention with a clear message and SHALL NOT create
   or sync matters until it is resolved.

### Requirement 2 — Discover and clone matters

**User Story:** As a Navigator user, I want my assigned matters to appear in the
work folder automatically, so that I never clone a repository by hand.

#### Acceptance Criteria
1. WHEN discovery runs THEN the system SHALL ask the Navigator CLI for the list of
   the signed-in user's matters.
2. WHEN a matter in the discovered list has no subfolder in the work folder THEN
   the system SHALL clone it into its own subfolder using the Navigator CLI.
3. WHEN a matter subfolder already exists and is a valid `jj` repo THEN the system
   SHALL NOT re-clone it.
4. IF discovery fails (CLI missing, not signed in, network error) THEN the system
   SHALL surface a clear error in the menu and SHALL keep syncing already-cloned
   matters.
5. WHEN a new matter is assigned to the user THEN it SHALL appear as a new
   subfolder within one discovery cycle without user action.

### Requirement 3 — Periodic sync of each matter

**User Story:** As a Navigator user, I want each matter kept in sync every minute,
so that edits propagate between my clones and the server without my involvement.

#### Acceptance Criteria
1. WHEN the scheduler fires on its interval (default 60 seconds) THEN the system
   SHALL schedule a sync for every known matter.
2. WHEN a matter syncs THEN the system SHALL run, in order: `jj git fetch`, rebase
   of local work onto the updated target bookmark, and `jj git push` to the
   configured bookmark.
3. WHEN an edit is made in one clone of a matter THEN it SHALL appear in another
   clone of the same matter within two minutes (two sync cycles).
4. WHERE a matter has no local changes and the remote is unchanged since the last
   fetch THEN the system SHOULD skip the push step for that matter.
5. WHEN the user invokes "Sync now" THEN the system SHALL immediately schedule a
   sync of all matters regardless of the interval timer.

### Requirement 4 — Bounded, resilient concurrency

**User Story:** As a user with up to ~200 matters, I want syncing to stay
responsive and not overwhelm the machine or the server, so that the app is usable
at scale.

#### Acceptance Criteria
1. WHERE many matters are due to sync THEN the system SHALL run at most N syncs in
   parallel, where N is configurable and defaults to 4.
2. WHEN a matter's sync is already running THEN the system SHALL NOT start a second
   concurrent sync for that same matter.
3. WHEN a matter's sync fails repeatedly THEN the system SHALL apply exponential
   backoff to that matter before retrying, without blocking other matters.
4. WHEN a sync cycle fires while a previous cycle's work is still draining THEN the
   system SHALL coalesce rather than pile up unbounded work.

### Requirement 5 — Per-matter status

**User Story:** As a Navigator user, I want to see each matter's status at a
glance, so that I know what is healthy and what needs my attention.

#### Acceptance Criteria
1. WHEN the user opens the menu THEN the system SHALL list every matter with one
   of these statuses: up to date, syncing, offline, needs attention.
2. WHEN a matter cannot push (conflict, auth failure, rejected push) THEN the
   system SHALL mark it needs-attention with a short human-readable reason and
   SHALL NOT leave it silently stuck.
3. WHEN a matter is actively running a sync THEN the system SHALL show it as
   syncing.
4. IF the network is unavailable THEN affected matters SHALL show as offline
   rather than needs-attention.
5. WHEN a matter transitions from needs-attention back to a healthy state on a
   later sync THEN the status SHALL update without restarting the app.

### Requirement 6 — Per-matter actions

**User Story:** As a Navigator user, I want to open a matter's folder and force a
sync, so that I can inspect files and recover quickly.

#### Acceptance Criteria
1. WHEN the user chooses "Open in Finder" for a matter THEN the system SHALL open
   that matter's subfolder in Finder.
2. WHEN the user chooses "Sync now" THEN the system SHALL trigger an immediate
   sync as in Requirement 3.5.

### Requirement 7 — CLI discovery and clear failures

**User Story:** As a user installing the app, I want a clear message when a
required CLI is missing, so that I can fix my setup instead of seeing a silent
failure.

#### Acceptance Criteria
1. WHEN the app starts THEN the system SHALL locate `jj` and `navigator` on `PATH`
   and, if not found there, in `/opt/homebrew/bin`.
2. IF either CLI cannot be found THEN the system SHALL show a clear message naming
   the missing CLI and how to install it, and SHALL NOT attempt syncs that need
   it.
3. WHEN a CLI invocation exits non-zero THEN the system SHALL capture its exit
   code and stderr for status reporting, WITHOUT logging file contents.

### Requirement 8 — Privacy and logging

**User Story:** As a user handling confidential legal matters, I want no file
contents or telemetry leaving my machine, so that client confidentiality is
preserved.

#### Acceptance Criteria
1. WHEN the system logs THEN it SHALL NOT include the contents of any matter file.
2. WHEN the system runs THEN it SHALL NOT send any telemetry or analytics.
3. WHERE a command's stderr may contain sensitive text THEN the system SHALL treat
   captured output as diagnostic only and keep it local.

### Requirement 9 — Testability and coverage

**User Story:** As a maintainer, I want the sync engine and output parsing covered
by unit tests with fake CLIs, so that I can change behavior safely.

#### Acceptance Criteria
1. WHERE the app calls a CLI THEN that call SHALL go through a Swift protocol
   (`JJClient`, `NavigatorClient`) so a fake implementation can be injected in
   tests.
2. WHEN `jj` template output is parsed THEN the parser SHALL be unit tested against
   recorded sample outputs, including malformed and empty inputs.
3. WHEN the sync engine processes a matter THEN its state transitions SHALL be unit
   testable with fake clients, with no real subprocess or network.
4. WHEN tests are written THEN they SHALL use the **Swift Testing** framework
   (`import Testing`, `@Test`, `#expect`/`#require`), not XCTest.
5. WHEN coverage is measured on the `NavigatorSyncCore` library target THEN line
   coverage SHALL be at least 80%, verified with `swift test --enable-code-coverage`
   and reported in the README / CI.

### Requirement 11 — Modern Swift 6 concurrency

**User Story:** As a maintainer, I want the code to use modern Swift 6 structured
concurrency correctly, so that it is safe and maintainable without escape hatches.

#### Acceptance Criteria
1. WHEN the package is built THEN it SHALL compile under Swift 6 language mode with
   complete strict concurrency checking and zero concurrency warnings.
2. WHERE concurrency is needed THEN the code SHALL use structured concurrency
   (actors, `async`/`await`, task groups) and Sendable types.
3. WHEN shared mutable state is required THEN it SHALL be protected by an actor or
   a `Synchronization.Mutex`, and the code SHALL NOT use `nonisolated(unsafe)`,
   `Task.detached`, or `DispatchQueue` to silence concurrency diagnostics.
4. WHEN a subprocess is run THEN its standard output and standard error SHALL be
   collected without a data race (via the library's concurrent capture, not a
   shared mutable buffer), and the call SHALL be cancellable: cancelling the
   owning task SHALL tear the process down (interrupt → terminate → kill) rather
   than leak it.
5. WHEN a subprocess exceeds its timeout THEN the system SHALL cancel and tear it
   down (not merely stop awaiting it), using the task-group timeout pattern with
   `cancelAll()`.

### Requirement 10 — Build, run, and license

**User Story:** As a developer, I want to build and run the app from a README, so
that I can verify it on my own Mac.

#### Acceptance Criteria
1. WHEN a developer follows the README THEN they SHALL be able to build and run the
   app on macOS 14+ Apple silicon.
2. WHEN the repository is published THEN it SHALL carry an MIT OR Apache-2.0
   license.

### Requirement 12 — First-run onboarding wizard

**User Story:** As a lawyer who is not a software developer, I want a guided
first-run setup that walks me through every prerequisite in plain language, so
that I can get Navigator Sync working without touching a terminal or
understanding Git, `jj`, or tokens.

#### Acceptance Criteria
1. WHEN the app launches and setup is not yet complete THEN the system SHALL open
   a multi-step onboarding wizard before showing the normal menu, and SHALL NOT
   begin syncing until the wizard reports the app is ready.
2. WHEN the wizard runs THEN it SHALL present ordered steps covering, at minimum:
   (a) a welcome/overview, (b) choosing the work folder, (c) checking that the
   required command-line tools are installed, (d) checking sign-in to Navigator,
   and (e) a final confirmation that setup is complete.
3. WHEN the wizard checks the command-line tools THEN it SHALL report each tool as
   found or missing in plain language, and WHERE a tool is missing it SHALL show
   the exact one-line install command with a copy button and SHALL offer to
   re-check, WITHOUT requiring the user to open a terminal to discover the
   command.
4. WHEN the wizard checks authentication THEN it SHALL report whether the user is
   signed in (and to which account), and WHERE the user is not signed in it SHALL
   explain in plain language how to sign in (the `navigator site login` step) and
   offer to re-check, treating sign-in itself as the CLI's responsibility
   (Assumption A3).
5. WHERE a step's prerequisite is not satisfied THEN the wizard SHALL block
   advancing past that step and SHALL clearly indicate what is needed, never
   leaving the user on a dead end with no next action.
6. WHEN every step is satisfied THEN the wizard SHALL let the user finish, SHALL
   persist that setup is complete, and SHALL NOT reappear on the next launch
   unless a prerequisite later becomes unsatisfied (for example the work folder
   is gone or the token expired), in which case the relevant guidance SHALL be
   reachable again.
7. WHEN the user wants to change setup later THEN the system SHALL let them
   re-open the wizard (or the equivalent settings) from the menu.
8. WHERE the wizard shows any guidance THEN the language SHALL avoid developer
   jargon and SHALL be written for a non-technical legal professional (e.g. "the
   folder on your Mac where your matters are kept", not "the sync root path").

### Requirement 13 — Modern, professional SwiftUI interface

**User Story:** As a lawyer using this on my Mac every day, I want a clean,
modern, trustworthy-looking interface, so that the tool feels professional and is
effortless to read at a glance.

#### Acceptance Criteria
1. WHEN any screen is built THEN its views SHALL be implemented in SwiftUI (no
   AppKit view controllers for screen content, no storyboards/XIBs). Thin AppKit
   system integration that SwiftUI has no equivalent for — `NSStatusItem`/
   `NSMenu` for the menu bar, `NSWindow`+`NSHostingController` to host SwiftUI
   views as windows in an accessory app, `NSOpenPanel`, `NSWorkspace` — is
   allowed and the SwiftUI views are hosted inside it. (This matches the
   `sebsto/wispr` house pattern; see the menu-bar decision in `design.md`.)
2. WHEN the UI renders THEN it SHALL present a clean, modern, professional
   appearance: consistent spacing and typography, SF Symbols for status and
   actions (not emoji), and a clear visual hierarchy.
3. WHEN the system shows a status THEN it SHALL be legible at a glance with a
   distinct, consistent visual treatment per state (up to date, syncing, offline,
   needs attention), including a text label and an accessible color/symbol pairing
   that does not rely on color alone.
4. WHEN the app is viewed in light or dark mode THEN the UI SHALL adapt correctly
   using system colors, and SHALL remain legible in both.
5. WHEN a user relies on accessibility features THEN interactive elements SHALL
   carry accessibility labels and the UI SHALL support Dynamic Type and
   VoiceOver for its primary controls.
6. WHERE text is shown to the user THEN it SHALL use plain, professional language
   appropriate for a lawyer, consistent with Requirement 12.8.
