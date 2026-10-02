#!/usr/bin/env bash
# Regression test: a clean divergence whose merge commit cannot be written must
# leave both sides untouched. Before the fix, errexit was silently off inside
# sync_repo, commit-tree's failure left the merge sha empty, and do_push turned
# `<empty>:refs/heads/<b>` into a delete on BOTH remotes.
#
# Usage: tests/test-merge-failure.sh   (no network, no tokens, --no-api)
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
MERGE_AUTHOR_NAME="holonet-sync"
C
echo "me/p me/p" > "$T"/cfg/repos.list
export GITHUB_TOKEN=x GITEA_TOKEN=y
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
GS()  { "$SYNC" run --no-api --config "$T"/cfg/c.conf 2>&1; }
tip() { git --git-dir="$T/$1/me/p.git" rev-parse -q --verify "$2" 2>/dev/null || echo "-"; }
commit() { echo "$3" > "$1/$3"; git -C "$1" add "$3"; git -C "$1" commit -qm "$3"; git -C "$1" push -q origin "$2"; }

git clone -q "$T"/gt/me/p.git "$T"/h 2>/dev/null
commit "$T"/h main a
git -C "$T"/h switch -qc feat; commit "$T"/h feat f
GS >/dev/null
git clone -q -b feat "$T"/gh/me/p.git "$T"/w 2>/dev/null
commit "$T"/h feat e
commit "$T"/w feat g
gt_before=$(tip gt feat); gh_before=$(tip gh feat)

# An empty committer name makes `git commit-tree` refuse to write the merge.
sed -i.bak 's/^MERGE_AUTHOR_NAME=.*/MERGE_AUTHOR_NAME=""/' "$T"/cfg/c.conf
out=$(GS); rc=$?

[[ $(tip gt feat) == "$gt_before" ]] && ok "gitea feat untouched" || fail "gitea feat changed: $(tip gt feat) (was $gt_before)"
[[ $(tip gh feat) == "$gh_before" ]] && ok "github feat untouched" || fail "github feat changed: $(tip gh feat) (was $gh_before)"
(( rc != 0 )) && ok "run exits non-zero" || fail "run exited 0"
grep -q 'merge commit could not be written' <<< "$out" && ok "alert names the failed merge" || fail "no merge-failure alert in: $out"
grep -q 'run finished with errors' <<< "$out" && ok "run summary printed" || fail "summary missing"
"$SYNC" status --config "$T"/cfg/c.conf 2>/dev/null | grep -q PARTIAL && ok "status is PARTIAL" || fail "status not PARTIAL"

# With a valid identity the same divergence merges cleanly on the next run.
sed -i.bak 's/^MERGE_AUTHOR_NAME=.*/MERGE_AUTHOR_NAME="holonet-sync"/' "$T"/cfg/c.conf
GS >/dev/null
[[ $(tip gt feat) == "$(tip gh feat)" && $(tip gt feat) != "$gt_before" ]] \
    && ok "next run merges and converges" || fail "did not converge: gitea=$(tip gt feat) github=$(tip gh feat)"

echo; (( FAILS == 0 )) && echo "all passed" || { echo "${FAILS} failed"; exit 1; }
