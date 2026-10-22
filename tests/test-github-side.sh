#!/usr/bin/env bash
# A protected branch that moves on GitHub, on a pair whose GitHub side is
# private, alerts: those commits skipped Gitea's pull request and CI, and
# GitHub Free enforces no ruleset on a private repository (Kamino item 97).
# They are still carried across. Gitea-side changes, unprotected branches and
# public GitHub sides do not alert.
#
# Usage: tests/test-github-side.sh   (no network, no tokens, --no-api)
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${HOLONET_SYNC:-${TEST_DIR}/../holonet-sync.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }

export GITHUB_TOKEN=x GITEA_TOKEN=y
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
commit() { echo "$3" > "$1/$3"; git -C "$1" add "$3"; git -C "$1" commit -qm "$3"; git -C "$1" push -q origin "$2"; }

# setup <name> <github visibility>: a synced pair p with main and feat, and
# clones h (Gitea) and w (GitHub) under $T/<name>.
setup() {
    local d="$T/$1"
    mkdir -p "$d"/gh/me "$d"/gt/me "$d"/cfg
    git init -q --bare -b main "$d"/gh/me/p.git
    git init -q --bare -b main "$d"/gt/me/p.git
    cat > "$d"/cfg/c.conf <<C
GITEA_URL="file://$d/gt"
GITHUB_GIT_BASE="file://$d/gh"
GITEA_USER=me; GITHUB_USER=me
STATE_DIR="$d/state"
ALERT_CMD="cat >> $d/alerts"
C
    echo "me/p me/p $2" > "$d"/cfg/repos.list
    git clone -q "$d"/gt/me/p.git "$d"/h 2>/dev/null
    commit "$d"/h main a
    git -C "$d"/h switch -qc feat; commit "$d"/h feat f; git -C "$d"/h switch -q main
    "$SYNC" run --no-api --config "$d"/cfg/c.conf >/dev/null 2>&1
    git clone -q "$d"/gh/me/p.git "$d"/w 2>/dev/null; git -C "$d"/w fetch -q origin feat
    : > "$d"/alerts
}
GS()  { "$SYNC" run --no-api --config "$T/$1"/cfg/c.conf 2>&1; }
tip() { git --git-dir="$T/$1/$2/me/p.git" rev-parse -q --verify "$3" 2>/dev/null || echo "-"; }

echo "# 1. private: main moved on GitHub alerts, and is still carried"
setup priv private
commit "$T"/priv/w main d
out=$(GS priv)
[[ $(tip priv gt main) == "$(tip priv gh main)" ]] && ok "carried to Gitea" || fail "main not carried"
grep -q "protected branch 'main' moved on GitHub (1 commit(s)" "$T"/priv/alerts && ok "alerted, with the commit count" || fail "no alert: $out"
grep -q "skipped Gitea's pull request and CI" "$T"/priv/alerts && ok "says what was skipped" || fail "alert text: $(cat "$T"/priv/alerts)"

echo "# 2. private: the same commits do not alert twice"
: > "$T"/priv/alerts; GS priv >/dev/null
[[ ! -s "$T"/priv/alerts ]] && ok "no repeat on the next run" || fail "repeated: $(cat "$T"/priv/alerts)"

echo "# 3. private: Gitea-side change and unprotected branch are quiet"
git -C "$T"/priv/h pull -q origin main
commit "$T"/priv/h main e
git -C "$T"/priv/w switch -q feat; commit "$T"/priv/w feat g
gt_main=$(tip priv gt main); gh_feat=$(tip priv gh feat)
GS priv >/dev/null
[[ $(tip priv gh main) == "$gt_main" && $(tip priv gt feat) == "$gh_feat" ]] && ok "Gitea's main and GitHub's feat both carried" || fail "not synced"
[[ ! -s "$T"/priv/alerts ]] && ok "no alert for either" || fail "alerted: $(cat "$T"/priv/alerts)"

echo "# 4. public: main moved on GitHub is quiet (a ruleset can guard it)"
setup pub public
commit "$T"/pub/w main d
GS pub >/dev/null
[[ $(tip pub gt main) == "$(tip pub gh main)" ]] && ok "carried to Gitea" || fail "main not carried"
[[ ! -s "$T"/pub/alerts ]] && ok "no alert" || fail "alerted: $(cat "$T"/pub/alerts)"

echo; (( FAILS == 0 )) && echo "all passed" || { echo "${FAILS} failed"; exit 1; }
