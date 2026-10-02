#!/usr/bin/env bash
# Regression test: a branch force-pushed on one side must never be merged back
# or fast-forwarded back to the dropped commits. Before the fix, a rewind on one
# side was silently undone by a fast-forward, and an amend was merged with the
# old history and pushed to both sides.
#
# Usage: tests/test-rewrites.sh   (no network, no tokens, --no-api)
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
PROPAGATE_REWRITES=0
C
echo "me/p me/p" > "$T"/cfg/repos.list
export GITHUB_TOKEN=x GITEA_TOKEN=y
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
GS()  { "$SYNC" run --no-api --config "$T"/cfg/c.conf 2>&1; }
tip() { git --git-dir="$T/$1/me/p.git" rev-parse -q --verify "$2" 2>/dev/null || echo "-"; }
has() { git --git-dir="$T/$1/me/p.git" log --format=%s "$2" | grep -qx "$3"; }
commit() { echo "$3" > "$1/$3"; git -C "$1" add "$3"; git -C "$1" commit -qm "$3"; git -C "$1" push -q origin "$2"; }
propagate() { sed -i.bak "s/^PROPAGATE_REWRITES=.*/PROPAGATE_REWRITES=$1/" "$T"/cfg/c.conf; }

git clone -q "$T"/gt/me/p.git "$T"/h 2>/dev/null
commit "$T"/h main a
commit "$T"/h main secret
GS >/dev/null
has gh main secret && ok "seed: github has the commit" || fail "seed did not reach github"

echo "# 1. rewind on gitea, PROPAGATE_REWRITES=0"
git -C "$T"/h reset -q --hard HEAD~1; git -C "$T"/h push -q --force origin main
gt0=$(tip gt main); gh0=$(tip gh main)
out=$(GS)
[[ $(tip gt main) == "$gt0" ]] && ok "gitea not fast-forwarded back" || fail "gitea moved to $(tip gt main)"
[[ $(tip gh main) == "$gh0" ]] && ok "github untouched" || fail "github moved"
grep -q 'was rewritten (force-pushed) on gitea' <<< "$out" && ok "rewrite alert raised" || fail "no rewrite alert: $out"

echo "# 2. same state, PROPAGATE_REWRITES=1 -> rewind carried to github"
propagate 1
GS >/dev/null
[[ $(tip gh main) == "$gt0" ]] && ok "github rewound to gitea's tip" || fail "github at $(tip gh main), want $gt0"
! has gh main secret && ok "dropped commit gone from github" || fail "github still has the dropped commit"
out=$(GS)
grep -qE 'pushed|ALERT' <<< "$out" && fail "rerun not a no-op: $out" || ok "rerun is a no-op"

echo "# 3. amend on github, PROPAGATE_REWRITES=0 -> no merge"
propagate 0
git clone -q "$T"/gh/me/p.git "$T"/w 2>/dev/null
git -C "$T"/w commit -q --amend -m "a (amended)"; git -C "$T"/w push -q --force origin main
gt0=$(tip gt main); gh0=$(tip gh main)
out=$(GS)
[[ $(tip gt main) == "$gt0" && $(tip gh main) == "$gh0" ]] && ok "neither side touched" || fail "a side moved: gitea=$(tip gt main) github=$(tip gh main)"
grep -q 'auto-merged' <<< "$out" && fail "rewrite was merged" || ok "rewrite not merged"

echo "# 4. rewritten on github AND new commit on gitea, PROPAGATE_REWRITES=1 -> alert only"
propagate 1
git -C "$T"/h pull -q --rebase=false origin main 2>/dev/null; commit "$T"/h main extra
gt0=$(tip gt main); gh0=$(tip gh main)
out=$(GS)
[[ $(tip gt main) == "$gt0" && $(tip gh main) == "$gh0" ]] && ok "neither side touched" || fail "a side moved: gitea=$(tip gt main) github=$(tip gh main)"
grep -q 'both sides changed since the last sync' <<< "$out" && ok "two-sided rewrite alert raised" || fail "no two-sided alert: $out"

echo; (( FAILS == 0 )) && echo "all passed" || { echo "${FAILS} failed"; exit 1; }
