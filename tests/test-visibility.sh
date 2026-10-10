#!/usr/bin/env bash
# Visibility reconciliation: the declared private/public against what each side
# actually is.
#
# The gap this closes: the column was read exactly once, when a missing twin
# was created, and never looked at again. arakyd sat private in Gitea while the
# list said public and GitHub agreed with the list — nothing compared them, so
# nothing said so.
#
# Usage: tests/test-visibility.sh   (no network, no tokens)
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${HOLONET_SYNC:-${TEST_DIR}/../holonet-sync.sh}"
[ -f "$SYNC" ] || { echo "holonet-sync.sh not found at $SYNC" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }
# `check "..." ! cmd` cannot work: check runs "$@", and `!` is a keyword, not a
# command. A wrapper function is the negation that survives being an argument.
not() { ! "$@"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# The two functions under test, lifted out of the engine. Same approach as
# test-api-diagnosis.sh: what is tested is the classification, not a request.
#
# info/warn are stand-ins rather than the real ones, which depend on _pfx and
# the colour variables. The decoration is not what these assertions are about,
# and reaching for it would mean eval'ing half the engine to test two
# functions.
DEFS="$(printf '%s\n' \
    'info() { printf "[info] %s\n" "$*"; }' \
    'warn() { printf "[warn] %s\n" "$*"; }'
    sed -n '/^_vis_word()/,/^}/p;/^_vis_report()/,/^}/p' "$SYNC")"
# vis — the combined output. rc_of — the exit status alone.
vis()   { ( eval "$DEFS"; "$@" ) 2>&1; }
rc_of() { ( eval "$DEFS"; "$@" >/dev/null 2>&1 ); }

echo "== _vis_word translates the API field =="
check "true is private"      test "$(vis _vis_word true)"  = private
check "false is public"      test "$(vis _vis_word false)" = public
# "unknown" and not a guess: a missing field must not read as public, which
# would turn "could not tell" into "this repository is exposed", or the reverse.
check "null is unknown"      test "$(vis _vis_word null)"  = unknown
check "empty is unknown"     test "$(vis _vis_word '')"    = unknown
check "a string is unknown"  test "$(vis _vis_word yes)"   = unknown

echo
echo "== agreement is reported and exits 0 =="
check "private matches true"  rc_of _vis_report "gitea:a/b" private true
check "public matches false"  rc_of _vis_report "github:a/b" public false
check "it says so"            has "private as declared" "$(vis _vis_report "gitea:a/b" private true)"

echo
echo "== a mismatch warns, names both values, and exits non-zero =="
# `! rc_of ...` and not a `bash -c`: a shell function is invisible to a child,
# which exits 127 and makes the negation true whatever the function does.
check "exits non-zero"            not rc_of _vis_report "gitea:x" public true
out=$(vis _vis_report "gitea:malahmen/arakyd" public true)
check "names the repository"      has "gitea:malahmen/arakyd" "$out"
check "says what it actually is"  has "is private" "$out"
check "says what was declared"    has "declares public" "$out"
# The tool must not resolve this itself: the fix may be to edit the list rather
# than the repository, and only a person knows which.
check "promises not to flip it"   has "will not flip" "$out"

out=$(vis _vis_report "github:a/b" private false)
check "the other direction too"   has "is public" "$out"
check "and its declaration"       has "declares private" "$out"

echo
echo "== an unreadable field is a warning, not a silent pass =="
check "exits non-zero"         not rc_of _vis_report "gitea:a/b" private null
out=$(vis _vis_report "gitea:a/b" private null)
check "says it cannot read it" has "unreadable" "$out"
check "and what was expected"  has "declared private" "$out"

echo
echo "== the fourth column, and what happens without it =="
# A real config file: load_config_file SOURCES it, so a REPOS_FILE handed in
# through the environment is overwritten by whatever the config says.
mkdir -p "$T/cfg" "$T/state"
cat > "$T/cfg/holonet-sync.conf" <<CONF
GITEA_URL="https://gitea.invalid"
GITEA_USER=me
GITHUB_USER=me
STATE_DIR="$T/state"
REPOS_FILE="$T/repos.list"
CONF
cat > "$T/repos.list" <<'LIST'
# a comment
one/a            one/a            private
two/b            two/b            public
three/c          three/c          private      public
four/d           four/d
five/e           five/e           bogus
six/f            six/f            private      bogus
malformed-line
LIST
out=$(bash "$SYNC" repos --config "$T/cfg/holonet-sync.conf" 2>&1)
tsv() { printf '%s\n' "$out" | awk -F'\t' -v r="$1" '$1==r {print $3"/"$4}'; }
check "one column means both sides"         test "$(tsv one/a)"   = "private/private"
check "public likewise"                     test "$(tsv two/b)"   = "public/public"
# The whole point of the change: an asymmetric pair can finally be stated.
check "two columns are kept apart"          test "$(tsv three/c)" = "private/public"
check "no column falls back to the default" test "$(tsv four/d)"  = "private/private"
check "a bad github visibility is skipped"  test -z "$(tsv five/e)"
check "a bad gitea visibility is skipped"   test -z "$(tsv six/f)"
check "and the gitea one is named as such"  has "bad gitea visibility" "$out"
check "a malformed line is skipped"         has "malformed line" "$out"
check "nothing else was dropped"            test "$(printf '%s\n' "$out" | grep -c "$(printf '\t')")" = 4

echo
if [ "$FAILS" -ne 0 ]; then echo "test-visibility: ${FAILS} check(s) failed" >&2; exit 1; fi
echo "test-visibility: all checks passed"
