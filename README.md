# Navigator Sync

[![CI](https://github.com/sebsto/navigator-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/sebsto/navigator-sync/actions/workflows/ci.yml)

A small macOS menu bar app that keeps a local work folder in sync with all of
the [Neon Law Navigator](https://www.neonlaw.com/navigator) matter repositories
belonging to the signed-in user — so lawyers and AI agents never have to type
`jj` or `git`.

Each matter (Project) is its own [Jujutsu](https://jj-vcs.github.io/jj/) (`jj`)
repository hosted on a Forgejo server. Navigator Sync discovers the user's
matters, clones the missing ones into a work folder (one subfolder per matter),
and syncs each one on a short interval (fetch → rebase local work → push),
surfacing a clear per-matter status in the menu bar.

> Status: MVP under active development. See `.kiro/specs/navigator-sync/` for the
> requirements, design, and task plan.

## Getting started

Follow these steps once, in order, on an Apple-silicon Mac running macOS 14 or
later. Each command runs in the Terminal app (press ⌘-Space, type "Terminal",
press Return).

### 1. Install Homebrew (skip if you already have it)

Homebrew is the package manager used to install the tools below.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Check it worked:

```sh
brew --version
```

### 2. Install the Swift toolchain (Xcode)

Navigator Sync builds with Swift 6.2 or newer. Install Xcode 26 or newer from the
Mac App Store (it includes the Swift toolchain), then accept its license and
command-line tools:

```sh
sudo xcodebuild -license accept
xcode-select --install   # no-op if already installed
swift --version          # should report Swift 6.2 or newer
```

### 3. Install the two helper CLIs

Navigator Sync drives these two command-line tools; it never reimplements them.

```sh
brew install jj
brew install neon-law/navigator/navigator
```

Check both are found:

```sh
jj --version
navigator --version
```

### 4. Sign in to Navigator

Navigator Sync does not handle your password; it uses the Navigator CLI's own
login. Run this once (it opens your browser):

```sh
navigator site login --host www.neonlaw.com
```

Confirm you are signed in:

```sh
navigator site whoami --host www.neonlaw.com
```

### 5. Build and run Navigator Sync

```sh
git clone https://github.com/sebsto/navigator-sync.git
cd navigator-sync
swift run NavigatorSync
```

A Navigator Sync icon appears in the menu bar at the top of your screen, and on
the first launch an onboarding wizard walks you through choosing a work folder
and re-checks the steps above. After setup it keeps your matters in sync and
shows a status for each one in the menu.

The app runs as a menu bar agent with no Dock icon. Signing and notarization are
out of scope for the MVP, so run it with `swift run` for now.

## Requirements (summary)

- macOS 14 or later, Apple silicon.
- Swift 6.2+ toolchain (Xcode 26 or newer).
- `jj` and `navigator` on your `PATH` (or in `/opt/homebrew/bin`).
- A Navigator account, signed in via `navigator site login`.

The app does not manage credentials itself — it relies on your existing `git`,
`jj`, and `navigator` configuration and only surfaces errors. No file contents
are logged and there is no telemetry.

## Test

```sh
swift test                 # unit tests (Swift Testing)
./scripts/coverage.sh      # tests + enforce >=80% line coverage on the core library
```

Tests use fake CLI clients and recorded `jj` output, so they need neither `jj`
nor `navigator` installed.

### Try it without a live account

`.kiro/specs/navigator-sync/fixtures/make-fake-dataset.sh` builds a fully offline
fake dataset (three local `jj` matter repos + a `matters.json` matching the live
API shape) you can point the app at. See that folder's README.

## Architecture (short)

- `NavigatorSyncCore` — models, the `jj`/`navigator` CLI clients behind
  protocols, the `jj` template parsers, and the sync engine (one actor per
  matter + a scheduler actor with bounded parallelism and backoff). Fully unit
  tested with fakes.
- `NavigatorSync` — the thin SwiftUI app: menu bar (`NSStatusItem`), onboarding
  wizard, and settings.

Subprocesses are run through Apple's
[`swift-subprocess`](https://github.com/swiftlang/swift-subprocess) package with
structured concurrency (bounded output capture, timeout, and cancellation
teardown). The full design is in `.kiro/specs/navigator-sync/design.md`.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.
