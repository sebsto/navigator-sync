# Navigator Sync — test fixtures

A self-contained, offline fake dataset for testing Navigator Sync without the
live Neon Law site, a login, or any network access.

## What `make-fake-dataset.sh` builds

```
/tmp/navfake/                 (override with: zsh make-fake-dataset.sh <DEST>)
  remotes/
    cruller-v-prine.git       bare git repo = matter's Forgejo remote
    widget-works.git
    estate-montgomery.git
  matters.json                exactly the GET /app/api/projects response shape
  work/                       empty; point the app's work folder here
```

Each bare remote is a real `jj`/git repository seeded with `navigator.yaml` and
`README.md` on a `trunk` bookmark. `trunk` is used deliberately (not `main`) as
the sync target so nothing depends on a protected branch name.

`matters.json` matches the live API's `Project` fields — `id`, `code`, `name`,
`status`, `repository_url` — with `repository_url` pointing at the local bare
repos via `file://`. A fake `NavigatorClient` serves this file in place of a real
`GET /app/api/projects` call.

## Requirements

- `jj` on `PATH` (tested with jj 0.47.1 — `brew install jj`).

## Run it

```
zsh make-fake-dataset.sh            # builds /tmp/navfake
zsh make-fake-dataset.sh /tmp/foo   # custom destination
```

## Verify the clone + sync cycle by hand

```
cd /tmp/navfake/work
jj git clone /tmp/navfake/remotes/cruller-v-prine.git cruller-v-prine
cd cruller-v-prine
jj bookmark track trunk@origin        # clones start non-tracking
echo "a change" >> README.md
jj describe -m "edit"
jj bookmark set trunk -r @
jj git push --bookmark trunk --remote origin
```

Clone the same matter a second time into another folder, `jj git fetch` +
`jj rebase -b @ -d trunk@origin`, and the edit appears — this is the
cross-clone propagation the Definition of Done requires.

## Notes

- The dataset is disposable: re-running the script wipes and rebuilds `DEST`.
- The unit-test suite does **not** use this dataset; it uses in-memory fakes and
  recorded `jj -T` output strings and needs no binaries. This fixture is for
  manual and integration testing against a real `jj`.
