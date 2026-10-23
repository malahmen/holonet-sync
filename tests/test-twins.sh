#!/usr/bin/env bash
# The API half of a run, which every other end-to-end suite skips with
# --no-api (Kamino items 129 and 130): ensure_twins' visibility gate,
# --no-create, a created twin read back, `check` failing on a mismatch, the
# protected-branch alert keyed on what GitHub IS, and trailing comments in the
# repo list.
#
# No network: git remotes are file://, and `curl` is a stub on PATH that
# answers from $T/api/<gt|gh>/<owner>/<name> (the repository's `private`
# field; no file is a 404) and creates the bare repository on a POST.
#
# Usage: tests/test-twins.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${HOLONET_SYNC:-${TEST_DIR}/../holonet-sync.sh}"
[[ -f "$SYNC" ]] || { echo "holonet-sync.sh not found at $SYNC" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export T
mkdir -p "$T/gh/me" "$T/gt/me" "$T/cfg" "$T/bin" "$T/api/gh/me" "$T/api/gt/me"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GITHUB_TOKEN=x GITEA_TOKEN=y

# The stub: -o FILE gets the body, stdout gets -w's status code. POST to
# /user/repos creates the repository, private as asked unless $T/policy says
# otherwise (an organisation's policy overriding the request).
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=/dev/null method=GET data="" url="" dump=0
while (( $# )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -X) method="$2"; shift 2 ;;
        --data) data="$2"; shift 2 ;;
        -D) dump=1; shift 2 ;;
        -H|-w|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    file://"$T"/gt/api/v1*) side=gt; path="${url#file://"$T"/gt/api/v1}" ;;
    http://gh.invalid*)     side=gh; path="${url#http://gh.invalid}" ;;
    *) echo "stub: unexpected url $url" >&2; printf 000; exit 0 ;;
esac
echo "$side $method $path" >> "$T/api.log"
(( dump )) && exit 0
case "$method $path" in
    "GET /user") echo '{"login":"me"}' > "$out"; printf 200 ;;
    "GET /repos/"*/push_mirrors) echo '[]' > "$out"; printf 200 ;;
    "GET /repos/"*)
        f="$T/api/$side/${path#/repos/}"
        if [[ -f "$f" ]]; then
            p="$(cat "$f")"
            if [[ "$p" == none ]]; then echo '{"default_branch":"main"}' > "$out"
            else printf '{"private":%s,"default_branch":"main"}\n' "$p" > "$out"; fi
            printf 200
        else echo '{"message":"Not Found"}' > "$out"; printf 404; fi ;;
    "POST /user/repos")
        name="$(jq -r .name <<<"$data")"; p="$(jq -r .private <<<"$data")"
        [[ -f "$T/policy" ]] && p="$(cat "$T/policy")"
        echo "$p" > "$T/api/$side/me/$name"
        git init -q --bare -b main "$T/$side/me/$name.git"
        printf '{"private":%s}\n' "$p" > "$out"; printf 201 ;;
    *) echo '{"message":"stub: no route"}' > "$out"; printf 404 ;;
esac
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

cat > "$T/cfg/holonet-sync.conf" <<C
GITEA_URL="file://$T/gt"
GITHUB_GIT_BASE="file://$T/gh"
GITHUB_API="http://gh.invalid"
GITEA_USER=me; GITHUB_USER=me
STATE_DIR="$T/state"
ALERT_CMD='cat >> $T/alerts.log'
C
LIST="$T/cfg/repos.list"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
not()   { ! "$@"; }
said()  { grep -q -- "$1" "$T/last.out"; }
RC=0
GS() { "$SYNC" "$@" --config "$T/cfg/holonet-sync.conf" > "$T/last.out" 2>&1; RC=$?; }
tip() { git --git-dir="$T/$1/me/$2.git" rev-parse -q --verify refs/heads/main 2>/dev/null || echo -; }
synced() { local g; g=$(tip gt "$1"); [[ "$g" != - && "$g" == "$(tip gh "$1")" ]]; }
alerts() { grep -c -- "$1" "$T/alerts.log" 2>/dev/null || true; }

# pair <name> [gitea-private] [github-private] — both bare repositories, the
# Gitea one seeded with a commit; an empty value leaves that side missing.
pair() {
    local n="$1" c="$T/seed-$1"
    if [[ -n "${2-false}" ]]; then
        git init -q --bare -b main "$T/gt/me/$n.git"; echo "${2-false}" > "$T/api/gt/me/$n"
        git clone -q "$T/gt/me/$n.git" "$c" 2>/dev/null
        echo "$n" > "$c/f"; git -C "$c" add f; git -C "$c" commit -qm "$n"; git -C "$c" push -q origin main
    fi
    if [[ -n "${3-false}" ]]; then git init -q --bare -b main "$T/gh/me/$n.git"; echo "${3-false}" > "$T/api/gh/me/$n"; fi
}

pair leak    false false   # declared github-private; GitHub is public
pair unread  false none    # declared github-private; no 'private' field
pair ok      false true    # private on GitHub, public on Gitea, as declared
pair gtleak  false true    # declared private on BOTH sides; Gitea is public
pair pubdecl false true    # declared public; GitHub is private (nothing leaks)
pair create  false ""      # GitHub side missing
pair policy  false ""      # GitHub side missing; created public by policy
cat > "$LIST" <<L
# a full-line comment
me/leak     me/leak     private public
me/unread   me/unread   private public
me/ok       me/ok       private public
me/gtleak   me/gtleak   private private
me/pubdecl  me/pubdecl  public   # three columns, then a comment
me/create   me/create   private public
me/policy   me/policy   private public
L

echo "== 129: nothing private is pushed somewhere public =="
GS run --repo me/leak
check "declared private, GitHub public: run fails"     test "$RC" -ne 0
check "  nothing reaches GitHub"                       test "$(tip gh leak)" = -
check "  saying which side and why"                    said "github:me/leak is public but the list declares it private"
check "  recorded as ERROR in status"                  bash -c '"$1" status --config "$2" 2>/dev/null | grep "me/leak" | grep -q ERROR' _ "$SYNC" "$T/cfg/holonet-sync.conf"
check "  and alerted"                                  test "$(alerts "me/leak")" -eq 1
GS run --repo me/leak
check "a second run does not alert again"              test "$(alerts "me/leak")" -eq 1
GS run --repo me/unread
check "an unreadable visibility is refused too"        test "$(tip gh unread)" = -
GS run --repo me/gtleak
check "declared private on Gitea, Gitea public: refused" said "gitea:me/gtleak is public but the list declares it private"
GS run --repo me/ok
check "private as declared syncs"                      synced ok
check "  and the run succeeds"                         test "$RC" -eq 0
GS run --repo me/pubdecl
check "declared public, actually private: still syncs" synced pubdecl

echo
echo "== creation, and --no-create =="
GS run --repo me/create --no-create
check "--no-create: a missing twin fails the run"      test "$RC" -ne 0
check "  saying so"                                    said "does not exist, and --no-create is set"
check "  and nothing is created"                       not grep -q "POST" "$T/api.log"
GS run --repo me/create
check "without it, the twin is created private"        test "$(cat "$T/api/gh/me/create")" = true
check "  and synced"                                   synced create
echo false > "$T/policy"
GS run --repo me/policy
rm -f "$T/policy"
check "a twin created public despite the request: refused" said "github:me/policy is public but the list declares it private"
check "  nothing pushed into it"                       test "$(tip gh policy)" = -

echo
echo "== check fails on a mismatch =="
GS check --repo me/ok
check "check passes when every side is as declared"   test "$RC" -eq 0
GS check --repo me/pubdecl
check "check exits non-zero on a mismatch"            test "$RC" -ne 0
check "  naming it"                                   said "github:me/pubdecl is private but the list declares public"

echo
echo "== 130: the protected-branch alert follows what GitHub is =="
# pubdecl is declared public, and is private: GitHub enforces no ruleset on
# it, so a commit made there to main skipped Gitea's review.
c="$T/away"; git clone -q "$T/gh/me/pubdecl.git" "$c" 2>/dev/null
echo away > "$c/g"; git -C "$c" add g; git -C "$c" commit -qm away; git -C "$c" push -q origin main
GS run --repo me/pubdecl
check "the alert fires for a GitHub side that IS private" said "protected branch 'main' moved on GitHub"

echo
echo "== 130: trailing comments =="
check "a trailing comment does not become the visibility" not grep -q "bad gitea visibility" "$T/last.out"
GS repos
check "repos lists the commented pair with its columns"    bash -c 'grep -qP "^me/pubdecl\tme/pubdecl\tpublic\tpublic$" "$1"' _ "$T/last.out"
check "a full-line comment is still skipped"               not said "a full-line"

echo
(( FAILS == 0 )) && echo "test-twins: all checks passed" || { echo "test-twins: ${FAILS} check(s) failed"; exit 1; }
