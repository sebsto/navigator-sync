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

## Requirements

- macOS 14 or later, Apple silicon.
- Swift 6.2+ toolchain (Xcode 26+ / current Swift.org toolchain).
- Two command-line tools on your `PATH` (or in `/opt/homebrew/bin`):
  - **Jujutsu** — `brew install jj`
  - **Navigator CLI** — `brew install neon-law/navigator/navigator`
- A Navigator account. Sign in once with the CLI:
  `navigator site login --host www.neonlaw.com`

The app does not manage credentials itself — it relies on your existing `git`,
`jj`, and `navigator` configuration and only surfaces errors. No file contents
are logged and there is no telemetry.

## Build

```sh
swift build
```

## Run

```sh
swift run NavigatorSync
```

On first launch an onboarding wizard walks you through choosing a work folder,
checking the two CLIs are installed, and confirming you are signed in.

The app runs as a menu bar agent (no Dock icon). A minimal `Info.plist` with
`LSUIElement` is documented for bundling; signing/notarization are out of scope
for the MVP.

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
