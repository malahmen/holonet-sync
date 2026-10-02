#!/usr/bin/env bash
# Regression test: a__b/c and a/b__c must get separate workspaces (the old
# `${full//\//__}` key mapped both to a__b__c), and state written under the old
# key must be migrated, unless two listed repos share that legacy key.
#
# Usage: tests/test-workspace-key.sh   (no network, no tokens, --no-api)
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${HOLONET_SYNC:-${TEST_DIR}/../holonet-sync.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }

export GITHUB_TOKEN=x GITEA_TOKEN=y
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$T"/cfg
cat > "$T"/cfg/c.conf <<C
GITEA_URL="file://$T/gt"
GITHUB_GIT_BASE="file://$T/gh"
GITEA_USER=me; GITHUB_USER=me
STATE_DIR="$T/state"
C
GS() { "$SYNC" run --no-api --config "$T"/cfg/c.conf 2>&1; }
mkrepo() {  # mkrepo <owner/name> <file>
    git init -q --bare -b main "$T/gt/$1.git"; git init -q --bare -b main "$T/gh/$1.git"
    local c="$T/clone-${1//\//-}"; git clone -q "$T/gt/$1.git" "$c" 2>/dev/null
    echo "$2" > "$c/$2"; git -C "$c" add "$2"; git -C "$c" commit -qm "$2"; git -C "$c" push -q origin main
}
mkdir -p "$T"/gt/a__b "$T"/gt/a "$T"/gh/a__b "$T"/gh/a
mkrepo a__b/c one
mkrepo a/b__c two
printf 'a__b/c a__b/c\na/b__c a/b__c\n' > "$T"/cfg/repos.list

echo "# 1. colliding names get separate workspaces"
out=$(GS)
[[ -d "$T/state/repos/a__b+c.git" && -d "$T/state/repos/a+b__c.git" ]] && ok "two workspaces" || fail "workspaces: $(ls "$T"/state/repos)"
[[ $(git --git-dir="$T/gh/a__b/c.git" log --format=%s main) == one ]] && ok "a__b/c synced its own history" || fail "a__b/c github has: $(git --git-dir="$T/gh/a__b/c.git" log --format=%s main 2>&1)"
[[ $(git --git-dir="$T/gh/a/b__c.git" log --format=%s main) == two ]] && ok "a/b__c synced its own history" || fail "a/b__c github has: $(git --git-dir="$T/gh/a/b__c.git" log --format=%s main 2>&1)"

echo "# 2. legacy workspace is migrated when unambiguous"
mkdir -p "$T"/gt/me "$T"/gh/me; mkrepo me/p three
echo "me/p me/p" > "$T"/cfg/repos.list
GS >/dev/null
mv "$T/state/repos/me+p.git" "$T/state/repos/me__p.git"; mv "$T/state/status/me+p" "$T/state/status/me__p"
base=$(git --git-dir="$T/state/repos/me__p.git" rev-parse refs/sync/base/heads/main)
out=$(GS)
grep -q 'migrated state me__p -> me+p' <<< "$out" && ok "migration logged" || fail "no migration: $out"
[[ $(git --git-dir="$T/state/repos/me+p.git" rev-parse refs/sync/base/heads/main 2>/dev/null) == "$base" ]] && ok "sync base kept" || fail "sync base lost"
[[ ! -e "$T/state/repos/me__p.git" && -e "$T/state/status/me+p" ]] && ok "old paths moved" || fail "old paths left behind"

echo "# 3. ambiguous legacy workspace is not migrated"
rm -rf "$T"/state; mkdir -p "$T"/state/repos
git init -q --bare "$T/state/repos/a__b__c.git"
printf 'a__b/c a__b/c\na/b__c a/b__c\n' > "$T"/cfg/repos.list
out=$(GS)
grep -q 'shared by 2 listed repos' <<< "$out" && ok "ambiguity warned" || fail "no ambiguity warning: $out"
[[ -d "$T/state/repos/a__b__c.git" ]] && ok "legacy workspace left in place" || fail "legacy workspace was moved"

echo; (( FAILS == 0 )) && echo "all passed" || { echo "${FAILS} failed"; exit 1; }
