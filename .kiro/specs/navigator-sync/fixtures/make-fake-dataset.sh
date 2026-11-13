#!/bin/zsh
# make-fake-dataset.sh — build a local, offline fake Navigator dataset for
# testing Navigator Sync without the live site, a login, or a network.
#
# It creates, under $DEST (default /tmp/navfake):
#   remotes/<code>.git   — bare git repos acting as each matter's Forgejo remote
#   matters.json         — the shape returned by GET /app/api/projects, with
#                          repository_url pointing at the local bare repos
#   work/                — empty work folder the app would clone into
#
# Sync target bookmark is "trunk" (not a protected branch name). Requires `jj`.
#
# Usage:  zsh make-fake-dataset.sh [DEST]
set -u
DEST="${1:-/tmp/navfake}"
BM=trunk

command -v jj >/dev/null 2>&1 || { echo "jj not found on PATH"; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/remotes" "$DEST/work"

jj config set --user user.name  "Test Lawyer"      2>/dev/null
jj config set --user user.email "test@example.com" 2>/dev/null

# code | name | status
MATTERS=(
  "cruller-v-prine|Cruller v. Prine|open"
  "widget-works|Widget Works|open"
  "estate-montgomery|Estate of Cornelius Montgomery|open"
)

seed_remote() {
  local code="$1" title="$2"
  git init --bare -q "$DEST/remotes/$code.git"
  local seed="$DEST/.seed-$code"
  jj git init "$seed" >/dev/null 2>&1
  (
    cd "$seed"
    printf 'title: %s\nstatus: open\n' "$title" > navigator.yaml
    printf '# %s\n\nInitial matter notes.\n' "$title" > README.md
    jj describe -m "seed $code"            >/dev/null 2>&1
    jj bookmark create -r @ "$BM"          >/dev/null 2>&1
    jj git remote add origin "$DEST/remotes/$code.git" >/dev/null 2>&1
    jj git push --bookmark "$BM" --remote origin       >/dev/null 2>&1
  )
  rm -rf "$seed"
}

echo "["            > "$DEST/matters.json"
local first=1 i=1
for row in "${MATTERS[@]}"; do
  code="${row%%|*}"; rest="${row#*|}"; name="${rest%%|*}"; st="${rest##*|}"
  seed_remote "$code" "$name"
  [ $first -eq 0 ] && echo ","  >> "$DEST/matters.json"
  first=0
  cat >> "$DEST/matters.json" <<JSON
  {
    "id": "00000000-0000-0000-0000-00000000000$i",
    "code": "$code",
    "name": "$name",
    "status": "$st",
    "repository_url": "file://$DEST/remotes/$code.git"
  }
JSON
  i=$((i+1))
  echo "seeded $code"
done
echo "]"           >> "$DEST/matters.json"

echo
echo "Fake dataset ready at: $DEST"
echo "  remotes:    $DEST/remotes"
echo "  matters:    $DEST/matters.json  (GET /app/api/projects shape)"
echo "  work dir:   $DEST/work  (point the app's work folder here)"
echo
echo "Sync target bookmark: $BM"
echo "Clone a matter as the app would:"
echo "  jj git clone $DEST/remotes/cruller-v-prine.git $DEST/work/cruller-v-prine"
echo "  (then: jj bookmark track $BM@origin  — clones start non-tracking)"
