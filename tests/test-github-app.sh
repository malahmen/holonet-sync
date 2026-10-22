#!/usr/bin/env bash
# The GitHub App sign-in: the JWT is what GitHub verifies, the installation
# token is what the run uses, git signs in as x-access-token, and an app does
# not try to create a repository it cannot. The app gives the sync its own
# identity on GitHub, so a ruleset can let it push to a protected main while
# nobody else can (Kamino item 97).
#
# Usage: tests/test-github-app.sh   (no network, no tokens; needs openssl)
# shellcheck disable=SC2034
# The settings below are read by the functions eval'd out of the engine;
# a linter cannot see that use from here.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="${HOLONET_SYNC:-${TEST_DIR}/../holonet-sync.sh}"
[ -f "$SYNC" ] || { echo "holonet-sync.sh not found at $SYNC" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }

openssl genrsa -traditional -out "$T/key.pem" 2048 2>/dev/null \
    || openssl genrsa -out "$T/key.pem" 2048 2>/dev/null
openssl rsa -in "$T/key.pem" -pubout -out "$T/pub.pem" 2>/dev/null

# The engine's functions under test, and quiet stand-ins for its logging.
ENGINE="$(grep -m1 '^b64url()' "$SYNC"
          grep -m1 '^app_mode()' "$SYNC"
          grep -m1 '^api_msg()' "$SYNC"
          for f in app_jwt app_token api_diag setup_auth create_gh; do sed -n "/^${f}()/,/^}/p" "$SYNC"; done)"
STUBS='error() { echo "error: $*" >&2; }; error_exit() { error "$*"; exit 1; }; info() { :; }'

b64d() { local s="$1"; s="${s//-/+}"; s="${s//_//}"; while (( ${#s} % 4 )); do s+="="; done; printf '%s' "$s" | openssl base64 -d -A; }

# --- the JWT ------------------------------------------------------------------
jwt="$(TMP="$T"; GITHUB_APP_ID=5399575; GITHUB_APP_KEY_FILE="$T/key.pem"; eval "$STUBS"; eval "$ENGINE"; app_jwt)"
IFS=. read -r h p s <<< "$jwt"
if [[ -n "$h" && -n "$p" && -n "$s" ]]; then ok "the JWT has three segments"; else fail "JWT: ${jwt}"; fi
if [[ "$(b64d "$h" | jq -r .alg)" == RS256 ]]; then ok "signed RS256"; else fail "header: $(b64d "$h")"; fi
payload="$(b64d "$p")"
if [[ "$(jq -r .iss <<< "$payload")" == 5399575 ]]; then ok "issued by the app"; else fail "payload: ${payload}"; fi
life=$(( $(jq .exp <<< "$payload") - $(jq .iat <<< "$payload") ))
if (( life == 600 )); then ok "valid 10 minutes from a minute back"; else fail "lifetime ${life}s"; fi
printf '%s.%s' "$h" "$p" > "$T/signed"
b64d "$s" > "$T/sig"
if openssl dgst -sha256 -verify "$T/pub.pem" -signature "$T/sig" "$T/signed" >/dev/null 2>&1
then ok "the signature verifies with the app's public key"; else fail "the signature does not verify"; fi

# --- the installation token -----------------------------------------------------
# curl stands in for GitHub: it answers the access_tokens call and records what
# it was asked.
fake_curl='curl() {
    local out="" url="" hdr="" a
    while (( $# )); do
        case "$1" in -o) out="$2"; shift ;; -H) hdr="${2#@}"; shift ;; -w|-X|--max-time) shift ;; http*) url="$1" ;; esac
        shift
    done
    printf "%s\n" "$url" > "$T/asked-url"; cp "$hdr" "$T/asked-header" 2>/dev/null
    printf "%s" "$BODY" > "$out"; printf "%s" "$CODE"
}'
token() {
    ( TMP="$T"; GITHUB_API="https://api.github.com"; GITHUB_APP_ID=5399575
      GITHUB_APP_INSTALLATION_ID=173478038; GITHUB_APP_KEY_FILE="$T/key.pem"; CONFIG_FILE=x
      CODE="$1"; BODY="$2"; eval "$STUBS"; eval "$ENGINE"; eval "$fake_curl"; app_token )
}
tok="$(token 201 '{"token":"ghs_abc","permissions":{"contents":"write","workflows":"write"}}')"
if [[ "$tok" == ghs_abc ]]; then ok "the installation token is returned"; else fail "token: ${tok}"; fi
if grep -qx 'https://api.github.com/app/installations/173478038/access_tokens' "$T/asked-url"
then ok "asked for the installation's token"; else fail "asked $(cat "$T/asked-url")"; fi
if grep -q '^Authorization: Bearer .*\..*\.' "$T/asked-header"; then ok "with the JWT as the bearer"; else fail "header: $(cat "$T/asked-header")"; fi
if [[ ! -e "$T/app.h" ]] && ! grep -q ghs_abc "$T/api.json"; then ok "neither the JWT nor the token is left in TMP"; else fail "credentials left in TMP"; fi
if [[ "$(jq -r .workflows "$T/app-perms.json")" == write ]]; then ok "the permissions are kept for check"; else fail "perms: $(cat "$T/app-perms.json")"; fi

err="$(token 401 '{"message":"A JSON web token could not be decoded"}' 2>&1 >/dev/null)"; rc=$?
if (( rc != 0 )) && [[ "$err" == *"credential refused"* && "$err" == *"could not be decoded"* ]]
then ok "a refused JWT fails the run and says why"; else fail "rc ${rc}: ${err}"; fi

# --- git signs in as x-access-token ---------------------------------------------
basic="$(TMP="$T"; GITHUB_USER=malahmen; GITHUB_TOKEN=ghs_abc; GITEA_USER=g; GITEA_TOKEN=t
         GITHUB_GIT_BASE=https://github.com; GITEA_URL=https://gitea; GITHUB_APP_ID=5399575
         eval "$STUBS"; eval "$ENGINE"; setup_auth; printf '%s' "${GIT_CONFIG_VALUE_0#Authorization: Basic }")"
if [[ "$(printf '%s' "$basic" | base64 -d)" == "x-access-token:ghs_abc" ]]
then ok "git signs in to GitHub as x-access-token"; else fail "basic: $(printf '%s' "$basic" | base64 -d)"; fi
basic="$(TMP="$T"; GITHUB_USER=malahmen; GITHUB_TOKEN=ghp_abc; GITEA_USER=g; GITEA_TOKEN=t
         GITHUB_GIT_BASE=https://github.com; GITEA_URL=https://gitea; GITHUB_APP_ID=""
         eval "$STUBS"; eval "$ENGINE"; setup_auth; printf '%s' "${GIT_CONFIG_VALUE_0#Authorization: Basic }")"
if [[ "$(printf '%s' "$basic" | base64 -d)" == "malahmen:ghp_abc" ]]
then ok "without an app, git signs in as GITHUB_USER, as before"; else fail "basic: $(printf '%s' "$basic" | base64 -d)"; fi

# --- an app does not try to create a repository --------------------------------
out="$(TMP="$T"; DRY_RUN=0; GITHUB_USER=malahmen; GITHUB_APP_ID=5399575
       eval "$STUBS"; eval "$ENGINE"; api() { echo called > "$T/api-called"; echo 201; }
       create_gh malahmen/new private 2>&1)"; rc=$?
if (( rc != 0 )) && [[ ! -e "$T/api-called" && "$out" == *"create it on GitHub"* ]]
then ok "an app says to create a missing repository by hand, and calls nothing"; else fail "rc ${rc}: ${out}"; fi

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
