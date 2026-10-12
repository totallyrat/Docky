#!/bin/bash
# Publishes the version in VERSION as a GitHub release: Docky.dmg is built here (signed with the
# local identity, so installed copies accept it as an update) and Docky.exe comes from the
# Windows workflow run for the same commit. Both apps update themselves from this release.
#
#   NOTES="What's new" Tools/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
GH=${GH:-gh}
VERSION=$(tr -d '[:space:]' < VERSION)
[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first."; exit 1; }
SHA=$(git rev-parse HEAD)
git push -q

./build.sh

echo "Waiting for the Windows build of ${SHA:0:7}…"
RUN=""
for _ in $(seq 1 60); do
    RUN=$($GH run list --workflow Windows --commit "$SHA" --json databaseId --jq '.[0].databaseId // empty')
    [[ -n $RUN ]] && break
    sleep 5
done
[[ -n $RUN ]] || { echo "No Windows build found for $SHA."; exit 1; }
$GH run watch "$RUN" --exit-status --interval 15 >/dev/null

TMP=$(mktemp -d)
$GH run download "$RUN" -n Docky-Windows -D "$TMP"
$GH release create "v$VERSION" build/Docky.dmg "$TMP/Docky.exe" \
    --title "Docky $VERSION" --notes "${NOTES:-Docky $VERSION}"
rm -rf "$TMP"
