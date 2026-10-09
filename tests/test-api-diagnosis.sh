#!/usr/bin/env bash
# Regression test for api_diag: an API failure must be attributed to whoever
# actually caused it.
#
# The failure it exists for: Gitea had moved to https while a config still said
# http, so the server answered 400 with "Client sent an HTTP request to an
# HTTPS server." The old code looked for a JSON .message, found none, and
# reported "gitea token rejected (HTTP 400)" — sending the operator to look at
# a token that was perfectly good. A transport problem must not read as an
# authentication problem.
#
# Usage: tests/test-api-diagnosis.sh   (no network, no tokens)
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${HOLONET_SYNC:-${TEST_DIR}/../holonet-sync.sh}"
[ -f "$SYNC" ] || { echo "holonet-sync.sh not found at $SYNC" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }

# diag <target> <code> <api.json body> <curl.err body>
# api_diag reads ${TMP}/api.json and ${TMP}/curl.err, so both are crafted here
# rather than produced by a request: what is under test is the classification.
diag() {
    local target="$1" code="$2" body="$3" err="${4:-}"
    printf '%s' "$body" > "$T/api.json"
    printf '%s' "$err"  > "$T/curl.err"
    (
        TMP="$T"
        GITEA_URL="https://gitea.example:3000"; GITHUB_API="https://api.github.com"
        # api_msg is a one-liner with no closing brace of its own, so a
        # /^api_msg()/,/^}/ range stays open into api_diag and prints its body
        # twice. Grep the one-liner, range only the block.
        eval "$(grep -m1 '^api_msg()' "$SYNC"; sed -n '/^api_diag()/,/^}/p' "$SYNC")"
        api_diag "$target" "$code"
    )
}
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# --- a refused credential, and only that, says so -----------------------------
for code in 401 403; do
    out="$(diag gt "$code" '{"message":"invalid username, password or token"}')"
    if has 'credential refused' "$out" && has 'invalid username' "$out"
    then ok "HTTP ${code} reads as a refused credential"
    else fail "HTTP ${code} -> ${out}"; fi
done

# --- the regression: a non-JSON body is a transport problem, not a token one --
out="$(diag gt 400 'Client sent an HTTP request to an HTTPS server.')"
if has 'was not JSON' "$out" && has 'check GITEA_URL' "$out" \
   && has 'Client sent an HTTP request' "$out"
then ok "a non-JSON 400 points at the URL and quotes the server"
else fail "non-JSON 400 -> ${out}"; fi
if has 'credential' "$out" || has 'token' "$out"
then fail "a non-JSON 400 still blames the credential: ${out}"
else ok "  and says nothing about the token"; fi

# --- no answer at all names the unreachable side ------------------------------
out="$(diag gt '' '' 'curl: (7) Failed to connect to gitea.example port 3999')"
if has 'no answer from the API' "$out" && has 'Failed to connect' "$out" \
   && has 'GITEA_URL' "$out"
then ok "an empty code reads as unreachable, with curl's reason"
else fail "empty code -> ${out}"; fi

# --- a JSON error from the API is quoted as the API's own words ---------------
out="$(diag gh 404 '{"message":"Not Found"}')"
if has 'the API declined it' "$out" && has 'Not Found' "$out"
then ok "a JSON error is attributed to the API"
else fail "JSON 404 -> ${out}"; fi

# --- the hint names the variable for the side that failed --------------------
out="$(diag gh 400 'not json')"
if has 'check GITHUB_API' "$out" && ! has 'GITEA_URL' "$out"
then ok "the GitHub side points at GITHUB_API"
else fail "github hint -> ${out}"; fi

# --- and a body that is JSON but has no .message still is not a token error --
out="$(diag gt 500 '{"errors":["boom"]}')"
if has 'was not JSON' "$out" || has 'the API declined it' "$out"
then ok "a JSON body without .message is still not a credential error"
else fail "500 without .message -> ${out}"; fi

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
