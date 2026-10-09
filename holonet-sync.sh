#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# holonet-sync.sh — bidirectional Gitea <-> GitHub branch/tag reconciler
# (gum-free, flag-driven CLI engine).
#
# Keeps a list of Gitea repos and their GitHub twins converged, using a
# three-way comparison per branch: github tip / gitea tip / last-synced base.
#
#   - fast-forwards whichever side is behind
#   - creates branches that are new on one side
#   - propagates deletions (only when the surviving side is unchanged)
#   - auto-merges diverged branches when conflict-free, alerts otherwise
#   - never force-overwrites: every push carries a --force-with-lease
#
# Loop safety: a converged pair produces zero pushes. holonet-sync's own pushes
# therefore cannot start a cascade; the next run finds both sides equal.
#
# No prompts: everything is driven by commands and flags, so it drops into a
# cron job, a systemd timer, CI or a TUI alike. The interactive experience lives
# in a separate front-end (scomp-link) that drives this engine with flags — the
# holo-convert / navicomputer pattern.
#
# Requirements: bash >= 4, git >= 2.38 (merge-tree --write-tree), curl, jq,
# flock, base64, sha1sum. Nothing is auto-installed; `check` reports what's
# missing. Run --help for the command list.
#
# Config: ~/.config/holonet-sync/{holonet-sync.conf,repos.list}
# State:  ~/.local/state/holonet-sync/{repos,status,alerts}
# -----------------------------------------------------------------------------

# Associative arrays and mapfile are load-bearing here; macOS's system bash 3.2
# would fail later, mid-run, with far less obvious errors.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_NAME="holonet-sync"
VERSION="1.0.0"

# ---- gum-free status output (stderr; stdout stays clean for data) ------------
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Unattended runs (cron, a systemd timer) get a leading UTC timestamp, since a
# mail spool or a log file has no other clock; a terminal already has one, and
# gets colour instead.
if [[ -t 2 ]]; then
    C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_N=$'\033[0m'
    _pfx() { printf ''; }
else
    C_G=""; C_Y=""; C_R=""; C_C=""; C_N=""
    _pfx() { printf '%s ' "$(_ts)"; }
fi

info()       { printf '%s%s[info]%s  %s\n'  "$(_pfx)" "$C_C" "$C_N" "$*" >&2; }
success()    { printf '%s%s[ok]%s    %s\n'  "$(_pfx)" "$C_G" "$C_N" "$*" >&2; }
warn()       { printf '%s%s[warn]%s  %s\n'  "$(_pfx)" "$C_Y" "$C_N" "$*" >&2; }
error()      { printf '%s%s[error]%s %s\n'  "$(_pfx)" "$C_R" "$C_N" "$*" >&2; }
error_exit() { error "$*"; exit 1; }
dbg()        { if (( VERBOSE )); then printf '%s[debug] %s\n' "$(_pfx)" "$*" >&2; fi; }

command -v git &>/dev/null || error_exit "git is required."

# -----------------------------------------------------------------------------
# Defaults — every one of these can be overridden in the config file
# -----------------------------------------------------------------------------

CONFIG_FILE="${HOLONET_SYNC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/holonet-sync/holonet-sync.conf}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/holonet-sync"

GITEA_URL=""
GITEA_USER=""
GITEA_TOKEN_FILE=""
GITHUB_USER=""
GITHUB_TOKEN_FILE=""
GITHUB_GIT_BASE="https://github.com"
GITHUB_API="https://api.github.com"
REPOS_FILE=""
DEFAULT_VISIBILITY="private"
PROTECTED_BRANCHES="main master"
PROPAGATE_REWRITES=0
EXCLUDE_BRANCHES=""
MAX_DELETIONS=5
AUTO_MERGE=1
AUTO_MERGE_PROTECTED=0
MERGE_AUTHOR_NAME="holonet-sync"
MERGE_AUTHOR_EMAIL="holonet-sync@localhost"
ALERT_CMD=""
ALLOW_LFS=0

# ---- runtime flags ----------------------------------------------------------
DRY_RUN=0
VERBOSE=0
NO_API=0
ALLOW_DELETIONS=0
ONLY_REPO=""
TMP=""
EACH_RC=0

# ---- per-repo working state (set in sync_repo, lives in a subshell) ----------
KEY="" WS="" CUR_REPO="" PUSHES=0 CONFLICTS=0 DRY_SKIP=0
PLAN=()
DEFER_ALERTS=0 ALERT_QUEUE=()

usage() {
    cat >&2 <<EOF
${SCRIPT_NAME} ${VERSION} — bidirectional Gitea <-> GitHub reconciler

USAGE
  ${SCRIPT_NAME}.sh <command> [flags]

COMMANDS
  init      write an example config and repo list (never overwrites)
  check     validate tools, tokens, repo access and Gitea push mirrors
  run       reconcile every repo in the list (or one, with --repo)
  status    show the last recorded result per repo (no network)
  reset     forget sync state for --repo (next run re-seeds; never deletes)
  config    print the resolved config/repos/state paths as key=value (stdout)
  repos     print the valid repo pairs from the list as TSV (stdout)
  version   print version

FLAGS
  --config PATH        config file (default: ${CONFIG_FILE/#$HOME/\~})
  --repo OWNER/NAME    limit to one Gitea repo from the list
  --dry-run            plan and report, push nothing
  --allow-deletions    bypass MAX_DELETIONS and the empty-side guard for this run
  --no-api             skip API lookups / twin creation (both repos must exist)
  -v, --verbose        debug logging
  -h, --help

Never force-pushes: every push and delete carries --force-with-lease, so a
remote that moved since the fetch fails the push instead of being overwritten.
Logs go to stderr; 'config', 'repos' and 'status' print their data on stdout.
EOF
}

# alert <dedup-key> <message>
# Logs always. Runs ALERT_CMD (message on stdin) once per dedup key, so a
# conflict that stays unresolved does not re-alert on every cron tick.
#
# While planning (DEFER_ALERTS=1) alerts are queued instead: a plan-time alert
# ("restoring it", "tag differs") must not be sent, or stamped as delivered,
# for a repo that a guard then skips. sync_repo flushes or drops the queue.
alert() {
    if (( DEFER_ALERTS )); then ALERT_QUEUE+=("$1" "$2"); return 0; fi
    local key="$1" msg="$2" stamp
    warn "ALERT: ${msg}"
    if [[ -z "$ALERT_CMD" ]] || (( DRY_RUN )); then return 0; fi

    stamp="${STATE_DIR}/alerts/$(printf '%s' "$key" | sha1sum | cut -c1-40)"
    if [[ -e "$stamp" ]]; then return 0; fi

    # Strip the credentials from the alert command's environment: it is
    # user-supplied and gets piped arbitrary repo/branch names.
    if printf '%s\n' "$msg" | env -u GIT_CONFIG_VALUE_0 -u GIT_CONFIG_VALUE_1 \
         -u GITHUB_TOKEN -u GITEA_TOKEN bash -c "$ALERT_CMD"; then
        : > "$stamp"
    else
        warn "ALERT_CMD failed"
    fi
}

flush_alerts() {
    local i
    DEFER_ALERTS=0
    for (( i = 0; i < ${#ALERT_QUEUE[@]}; i += 2 )); do alert "${ALERT_QUEUE[i]}" "${ALERT_QUEUE[i+1]}"; done
    ALERT_QUEUE=()
}

drop_alerts() {
    DEFER_ALERTS=0
    if (( ${#ALERT_QUEUE[@]} )); then dbg "dropped $(( ${#ALERT_QUEUE[@]} / 2 )) planned alert(s): repo skipped"; fi
    ALERT_QUEUE=()
}

label() { if [[ "$1" == gh ]]; then echo github; else echo gitea; fi; }

# =============================================================================
# config / auth
# =============================================================================

load_config_file() {
    [[ -r "$CONFIG_FILE" ]] || error_exit "config not found: ${CONFIG_FILE} (run: ${SCRIPT_NAME}.sh init)"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    : "${REPOS_FILE:=$(dirname "$CONFIG_FILE")/repos.list}"
    GITEA_URL="${GITEA_URL%/}"
    GITHUB_GIT_BASE="${GITHUB_GIT_BASE%/}"

    [[ -n "$GITEA_URL"   ]] || error_exit "GITEA_URL is not set in ${CONFIG_FILE}"
    [[ -n "$GITEA_USER"  ]] || error_exit "GITEA_USER is not set in ${CONFIG_FILE}"
    [[ -n "$GITHUB_USER" ]] || error_exit "GITHUB_USER is not set in ${CONFIG_FILE}"
    [[ "$MAX_DELETIONS" =~ ^[0-9]+$ ]] || error_exit "MAX_DELETIONS must be an integer"

    mkdir -p "${STATE_DIR}"/{repos,status,alerts}
}

# Hard dependencies for a reconcile run. Nothing is installed here: an engine
# that layers OS packages behind your back is not something you put in a timer.
_require_tools() {
    local tool absent=()
    for tool in curl jq flock base64 sha1sum; do
        command -v "$tool" >/dev/null 2>&1 || absent+=("$tool")
    done
    (( ${#absent[@]} == 0 )) || error_exit "missing required tool(s): ${absent[*]} (see: ${SCRIPT_NAME}.sh check)"
}

# read_token <file> <LABEL> — echoed, so error_exit inside it would only kill
# the command substitution; callers add `|| exit 1` to make it fatal.
read_token() {
    local f="$1" tok_label="$2"
    [[ -n "$f" ]] || error_exit "${tok_label} token: set ${tok_label}_TOKEN (env) or ${tok_label}_TOKEN_FILE (config)"
    [[ -r "$f" ]] || error_exit "${tok_label} token file not readable: ${f}"
    tr -d '[:space:]' < "$f"
}

load_tokens() {
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then GITHUB_TOKEN=$(read_token "$GITHUB_TOKEN_FILE" GITHUB) || exit 1; fi
    if [[ -z "${GITEA_TOKEN:-}"  ]]; then GITEA_TOKEN=$(read_token "$GITEA_TOKEN_FILE" GITEA)   || exit 1; fi
}

# Credentials reach git through GIT_CONFIG_* environment variables: they never
# appear in argv (ps) nor in any repo's .git/config.
setup_auth() {
    local gh_b64 gt_b64
    gh_b64=$(printf '%s:%s' "$GITHUB_USER" "$GITHUB_TOKEN" | base64 | tr -d '\n')
    gt_b64=$(printf '%s:%s' "$GITEA_USER"  "$GITEA_TOKEN"  | base64 | tr -d '\n')

    export GIT_CONFIG_COUNT=2
    export GIT_CONFIG_KEY_0="http.${GITHUB_GIT_BASE}/.extraheader"
    export GIT_CONFIG_VALUE_0="Authorization: Basic ${gh_b64}"
    export GIT_CONFIG_KEY_1="http.${GITEA_URL}/.extraheader"
    export GIT_CONFIG_VALUE_1="Authorization: Basic ${gt_b64}"
    export GIT_TERMINAL_PROMPT=0

    # curl reads its API headers from files (-H @file) for the same reason.
    printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' \
        "$GITHUB_TOKEN" > "${TMP}/gh.h"
    printf 'Authorization: token %s\nAccept: application/json\n' "$GITEA_TOKEN" > "${TMP}/gt.h"
}

# api <gh|gt> <METHOD> <path> [json-body]
# Echoes the HTTP status code (000 on network failure); body lands in $TMP/api.json.
api() {
    local target="$1" method="$2" path="$3" body="${4:-}" base hdr
    case "$target" in
        gh) base="$GITHUB_API";         hdr="${TMP}/gh.h" ;;
        gt) base="${GITEA_URL}/api/v1"; hdr="${TMP}/gt.h" ;;
        *)  error_exit "api: unknown target '${target}'" ;;
    esac

    local args=(-sS --max-time 30 -o "${TMP}/api.json" -w '%{http_code}' -X "$method" -H "@$hdr")
    if [[ -n "$body" ]]; then args+=(-H 'Content-Type: application/json' --data "$body"); fi
    curl "${args[@]}" "${base}${path}" 2>>"${TMP}/curl.err" || true
}

api_msg() { jq -r '.message // empty' "${TMP}/api.json" 2>/dev/null || true; }

# api_diag <target> <code> — why a request failed, attributed to whoever
# actually said so.
#
# The failure this exists for: Gitea had moved to https while a config still
# said http, so the server answered 400 with "Client sent an HTTP request to
# an HTTPS server." api_msg looked for a JSON .message, found none, and check
# reported "gitea token rejected (HTTP 400)" — which sent the operator to look
# at a token that was perfectly good.
#
# 401 and 403 are the only codes that mean a credential was refused. An empty
# code means curl never got an answer. Anything else is the far end declining
# the request, and if its body is not even JSON then it is probably not the
# API talking at all — which points at the URL rather than the token.
api_diag() {
    local target="$1" code="$2" msg body var
    case "$target" in gh) var=GITHUB_API ;; gt) var=GITEA_URL ;; *) var="the base URL" ;; esac
    msg="$(api_msg)"
    case "$code" in
        401|403)
            printf 'credential refused (HTTP %s)%s' "$code" "${msg:+ — ${msg}}"
            ;;
        ''|000)
            body="$(tr -d '\r' < "${TMP}/curl.err" 2>/dev/null | grep -v '^$' | tail -1)"
            printf 'no answer from the API%s — is %s reachable?' "${body:+ (${body})}" "$var"
            ;;
        *)
            if [[ -n "$msg" ]]; then
                printf 'the API declined it (HTTP %s) — %s' "$code" "$msg"
            else
                body="$(head -c 120 "${TMP}/api.json" 2>/dev/null | tr -d '\r\n')"
                printf 'HTTP %s and the body was not JSON%s — check %s (scheme, host, port)' \
                    "$code" "${body:+: \"${body}\"}" "$var"
            fi
            ;;
    esac
}

# =============================================================================
# twin repo lookup / creation
# =============================================================================

# create_gh <owner/name> <visibility>
create_gh() {
    local full="$1" vis="$2" owner="${1%%/*}" name="${1#*/}" path body code private=true
    [[ "$vis" == public ]] && private=false
    if (( DRY_RUN )); then info "[dry-run] would create github:${full} (${vis})"; DRY_SKIP=1; return 0; fi

    body=$(jq -nc --arg n "$name" --argjson p "$private" '{name:$n, private:$p, auto_init:false}')
    if [[ "${owner,,}" == "${GITHUB_USER,,}" ]]; then path="/user/repos"; else path="/orgs/${owner}/repos"; fi

    code=$(api gh POST "$path" "$body")
    if [[ "$code" != 201 ]]; then error "creating github:${full} failed: $(api_diag gh "$code")"; return 1; fi
    info "created github:${full} (${vis})"
}

# create_gt <owner/name> <visibility> <default-branch>
create_gt() {
    local full="$1" vis="$2" def="$3" owner="${1%%/*}" name="${1#*/}" path body code private=true
    [[ "$vis" == public ]] && private=false
    if (( DRY_RUN )); then info "[dry-run] would create gitea:${full} (${vis})"; DRY_SKIP=1; return 0; fi

    body=$(jq -nc --arg n "$name" --argjson p "$private" --arg d "$def" \
        '{name:$n, private:$p} + (if $d != "" then {default_branch:$d} else {} end)')
    if [[ "${owner,,}" == "${GITEA_USER,,}" ]]; then path="/user/repos"; else path="/orgs/${owner}/repos"; fi

    code=$(api gt POST "$path" "$body")
    if [[ "$code" != 201 ]]; then error "creating gitea:${full} failed: $(api_diag gt "$code")"; return 1; fi
    info "created gitea:${full} (${vis})"
}

# ensure_twins <gitea owner/name> <github owner/name> <visibility>
ensure_twins() {
    local gt_full="$1" gh_full="$2" vis="$3" gt_code gh_code gh_def=""
    gt_code=$(api gt GET "/repos/${gt_full}")
    gh_code=$(api gh GET "/repos/${gh_full}")
    if [[ "$gh_code" == 200 ]]; then gh_def=$(jq -r '.default_branch // empty' "${TMP}/api.json"); fi

    case "${gt_code}:${gh_code}" in
        200:200) return 0 ;;
        404:404) error "neither gitea:${gt_full} nor github:${gh_full} exists"; return 1 ;;
        200:404) create_gh "$gh_full" "$vis" ;;
        404:200) create_gt "$gt_full" "$vis" "$gh_def" ;;
        *)       error "API lookup failed (gitea HTTP ${gt_code}, github HTTP ${gh_code})"; return 1 ;;
    esac
}

# =============================================================================
# git helpers — all operate on the bare workspace $WS
# =============================================================================

rev()         { git -C "$WS" rev-parse -q --verify "$1" 2>/dev/null || true; }
is_sha()      { [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; }
is_ancestor() { git -C "$WS" merge-base --is-ancestor "$1" "$2"; }
count_refs()  { git -C "$WS" for-each-ref --format=x "$1" | wc -l | tr -d ' '; }  # BSD wc pads
list_names()  { git -C "$WS" for-each-ref --format='%(refname)' "$1" | sed "s|^$1||"; }

# uses_lfs — true when any fetched branch tip routes paths through Git LFS.
# One git-grep over every distinct tip, root and nested .gitattributes.
uses_lfs() {
    local -a tips
    mapfile -t tips < <(git -C "$WS" for-each-ref --format='%(objectname)' refs/gh/heads/ refs/gt/heads/ | sort -u)
    (( ${#tips[@]} )) || return 1
    git -C "$WS" grep -q -e 'filter=lfs' "${tips[@]}" -- '.gitattributes' '*/.gitattributes' 2>/dev/null
}

# Symbolic HEAD of a remote, empty when unknown.
remote_default() {
    git -C "$WS" ls-remote --symref "$1" HEAD 2>/dev/null \
        | awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2; exit }' || true
}

# matches_any <name> <space-separated globs>
matches_any() {
    local name="$1" p; local -a pats
    read -ra pats <<< "$2"          # read does not glob-expand, unlike a bare for-loop
    # An empty pattern list is the common case (EXCLUDE_BRANCHES defaults to
    # empty); expanding an empty array under `set -u` is an error on bash < 4.4.
    (( ${#pats[@]} )) || return 1
    for p in "${pats[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$name" == $p ]]; then return 0; fi
    done
    return 1
}

is_excluded()  { matches_any "$1" "$EXCLUDE_BRANCHES"; }
is_protected() { matches_any "$1" "$PROTECTED_BRANCHES"; }

# =============================================================================
# planning
#   plan lines: op:kind:side:name:sha:expected   (':' is illegal in ref names)
# =============================================================================

add() { local IFS=:; PLAN+=("$*"); }

# Branch that exists only on the <have> side.
plan_one_sided() {
    local b="$1" have="$2" sha="$3" missing="$4" base="$5"
    if [[ -z "$base" ]]; then
        add push heads "$missing" "$b" "$sha" ""          # new branch
        add base heads - "$b" "$sha" ""
    elif is_protected "$b"; then
        alert "${KEY}|protdel|${b}|${missing}|${sha}" \
            "[${CUR_REPO}] protected branch '${b}' disappeared from $(label "$missing"); restoring it"
        add push heads "$missing" "$b" "$sha" ""
        add base heads - "$b" "$sha" ""
    elif [[ "$sha" == "$base" ]]; then
        add del heads "$have" "$b" "" "$sha"              # deleted on <missing>, untouched on <have>
        add unbase heads - "$b" "" ""
    else
        alert "${KEY}|delmoved|${b}|${missing}|${sha}" \
            "[${CUR_REPO}] branch '${b}' was deleted on $(label "$missing") but has new commits on $(label "$have"); restoring it instead of deleting"
        add push heads "$missing" "$b" "$sha" ""
        add base heads - "$b" "$sha" ""
    fi
}

# Both sides moved since the last sync and at least one of them no longer
# contains the base: that side was force-pushed (amend, rebase, reset, a
# history scrub). Merging would bring the dropped commits back on both sides,
# and a fast-forward to the other side's tip would silently undo a rewind, so
# a rewrite is never merged. When only one side was rewritten and the other
# still sits on the base, PROPAGATE_REWRITES=1 carries the rewrite across under
# a lease on the base; otherwise it alerts and touches neither side.
plan_rewrite() {
    local b="$1" gt="$2" gh="$3" base="$4" rewritten="" other new
    if [[ "$gt" == "$base" ]]; then rewritten=gh other=gt new="$gh"
    elif [[ "$gh" == "$base" ]]; then rewritten=gt other=gh new="$gt"
    fi

    if [[ -n "$rewritten" ]] && (( PROPAGATE_REWRITES )); then
        info "branch '${b}' was rewritten on $(label "$rewritten"); propagating to $(label "$other") (PROPAGATE_REWRITES=1)"
        add push heads "$other" "$b" "$new" "$base"
        add base heads - "$b" "$new" ""
        return 0
    fi

    CONFLICTS=$((CONFLICTS + 1))
    if [[ -n "$rewritten" ]]; then
        alert "${KEY}|rewrite|${b}|${gt}|${gh}" \
            "[${CUR_REPO}] branch '${b}' was rewritten (force-pushed) on $(label "$rewritten") and is unchanged on the other side; not merging it back and not propagating it (PROPAGATE_REWRITES=0). Resolve manually or set PROPAGATE_REWRITES=1"
    else
        alert "${KEY}|rewrite|${b}|${gt}|${gh}" \
            "[${CUR_REPO}] branch '${b}' was rewritten (force-pushed) and both sides changed since the last sync (gitea ${gt:0:10}, github ${gh:0:10}); resolve manually"
    fi
}

plan_branch() {
    local b="$1" gh gt base
    if is_excluded "$b"; then dbg "excluded: ${b}"; return 0; fi

    gh=$(rev "refs/gh/heads/$b")
    gt=$(rev "refs/gt/heads/$b")
    base=$(rev "refs/sync/base/heads/$b")

    if [[ -n "$gh" && -n "$gt" ]]; then
        if [[ "$gh" == "$gt" ]]; then
            if [[ "$base" != "$gh" ]]; then add base heads - "$b" "$gh" ""; fi
        elif [[ -n "$base" ]] && { ! is_ancestor "$base" "$gh" || ! is_ancestor "$base" "$gt"; }; then
            plan_rewrite "$b" "$gt" "$gh" "$base"
        elif is_ancestor "$gt" "$gh"; then
            add push heads gt "$b" "$gh" "$gt"; add base heads - "$b" "$gh" ""
        elif is_ancestor "$gh" "$gt"; then
            add push heads gh "$b" "$gt" "$gh"; add base heads - "$b" "$gt" ""
        else
            add merge heads - "$b" "$gt" "$gh"
        fi
    elif [[ -n "$gt" ]]; then
        plan_one_sided "$b" gt "$gt" gh "$base"
    elif [[ -n "$gh" ]]; then
        plan_one_sided "$b" gh "$gh" gt "$base"
    elif [[ -n "$base" ]]; then
        add unbase heads - "$b" "" ""                     # gone on both sides
    fi
}

# Tags are write-once: missing tags are copied, differing tags alert, and tag
# deletions are NOT propagated (a deleted tag is recreated from the other side).
plan_tag() {
    local t="$1" gh gt
    gh=$(rev "refs/gh/tags/$t")
    gt=$(rev "refs/gt/tags/$t")

    if [[ -n "$gh" && -n "$gt" ]]; then
        if [[ "$gh" != "$gt" ]]; then
            CONFLICTS=$((CONFLICTS + 1))
            alert "${KEY}|tag|${t}|${gt}|${gh}" \
                "[${CUR_REPO}] tag '${t}' differs (gitea ${gt:0:10}, github ${gh:0:10}); not touching it"
        fi
    elif [[ -n "$gt" ]]; then add push tags gh "$t" "$gt" ""
    elif [[ -n "$gh" ]]; then add push tags gt "$t" "$gh" ""
    fi
}

# =============================================================================
# execution
# =============================================================================

# do_push <side> <kind> <name> <sha> <expected-or-empty>
do_push() {
    local side="$1" kind="$2" name="$3" sha="$4" exp="$5" ref="refs/$2/$3"
    # An empty source turns `<sha>:<ref>` into `:<ref>`, which is a DELETE that
    # the lease would happily allow. Only do_delete may remove a ref.
    # (Inline rather than is_sha: tests source do_push on its own.)
    if [[ ! "$sha" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
        alert "${KEY}|badsha|${side}|${ref}|${sha}" \
            "[${CUR_REPO}] internal: refusing to push '${sha}' to $(label "$side"):${ref} (not an object id)"
        return 1
    fi
    if (( DRY_RUN )); then
        info "[dry-run] push ${sha:0:10} -> $(label "$side"):${ref} (expecting ${exp:0:10}${exp:-absent})"
        return 0
    fi

    # --force-with-lease=<ref>:<expect> — the push only lands if the remote
    # still holds <expect> (empty = must not exist). A concurrent push makes it
    # fail safely instead of being overwritten; the next run picks the change up.
    if git -C "$WS" push --quiet --force-with-lease="${ref}:${exp}" "$side" "${sha}:${ref}" 2>"${TMP}/push.err"; then
        PUSHES=$((PUSHES + 1))
        git -C "$WS" update-ref "refs/${side}/${kind}/${name}" "$sha" \
            || { error "pushed, but could not record refs/${side}/${kind}/${name} locally"; return 1; }
        info "pushed ${sha:0:10} -> $(label "$side"):${ref}"
    else
        alert "${KEY}|pushfail|${side}|${ref}|${sha}" \
            "[${CUR_REPO}] push to $(label "$side"):${ref} failed: $(tr '\n' ' ' < "${TMP}/push.err")"
        return 1
    fi
}

# do_delete <side> <kind> <name> <expected>
do_delete() {
    local side="$1" kind="$2" name="$3" exp="$4" ref="refs/$2/$3"
    if (( DRY_RUN )); then info "[dry-run] delete $(label "$side"):${ref} (expecting ${exp:0:10})"; return 0; fi

    if git -C "$WS" push --quiet --force-with-lease="${ref}:${exp}" "$side" ":${ref}" 2>"${TMP}/push.err"; then
        PUSHES=$((PUSHES + 1))
        git -C "$WS" update-ref -d "refs/${side}/${kind}/${name}" \
            || { error "deleted, but could not drop refs/${side}/${kind}/${name} locally"; return 1; }
        info "deleted $(label "$side"):${ref} (deleted on the other side)"
    else
        alert "${KEY}|delfail|${side}|${ref}|${exp}" \
            "[${CUR_REPO}] delete of $(label "$side"):${ref} failed: $(tr '\n' ' ' < "${TMP}/push.err")"
        return 1
    fi
}

set_base() {
    if (( DRY_RUN )); then return 0; fi
    git -C "$WS" update-ref "refs/sync/base/heads/$1" "$2"
}

unset_base() {
    if (( DRY_RUN )); then return 0; fi
    git -C "$WS" update-ref -d "refs/sync/base/heads/$1" 2>/dev/null || true
}

# do_merge <branch> <gitea-sha> <github-sha>
do_merge() {
    local b="$1" gt="$2" gh="$3" out tree m rc
    local tag="${KEY}|diverged|${b}|${gt}|${gh}"

    if (( ! AUTO_MERGE )); then
        CONFLICTS=$((CONFLICTS + 1))
        alert "$tag" "[${CUR_REPO}] branch '${b}' diverged (gitea ${gt:0:10}, github ${gh:0:10}); AUTO_MERGE=0, resolve manually"
        return 1
    fi
    # A textually clean merge is not a reviewed one: on the branches that
    # matter most (main, release lines) the merge is left to a human unless
    # explicitly allowed.
    if is_protected "$b" && (( ! AUTO_MERGE_PROTECTED )); then
        CONFLICTS=$((CONFLICTS + 1))
        alert "$tag" "[${CUR_REPO}] protected branch '${b}' diverged (gitea ${gt:0:10}, github ${gh:0:10}); AUTO_MERGE_PROTECTED=0, resolve manually"
        return 1
    fi

    # In-memory merge in the bare repo: exit 0 = clean, 1 = conflicts, other = error.
    if out=$(git -C "$WS" merge-tree --write-tree --no-messages "$gt" "$gh" 2>&1); then
        tree="${out%%$'\n'*}"
        if ! is_sha "$tree"; then
            CONFLICTS=$((CONFLICTS + 1))
            alert "$tag" "[${CUR_REPO}] branch '${b}' diverged; merge-tree returned no tree: ${tree}"
            return 1
        fi
    else
        rc=$?
        CONFLICTS=$((CONFLICTS + 1))
        if (( rc == 1 )); then
            alert "$tag" "[${CUR_REPO}] branch '${b}' diverged with conflicts (gitea ${gt:0:10}, github ${gh:0:10}); resolve manually"
        else
            alert "$tag" "[${CUR_REPO}] branch '${b}' diverged; merge failed (rc=${rc}): ${out%%$'\n'*}"
        fi
        return 1
    fi

    if (( DRY_RUN )); then info "[dry-run] would auto-merge '${b}' (clean): gitea ${gt:0:10} + github ${gh:0:10}"; return 0; fi

    # Checked explicitly: do_merge runs from an || context, where errexit is
    # off, and an empty $m would reach do_push as a delete.
    if ! m=$(GIT_AUTHOR_NAME="$MERGE_AUTHOR_NAME" GIT_AUTHOR_EMAIL="$MERGE_AUTHOR_EMAIL" \
        GIT_COMMITTER_NAME="$MERGE_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$MERGE_AUTHOR_EMAIL" \
        git -C "$WS" commit-tree "$tree" -p "$gt" -p "$gh" \
            -m "${SCRIPT_NAME}: merge diverged '${b}' (gitea ${gt:0:10} + github ${gh:0:10})" 2>"${TMP}/merge.err") \
       || ! is_sha "$m"; then
        CONFLICTS=$((CONFLICTS + 1))
        alert "$tag" "[${CUR_REPO}] branch '${b}' diverged cleanly but the merge commit could not be written: $(tr '\n' ' ' < "${TMP}/merge.err")"
        return 1
    fi
    info "auto-merged '${b}' -> ${m:0:10}"

    # If only one of the two pushes lands, base is not updated; the next run
    # sees a plain fast-forward (or a fresh divergence) and converges from there.
    do_push gt heads "$b" "$m" "$gt" || return 1
    do_push gh heads "$b" "$m" "$gh" || return 1
    set_base "$b" "$m"
}

# repo_key <gitea owner/name> — the per-repo name for the workspace, status
# file and alert keys. '+' is illegal in Gitea and GitHub owner and repo names,
# so no two pairs can collide. (The old `${full//\//__}` mapped both a__b/c and
# a/b__c to a__b__c, so two repos would have shared one workspace and base.)
repo_key()    { printf '%s+%s' "${1%%/*}" "${1#*/}"; }
legacy_key()  { printf '%s' "${1//\//__}"; }

# migrate_state <gitea owner/name> — move a workspace named by the old scheme and status file
# to the new key. Skipped when another listed repo maps to the same legacy key:
# that state is ambiguous, and re-seeding is safe (it only creates and merges).
migrate_state() {
    local full="$1" old new n
    old=$(legacy_key "$full"); new=$(repo_key "$full")
    [[ -d "${STATE_DIR}/repos/${old}.git" && ! -e "${STATE_DIR}/repos/${new}.git" ]] || return 0

    n=$(awk '$1 !~ /^#/ && NF >= 2 { k = $1; gsub("/", "__", k); print k }' "$REPOS_FILE" | grep -cxF -- "$old" || true)
    if (( n > 1 )); then
        warn "legacy state ${old}.git is shared by ${n} listed repos; not migrating it, ${full} re-seeds"
        return 0
    fi
    mv "${STATE_DIR}/repos/${old}.git" "${STATE_DIR}/repos/${new}.git"
    if [[ -e "${STATE_DIR}/status/${old}" ]]; then mv "${STATE_DIR}/status/${old}" "${STATE_DIR}/status/${new}"; fi
    info "migrated state ${old} -> ${new}"
}

# record_status <RESULT> [detail]
record_status() {
    if (( DRY_RUN )); then return 0; fi
    printf '%s\t%s\t%s\tpushes=%d conflicts=%d\t%s\n' \
        "$(_ts)" "$CUR_REPO" "$1" "$PUSHES" "$CONFLICTS" "${2:-}" > "${STATE_DIR}/status/${KEY}"
}

# =============================================================================
# per-repo reconcile — always runs inside its own `set -e` subshell (run_one)
# =============================================================================

# sync_repo <gitea owner/name> <github owner/name> <visibility>
sync_repo() {
    local gt_full="$1" gh_full="$2" vis="$3" side
    CUR_REPO="$gt_full"
    KEY=$(repo_key "$gt_full")
    WS="${STATE_DIR}/repos/${KEY}.git"
    PUSHES=0 CONFLICTS=0 DRY_SKIP=0 PLAN=() DEFER_ALERTS=0 ALERT_QUEUE=()
    info "== gitea:${gt_full} <-> github:${gh_full}"

    if (( ! NO_API )); then
        if ! ensure_twins "$gt_full" "$gh_full" "$vis"; then record_status ERROR "repo lookup/creation failed"; return 1; fi
        if (( DRY_SKIP )); then return 0; fi
    fi

    if (( ! DRY_RUN )); then migrate_state "$gt_full"; fi
    if [[ ! -d "$WS" ]]; then git init -q --bare "$WS"; fi
    git -C "$WS" config remote.gh.url "${GITHUB_GIT_BASE}/${gh_full}.git"
    git -C "$WS" config remote.gt.url "${GITEA_URL}/${gt_full}.git"

    # A failed fetch must abort: treating an unreachable side as "empty" would
    # look like every branch was deleted there.
    for side in gh gt; do
        if ! git -C "$WS" fetch --quiet --no-tags --prune "$side" \
                "+refs/heads/*:refs/${side}/heads/*" "+refs/tags/*:refs/${side}/tags/*" 2>"${TMP}/fetch.err"; then
            error "fetch from $(label "$side") failed: $(tr '\n' ' ' < "${TMP}/fetch.err")"
            record_status ERROR "fetch from $(label "$side") failed"
            return 1
        fi
    done

    # Guard: one side suddenly empty while we have history = recreated/wiped repo.
    local n_gh n_gt n_base
    n_gh=$(count_refs refs/gh/heads/); n_gt=$(count_refs refs/gt/heads/); n_base=$(count_refs refs/sync/base/heads/)
    if (( n_base > 0 && (n_gh == 0 || n_gt == 0) && ! ALLOW_DELETIONS )); then
        alert "${KEY}|emptyside|${n_gh}|${n_gt}" \
            "[${CUR_REPO}] one side has no branches but sync state exists (github=${n_gh}, gitea=${n_gt}); refusing. Use 'reset --repo ${gt_full}' or --allow-deletions"
        record_status ERROR "empty-side guard"
        return 1
    fi

    # Guard: Git LFS. git push carries only the pointer files; the LFS objects
    # live on each server's LFS store and would never reach the twin, leaving
    # it with dangling pointers. Refuse unless explicitly accepted.
    if uses_lfs && (( ! ALLOW_LFS )); then
        alert "${KEY}|lfs" \
            "[${CUR_REPO}] repo uses Git LFS; holonet-sync syncs refs only, so LFS objects would not reach the other side. Skipping (set ALLOW_LFS=1 to sync the pointers anyway)"
        record_status ERROR "uses Git LFS"
        return 1
    fi

    # Plan branches (default branch first, so a new twin gets the right
    # default), then tags.
    local def b t; local -a branches ordered=()
    DEFER_ALERTS=1
    def=$(remote_default gt); if [[ -z "$def" ]]; then def=$(remote_default gh); fi
    mapfile -t branches < <( { list_names refs/gh/heads/; list_names refs/gt/heads/; list_names refs/sync/base/heads/; } | sort -u )
    for b in "${branches[@]}"; do if [[ "$b" == "$def" ]]; then ordered+=("$b"); fi; done
    for b in "${branches[@]}"; do if [[ "$b" != "$def" ]]; then ordered+=("$b"); fi; done
    for b in "${ordered[@]}"; do plan_branch "$b"; done
    while IFS= read -r t; do plan_tag "$t"; done < <( { list_names refs/gh/tags/; list_names refs/gt/tags/; } | sort -u )

    # Nothing to do. Expanding an empty PLAN below would trip `set -u` on
    # bash < 4.4, and a tag conflict adds no plan entry but must still report.
    if (( ${#PLAN[@]} == 0 )); then
        flush_alerts
        if (( CONFLICTS == 0 )); then dbg "in sync"; fi
        record_status OK
        return 0
    fi

    # Guard: too many deletions in one run.
    local n_del
    n_del=$(printf '%s\n' "${PLAN[@]}" | grep -c '^del:' || true)
    if (( n_del > MAX_DELETIONS && ! ALLOW_DELETIONS )); then
        drop_alerts
        alert "${KEY}|maxdel|${n_del}" \
            "[${CUR_REPO}] run would delete ${n_del} branches (MAX_DELETIONS=${MAX_DELETIONS}); refusing. Re-run with --allow-deletions if intended"
        record_status ERROR "deletion guard (${n_del})"
        return 1
    fi

    flush_alerts

    # Execute. A failed step on a ref skips that ref's remaining steps,
    # including its base update.
    local line op kind side name sha exp failures=0; local -A failed=()
    for line in "${PLAN[@]}"; do
        IFS=: read -r op kind side name sha exp <<< "$line"
        if [[ -n "${failed[$kind/$name]:-}" ]]; then continue; fi
        case "$op" in
            push)   do_push "$side" "$kind" "$name" "$sha" "$exp" || { failed[$kind/$name]=1; failures=$((failures + 1)); } ;;
            del)    do_delete "$side" "$kind" "$name" "$exp"      || { failed[$kind/$name]=1; failures=$((failures + 1)); } ;;
            merge)  do_merge "$name" "$sha" "$exp"                || { failed[$kind/$name]=1; failures=$((failures + 1)); } ;;
            base)   set_base "$name" "$sha" ;;
            unbase) unset_base "$name" ;;
            *)      error_exit "internal: unknown plan op '${op}'" ;;
        esac
    done

    if (( failures > 0 )); then
        record_status PARTIAL "${failures} ref(s) not synced"
        return 1
    fi
    if (( PUSHES == 0 && CONFLICTS == 0 )); then dbg "in sync"; fi
    record_status OK
}

# =============================================================================
# repo list iteration
# =============================================================================

# for_each_repo <callback>
# Reads the repo list on fd 3 so nothing inside the loop can consume it.
# Always returns 0 and leaves the combined callback status in EACH_RC: callers
# must invoke it bare (never `for_each_repo … || …`), or bash would disable
# errexit for every callback, including run_one's per-repo subshell.
# Line format:  <gitea owner/name>  <github owner/name>  [private|public]
for_each_repo() {
    local cb="$1" gt_full gh_full vis rest matched=0 rc=0 cb_rc
    [[ -r "$REPOS_FILE" ]] || error_exit "repo list not found: ${REPOS_FILE}"

    while read -r gt_full gh_full vis rest <&3; do
        if [[ -z "${gt_full:-}" || "$gt_full" == \#* ]]; then continue; fi
        if [[ "$gt_full" != */* || "${gh_full:-}" != */* ]]; then warn "skipping malformed line: ${gt_full} ${gh_full:-}"; continue; fi
        vis="${vis:-$DEFAULT_VISIBILITY}"
        if [[ "$vis" != private && "$vis" != public ]]; then warn "bad visibility '${vis}' for ${gt_full}; skipping"; continue; fi
        if [[ -n "$ONLY_REPO" && "$gt_full" != "$ONLY_REPO" ]]; then continue; fi
        matched=$((matched + 1))
        # Not `"$cb" … || rc=1`: bash ignores errexit for everything run from
        # an ||/&&/if context, including the `( set -e; … )` subshell in
        # run_one, so the callback must be called bare and its status read
        # afterwards.
        set +e
        "$cb" "$gt_full" "$gh_full" "$vis"
        cb_rc=$?
        set -e
        (( cb_rc == 0 )) || rc=1
    done 3< "$REPOS_FILE"

    if [[ -n "$ONLY_REPO" ]] && (( matched == 0 )); then error_exit "${ONLY_REPO} is not in ${REPOS_FILE}"; fi
    EACH_RC=$rc
}

# Each repo reconciles in its own subshell, so a failure aborts that repo only.
# errexit holds inside it only because for_each_repo calls this bare (see
# there); helpers that sync_repo itself calls from an ||/if context (do_push,
# do_delete, do_merge, ensure_twins) check their own commands explicitly.
run_one() {
    ( set -e; sync_repo "$@" )
}

# =============================================================================
# commands
# =============================================================================

cmd_run() {
    _require_tools
    load_config_file; load_tokens; setup_auth

    exec 9> "${STATE_DIR}/run.lock"
    if ! flock -n 9; then info "another run is in progress; exiting"; return 0; fi

    find "${STATE_DIR}/alerts" -type f -mtime +30 -delete 2>/dev/null || true

    local rc
    for_each_repo run_one; rc=$EACH_RC
    if (( rc )); then warn "run finished with errors (see above / status)"; else success "run finished"; fi
    return "$rc"
}

version_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

check_repo() {
    local gt_full="$1" gh_full="$2" code n
    code=$(api gt GET "/repos/${gt_full}")
    case "$code" in
        200) info "gitea:${gt_full} ok" ;;
        404) warn "gitea:${gt_full} missing (run will create it)" ;;
        *)   error "gitea:${gt_full}: $(api_diag gt "$code")"; return 1 ;;
    esac

    # Gitea push mirrors force-push on their own schedule and would fight this
    # engine over every ref, so they are a hard failure rather than a warning.
    if [[ "$code" == 200 ]]; then
        code=$(api gt GET "/repos/${gt_full}/push_mirrors")
        if [[ "$code" == 200 ]]; then
            n=$(jq 'length' "${TMP}/api.json")
            if (( n > 0 )); then error "gitea:${gt_full} has ${n} push mirror(s): remove them, they force-push and will fight ${SCRIPT_NAME}"; return 1; fi
        else
            warn "gitea:${gt_full} could not list push mirrors: $(api_diag gt "$code"); check Settings > Repository > Mirror manually"
        fi
    fi

    code=$(api gh GET "/repos/${gh_full}")
    case "$code" in
        200) info "github:${gh_full} ok" ;;
        404) warn "github:${gh_full} missing or not visible to token (run will try to create it)" ;;
        *)   error "github:${gh_full}: $(api_diag gh "$code")"; return 1 ;;
    esac
}

cmd_check() {
    local ok=1 tool v code login scopes

    for tool in git curl jq flock base64 sha1sum; do
        command -v "$tool" >/dev/null 2>&1 || { error "missing tool: ${tool}"; ok=0; }
    done

    v=$(git version | awk '{print $3}')
    if version_ge "$v" 2.38; then info "git ${v} ok"; else error "git ${v} < 2.38 (needed for merge-tree --write-tree)"; ok=0; fi

    load_config_file; load_tokens; setup_auth

    # Credentials ride on an Authorization header (git) and a token header
    # (API): over plain http they cross the network readable by anyone on path.
    local name url
    for name in GITEA_URL GITHUB_GIT_BASE GITHUB_API; do
        url="${!name}"
        if [[ "$url" == http://* ]]; then
            warn "${name}=${url} is plain http: tokens are sent unencrypted. Use https unless this is a trusted loopback"
        fi
    done

    code=$(api gh GET /user)
    if [[ "$code" == 200 ]]; then
        login=$(jq -r .login "${TMP}/api.json"); info "github token ok (login: ${login})"
        [[ "${login,,}" == "${GITHUB_USER,,}" ]] || warn "GITHUB_USER=${GITHUB_USER} but token belongs to ${login}"
        scopes=$(curl -sS -o /dev/null -D - -H "@${TMP}/gh.h" "${GITHUB_API}/user" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')
        if [[ -n "$scopes" ]]; then
            info "classic token scopes: ${scopes}"
            [[ "$scopes" == *workflow* ]] || warn "token lacks 'workflow' scope: pushes touching .github/workflows/ will be rejected"
        else
            info "fine-grained token (no scope header): verify Contents, Workflows and Administration permissions"
        fi
    else
        error "github /user failed: $(api_diag gh "$code")"; ok=0
    fi

    code=$(api gt GET /user)
    if [[ "$code" == 200 ]]; then
        login=$(jq -r .login "${TMP}/api.json"); info "gitea token ok (login: ${login})"
        [[ "${login,,}" == "${GITEA_USER,,}" ]] || warn "GITEA_USER=${GITEA_USER} but token belongs to ${login}"
    else
        error "gitea /user failed: $(api_diag gt "$code")"; ok=0
    fi

    for_each_repo check_repo; (( EACH_RC == 0 )) || ok=0

    if (( ok )); then success "check passed"; else error "check failed"; return 1; fi
}

cmd_status() {
    load_config_file

    local files=("${STATE_DIR}"/status/*)
    if [[ ! -e "${files[0]}" ]]; then info "no runs recorded yet"; return 0; fi

    { printf 'LAST RUN\tREPO\tRESULT\tCOUNTS\tDETAIL\n'; cat "${files[@]}" | sort -t$'\t' -k2,2; } \
        | if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi
}

cmd_reset() {
    [[ -n "$ONLY_REPO" ]] || error_exit "reset needs --repo OWNER/NAME"
    load_config_file

    KEY=$(repo_key "$ONLY_REPO"); WS="${STATE_DIR}/repos/${KEY}.git"
    if [[ ! -d "$WS" && -d "${STATE_DIR}/repos/$(legacy_key "$ONLY_REPO").git" ]]; then
        KEY=$(legacy_key "$ONLY_REPO"); WS="${STATE_DIR}/repos/${KEY}.git"
    fi
    [[ -d "$WS" ]] || error_exit "no state for ${ONLY_REPO}"

    git -C "$WS" for-each-ref --format='delete %(refname)' refs/sync/base/ | git -C "$WS" update-ref --stdin
    rm -f "${STATE_DIR}/status/${KEY}"
    success "sync state cleared for ${ONLY_REPO}; next run re-seeds (creates/merges, never deletes)"
}

# Machine-readable paths on stdout, so a front-end (or a Makefile) can find the
# config without re-deriving the XDG defaults. Works before `init`.
cmd_config() {
    local repos
    if [[ -r "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
    repos="${REPOS_FILE:-$(dirname "$CONFIG_FILE")/repos.list}"

    printf 'config=%s\n'        "$CONFIG_FILE"
    printf 'config_exists=%d\n' "$( [[ -r "$CONFIG_FILE" ]] && echo 1 || echo 0 )"
    printf 'repos=%s\n'         "$repos"
    printf 'repos_exists=%d\n'  "$( [[ -r "$repos" ]] && echo 1 || echo 0 )"
    printf 'state=%s\n'         "$STATE_DIR"
}

# The valid repo pairs, one TSV line each, using the same parser a run uses —
# so a front-end's picker can't disagree with what will actually be synced.
_print_repo() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

cmd_repos() {
    load_config_file
    for_each_repo _print_repo
    return "$EACH_RC"
}

cmd_init() {
    local dir; dir=$(dirname "$CONFIG_FILE")
    mkdir -p "$dir"

    if [[ -e "$CONFIG_FILE" ]]; then
        info "exists, not touching: ${CONFIG_FILE}"
    else
        cat > "$CONFIG_FILE" <<'EOF'
# holonet-sync configuration (sourced by bash)

GITEA_URL="https://gitea.lan"          # base URL, no trailing slash
GITEA_USER="you"
GITEA_TOKEN_FILE="$HOME/.config/holonet-sync/gitea.token"
# Gitea token scopes: write:repository, read:user (+ write:organization to create org repos)

GITHUB_USER="you"
GITHUB_TOKEN_FILE="$HOME/.config/holonet-sync/github.token"
# GitHub classic PAT: repo, workflow
# (without 'workflow', any push that touches .github/workflows/ is rejected)
# Env vars GITEA_TOKEN / GITHUB_TOKEN override the files (e.g. k8s secrets).

# REPOS_FILE="$HOME/.config/holonet-sync/repos.list"
# STATE_DIR="$HOME/.local/state/holonet-sync"   # bare workspaces + sync base; persist it

DEFAULT_VISIBILITY="private"            # used when a repos.list line has no 3rd column
PROTECTED_BRANCHES="main master"        # never deleted by sync; restored if they vanish
PROPAGATE_REWRITES=0                    # 1 = carry a force-push on one side to the other
                                        #     (only when the other side is unchanged); 0 = alert
EXCLUDE_BRANCHES="wip/* local/*"        # globs, never synced in either direction
MAX_DELETIONS=5                         # per repo per run, above this the repo is skipped
AUTO_MERGE=1                            # 1 = merge clean divergences, 0 = alert only
AUTO_MERGE_PROTECTED=0                  # same, for PROTECTED_BRANCHES (default: alert only)
MERGE_AUTHOR_NAME="holonet-sync"
MERGE_AUTHOR_EMAIL="holonet-sync@localhost"

# Receives the alert text on stdin. Examples:
# ALERT_CMD='curl -fsS -H "Title: holonet-sync" -d @- https://ntfy.lan/holonet-sync'
# ALERT_CMD='logger -t holonet-sync'
ALERT_CMD=""

ALLOW_LFS=0                             # 1 = sync Git LFS repos anyway (pointers only)
EOF
        success "wrote ${CONFIG_FILE}"
    fi

    if [[ -e "${dir}/repos.list" ]]; then
        info "exists, not touching: ${dir}/repos.list"
    else
        cat > "${dir}/repos.list" <<'EOF'
# <gitea owner/name>        <github owner/name>        [private|public]
# you/homelab               you/homelab                private
# you/lan-locate            you/lan-locate             public
EOF
        success "wrote ${dir}/repos.list"
    fi
}

# =============================================================================
main() {
    local cmd="${1:-}"; [[ $# -gt 0 ]] && shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)          CONFIG_FILE="${2:?--config needs a path}"; shift 2 ;;
            --repo)            ONLY_REPO="${2:?--repo needs OWNER/NAME}"; shift 2 ;;
            --dry-run)         DRY_RUN=1; shift ;;
            --allow-deletions) ALLOW_DELETIONS=1; shift ;;
            --no-api)          NO_API=1; shift ;;
            -v|--verbose)      VERBOSE=1; shift ;;
            -h|--help)         usage; exit 0 ;;
            *)                 usage; error_exit "unknown flag: $1" ;;
        esac
    done

    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT

    case "$cmd" in
        init)         cmd_init ;;
        check)        cmd_check ;;
        run)          cmd_run ;;
        status)       cmd_status ;;
        reset)        cmd_reset ;;
        config)       cmd_config ;;
        repos)        cmd_repos ;;
        version)      echo "${SCRIPT_NAME} ${VERSION}" ;;
        ""|-h|--help) usage ;;
        *)            usage; error_exit "unknown command: ${cmd}" ;;
    esac
}

main "$@"
