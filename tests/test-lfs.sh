#!/usr/bin/env bash
# A repo that uses Git LFS on any branch is skipped (refs-only sync would leave
# the twin with dangling pointers) unless ALLOW_LFS=1.
#
# Usage: tests/test-lfs.sh   (no network, no tokens, --no-api)
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${HOLONET_SYNC:-${TEST_DIR}/../holonet-sync.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }

mkdir -p "$T"/gh/me "$T"/gt/me "$T"/cfg
git init -q --bare -b main "$T"/gh/me/p.git
git init -q --bare -b main "$T"/gt/me/p.git
cat > "$T"/cfg/c.conf <<C
GITEA_URL="file://$T/gt"
GITHUB_GIT_BASE="file://$T/gh"
GITEA_USER=me; GITHUB_USER=me
STATE_DIR="$T/state"
C
echo "me/p me/p" > "$T"/cfg/repos.list
export GITHUB_TOKEN=x GITEA_TOKEN=y
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
GS()  { "$SYNC" run --no-api --config "$T"/cfg/c.conf 2>&1; }
tip() { git --git-dir="$T/$1/me/p.git" rev-parse -q --verify "$2" 2>/dev/null || echo "-"; }

git clone -q "$T"/gt/me/p.git "$T"/h 2>/dev/null
echo a > "$T"/h/a; git -C "$T"/h add a; git -C "$T"/h commit -qm a; git -C "$T"/h push -q origin main
out=$(GS)
[[ $(tip gh main) == "$(tip gt main)" ]] && ok "plain repo syncs" || fail "plain repo did not sync"

echo "# LFS on a non-default branch, nested .gitattributes"
git -C "$T"/h switch -qc assets; mkdir -p "$T"/h/art
echo '*.png filter=lfs diff=lfs merge=lfs -text' > "$T"/h/art/.gitattributes
git -C "$T"/h add art; git -C "$T"/h commit -qm lfs; git -C "$T"/h push -q origin assets
out=$(GS)
grep -q 'repo uses Git LFS' <<< "$out" && ok "LFS detected and alerted" || fail "no LFS alert: $out"
[[ $(tip gh assets) == "-" ]] && ok "nothing pushed" || fail "assets reached github"

echo 'ALLOW_LFS=1' >> "$T"/cfg/c.conf
GS >/dev/null
[[ $(tip gh assets) == "$(tip gt assets)" ]] && ok "ALLOW_LFS=1 syncs it" || fail "ALLOW_LFS=1 did not sync"

echo; (( FAILS == 0 )) && echo "all passed" || { echo "${FAILS} failed"; exit 1; }
