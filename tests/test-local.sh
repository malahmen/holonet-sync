#!/usr/bin/env bash
# End-to-end test for holonet-sync.sh against file:// bare repos — no network,
# no tokens, --no-api throughout. 19 scenarios: fast-forwards, new branches,
# excluded branches, deletions, restores, clean and conflicting divergence,
# tags, dry-run, both guards, reset, and a stale --force-with-lease rejection.
#
# Usage: tests/test-local.sh            # uses ../holonet-sync.sh
#        HOLONET_SYNC=/path/to/holonet-sync.sh tests/test-local.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${HOLONET_SYNC:-${TEST_DIR}/../holonet-sync.sh}"
[[ -f "$SYNC" ]] || { echo "holonet-sync.sh not found at $SYNC" >&2; exit 1; }

T=/tmp/holonet-sync-test; rm -rf $T; mkdir -p $T/gh/me $T/gt/me $T/cfg
git init -q --bare -b main $T/gh/me/proj.git
git init -q --bare -b main $T/gt/me/proj.git
cat > $T/cfg/holonet-sync.conf <<C
GITEA_URL="file://$T/gt"
GITHUB_GIT_BASE="file://$T/gh"
GITEA_USER=me; GITHUB_USER=me
STATE_DIR="$T/state"
EXCLUDE_BRANCHES="wip/*"
AUTO_MERGE_PROTECTED=1   # scenario 6 auto-merges main
ALERT_CMD='cat >> $T/alerts.log'
C
echo "me/proj me/proj private" > $T/cfg/repos.list
export GITHUB_TOKEN=x GITEA_TOKEN=y
GS() { "$SYNC" run --no-api --config $T/cfg/holonet-sync.conf "$@" 2>&1 | sed 's/^[^ ]* //'; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git clone -q $T/gt/me/proj.git $T/home 2>/dev/null; git clone -q $T/gh/me/proj.git $T/away 2>/dev/null
h() { git -C $T/home "$@"; }; a() { git -C $T/away "$@"; }
tip() { git --git-dir=$T/$1/me/proj.git rev-parse --short "$2" 2>/dev/null || echo "-"; }
both() { echo "   => $1: gitea=$(tip gt $1) github=$(tip gh $1)"; }

echo "## 1. seed on gitea, github empty"; echo a > $T/home/a; h add a; h commit -qm A; h push -q origin main; GS; both main
echo "## 2. rerun (must be no-op)"; GS
echo "## 3. commit on github -> ff gitea"; a pull -q origin main; echo b > $T/away/b; a add b; a commit -qm B; a push -q origin main; GS; both main
echo "## 4. new branch on gitea + excluded wip"; h pull -q origin main; h switch -qc feat; echo f>$T/home/f; h add f; h commit -qm F; h push -q origin feat; h switch -qc wip/x; h push -q origin wip/x; GS; both feat; both wip/x
echo "## 5. delete feat on github"; a fetch -q; a push -q origin :feat; GS; both feat
echo "## 6. clean divergence"; h switch -q main; echo c>$T/home/c; h add c; h commit -qm C; h push -q origin main; a pull -q origin main; echo d>$T/away/d; a add d; a commit -qm D; a push -q origin main; GS; both main
echo "## 7. rerun after merge (no-op)"; GS
echo "## 8. conflicting divergence"; h pull -q origin main; a pull -q origin main; echo home>$T/home/a; h commit -qam H; h push -q origin main; echo away>$T/away/a; a commit -qam W; a push -q origin main; GS; both main
echo "## 9. rerun, alert must not repeat"; GS; echo "alerts sent:"; cat $T/alerts.log
echo "## 10. tags"; a tag v1 origin/main~0 2>/dev/null || a tag v1; a push -q origin v1; GS; echo "   gitea v1=$(tip gt v1)"
echo "## 11. dry-run"; h tag v2; h push -q origin v2; GS --dry-run; echo "   github v2=$(tip gh v2)"
echo "## 12. status"; "$SYNC" status --config $T/cfg/holonet-sync.conf
echo "## 13. manual resolution at home -> ff github"; h fetch -q; git -C $T/home remote add gh $T/gh/me/proj.git; h fetch -q gh; h merge -q gh/main >/dev/null 2>&1; echo resolved>$T/home/a; h commit -qam R; h push -q origin main; GS; both main
echo "## 14. protected main deleted on github -> restored"; git --git-dir=$T/gh/me/proj.git update-ref -d refs/heads/main; GS; both main
echo "## 15. github emptied -> empty-side guard"; for r in $(git --git-dir=$T/gh/me/proj.git for-each-ref --format='%(refname)' refs/heads); do git --git-dir=$T/gh/me/proj.git update-ref -d $r; done; GS; both main
echo "## 16. reset then run -> reseed, nothing deleted"; "$SYNC" reset --repo me/proj --config $T/cfg/holonet-sync.conf 2>&1 | sed 's/^[^ ]* //'; GS; both main
echo "## 17. lease: remote moves between fetch and push (simulated via stale expect)";
# do_push is lifted straight out of the script and fed hand-set globals, so the
# linter can neither follow the source nor see where those vars are used.
# shellcheck disable=SC1090,SC2034
( source <(sed -n '/^do_push()/,/^}/p' "$SYNC"); WS=$T/state/repos/me__proj.git; TMP=$(mktemp -d); DRY_RUN=0; PUSHES=0; KEY=k; CUR_REPO=me/proj; STATE_DIR=$T/state; ALERT_CMD=""; label(){ echo $1; }; info(){ echo "INFO $*"; }; alert(){ echo "ALERT $2"; }
  cur=$(git --git-dir=$T/gt/me/proj.git rev-parse main); old=$(git --git-dir=$T/gt/me/proj.git rev-parse main~1)
  do_push gt heads main "$old" "$old" ; echo "   gitea main still $(tip gt main) (expected ${cur:0:7})" )
echo "## 18. protected main deleted on github (other branch present) -> restored"; h switch -qc other; h push -q origin other; GS >/dev/null; git --git-dir=$T/gh/me/proj.git update-ref -d refs/heads/main; GS; both main
echo "## 19. deletion guard"; for i in 1 2 3 4 5 6; do h branch -q b$i main; h push -q origin b$i; done; GS >/dev/null; for i in 1 2 3 4 5 6; do git --git-dir=$T/gh/me/proj.git update-ref -d refs/heads/b$i; done; GS; both b1; GS --allow-deletions | tail -3; both b1
