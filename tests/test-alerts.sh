#!/usr/bin/env bash
# Regression test for alert hygiene:
#   - an alert raised while planning ("restoring it") is not sent, nor stamped,
#     for a repo that the deletion guard then skips; it is sent once the run
#     goes ahead;
#   - counts in alert text carry no padding (BSD `wc -l` pads its output).
#
# Usage: tests/test-alerts.sh   (no network, no tokens, --no-api)
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
ALERT_CMD='cat >> "$T/alerts.log"; echo >> "$T/alerts.log"'
C
echo "me/p me/p" > "$T"/cfg/repos.list
export GITHUB_TOKEN=x GITEA_TOKEN=y
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
GS()  { "$SYNC" run --no-api --config "$T"/cfg/c.conf "$@" 2>&1; }
gh()  { git --git-dir="$T/gh/me/p.git" "$@"; }
sent() { grep -c "$1" "$T/alerts.log" 2>/dev/null || true; }

git clone -q "$T"/gt/me/p.git "$T"/h 2>/dev/null
echo a > "$T"/h/a; git -C "$T"/h add a; git -C "$T"/h commit -qm a; git -C "$T"/h push -q origin main
for i in 1 2 3 4 5 6 7; do git -C "$T"/h branch -q "b$i" main; git -C "$T"/h push -q origin "b$i"; done
GS >/dev/null

echo "# 1. deletion guard skips the repo: plan-time alert is held back"
for i in 1 2 3 4 5 6; do gh update-ref -d "refs/heads/b$i"; done
gh update-ref -d refs/heads/b7
git -C "$T"/h switch -q b7; echo n > "$T"/h/n; git -C "$T"/h add n; git -C "$T"/h commit -qm n; git -C "$T"/h push -q origin b7
out=$(GS)
grep -q 'run would delete 6 branches' <<< "$out" && ok "deletion guard tripped" || fail "guard did not trip: $out"
[[ $(sent "branch 'b7' was deleted") == 0 ]] && ok "restore alert not sent for a skipped repo" || fail "restore alert sent although the repo was skipped"
grep -q "branch 'b7' was deleted" <<< "$out" && fail "restore alert logged for a skipped repo" || ok "restore alert not logged either"

echo "# 2. the run goes ahead: the alert is sent exactly once"
GS --allow-deletions >/dev/null
[[ $(sent "branch 'b7' was deleted") == 1 ]] && ok "restore alert sent once" || fail "restore alert sent $(sent "branch 'b7' was deleted") times"
[[ -n $(gh rev-parse -q --verify b7) ]] && ok "b7 restored on github" || fail "b7 not restored"

echo "# 3. counts in alert text are unpadded"
for r in $(gh for-each-ref --format='%(refname)' refs/heads); do gh update-ref -d "$r"; done
out=$(GS)
grep -qE 'github=0, gitea=[0-9]+\)' <<< "$out" && ok "empty-side alert reads github=0" || fail "padded or missing counts: $(grep emptyside -i <<< "$out"; grep 'no branches' <<< "$out")"

echo; (( FAILS == 0 )) && echo "all passed" || { echo "${FAILS} failed"; exit 1; }
