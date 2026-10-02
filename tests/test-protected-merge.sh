#!/usr/bin/env bash
# A clean divergence on a protected branch alerts by default and merges only
# with AUTO_MERGE_PROTECTED=1; unprotected branches keep auto-merging.
#
# Usage: tests/test-protected-merge.sh   (no network, no tokens, --no-api)
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
commit() { echo "$3" > "$1/$3"; git -C "$1" add "$3"; git -C "$1" commit -qm "$3"; git -C "$1" push -q origin "$2"; }

git clone -q "$T"/gt/me/p.git "$T"/h 2>/dev/null
commit "$T"/h main a
git -C "$T"/h switch -qc feat; commit "$T"/h feat f; git -C "$T"/h switch -q main
GS >/dev/null
git clone -q "$T"/gh/me/p.git "$T"/w 2>/dev/null; git -C "$T"/w fetch -q origin feat
commit "$T"/h main c; commit "$T"/w main d
git -C "$T"/h switch -q feat; commit "$T"/h feat e
git -C "$T"/w switch -q feat; commit "$T"/w feat g

echo "# 1. default: protected main alerts, feat merges"
gt0=$(tip gt main); gh0=$(tip gh main)
out=$(GS)
[[ $(tip gt main) == "$gt0" && $(tip gh main) == "$gh0" ]] && ok "main untouched on both sides" || fail "main moved"
grep -q "protected branch 'main' diverged" <<< "$out" && ok "main divergence alerted" || fail "no alert: $out"
[[ $(tip gt feat) == "$(tip gh feat)" ]] && ok "feat auto-merged" || fail "feat not merged"

echo "# 2. AUTO_MERGE_PROTECTED=1: main merges"
echo 'AUTO_MERGE_PROTECTED=1' >> "$T"/cfg/c.conf
GS >/dev/null
[[ $(tip gt main) == "$(tip gh main)" && $(tip gt main) != "$gt0" ]] && ok "main auto-merged" || fail "main not merged"

echo; (( FAILS == 0 )) && echo "all passed" || { echo "${FAILS} failed"; exit 1; }
