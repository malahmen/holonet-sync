# holonet-sync

[![ci](https://github.com/malahmen/holonet-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/malahmen/holonet-sync/actions/workflows/ci.yml)

**`holonet-sync.sh` — keep Gitea and GitHub repositories converged, both ways.**

> "Two transmitters, one signal."

Not a mirror: **neither side is the master copy**. For every repo pair in your
list, holonet-sync compares three things per branch — the GitHub tip, the Gitea
tip, and the **last-synced base** (what both sides agreed on at the end of the
previous run) — and from that works out what actually happened, instead of
assuming one side is right.

It's a gum-free, flag-driven CLI (the engine); an interactive front-end
([scomp-link](https://github.com/malahmen/scomp-link)) drives it, the same split
as [holo-convert](https://github.com/malahmen/holo-convert) and
[navicomputer](https://github.com/malahmen/navicomputer). No prompts, ever — it
is built to live in a cron job or a systemd timer.

## What it does

| Situation | What it does |
| --- | --- |
| One side is behind | Fast-forwards it |
| Branch is new on one side | Creates it on the other |
| Branch deleted on one side, untouched on the other | Deletes it on the surviving side |
| Branch deleted on one side but with new commits on the other | Restores it and alerts — deletion never wins by default |
| Protected branch (`main`, `master`) vanished | Restores it and alerts |
| Branches diverged, merge is clean | Auto-merges and pushes the merge to both sides (on a protected branch only with `AUTO_MERGE_PROTECTED=1`; otherwise alerts) |
| Branches diverged with conflicts | Leaves both alone and alerts |
| Branch rewritten (force-pushed) on one side, unchanged on the other | Alerts and leaves both alone; with `PROPAGATE_REWRITES=1`, carries the rewrite across under a lease |
| Branch rewritten and the other side also moved | Leaves both alone and alerts — a rewrite is never merged back |
| Tag missing on one side | Copies it |
| Tag differs between sides | Leaves both alone and alerts |

Tags are write-once: a tag deletion is never propagated (the tag is recreated
from the other side).

## Safety

- **Never force-overwrites.** Every push and delete carries
  `--force-with-lease=<ref>:<expected>`. If the remote moved between the fetch
  and the push, the push fails safely instead of clobbering it, and the next run
  picks the change up.
- **Loop-safe.** A converged pair produces zero pushes, so its own pushes can't
  start a cascade — the next run finds both sides equal.
- **Rewrites are detected, never merged.** A side that no longer contains the
  last-synced base was force-pushed (amend, rebase, reset, a history scrub such
  as mind-trick's). Merging it with the other side would bring the dropped
  commits back everywhere, so holonet-sync alerts instead, or, with
  `PROPAGATE_REWRITES=1`, pushes the rewrite to the unchanged side under a lease
  on the base.
- **Empty-side guard.** If one side suddenly has no branches while sync state
  exists, the repo is skipped and alerted: a wiped or recreated repo looks
  exactly like "every branch was deleted at once". Clear with `reset`, or
  override with `--allow-deletions`.
- **Deletion cap.** More than `MAX_DELETIONS` (default 5) branch deletions
  planned in one run skips that repo entirely.
- **Git LFS repos are skipped.** Pushes carry only the pointer files; the LFS
  objects stay on each server's LFS store, so the twin would end up with
  dangling pointers. A repo whose `.gitattributes` uses `filter=lfs` on any
  branch is skipped and alerted unless `ALLOW_LFS=1`.
- **A failed fetch aborts that repo.** An unreachable side is never mistaken for
  an empty one.
- **Per-ref failure isolation.** A ref whose push fails skips its own remaining
  steps (including its base update); the rest of the run continues.
- **Nothing is auto-installed** and privileges are never elevated. `check` tells
  you what's missing; you install it.
- **`run` takes an `flock`**, so an overlapping cron tick exits immediately
  instead of racing the run already in flight.

## Requirements

- **bash ≥ 4** (associative arrays, `mapfile`)
- **git ≥ 2.38** — `merge-tree --write-tree` is how a clean divergence is merged
  entirely inside the bare workspace, with no working tree. `check` verifies it.
- **curl**, **jq**, **flock**, **base64**, **sha1sum**
- **macOS:** the system bash is 3.2 and there is no `flock`; install both
  (`brew install bash flock`). `sha1sum` ships with recent macOS, or comes from
  `brew install coreutils`.
- **https** for `GITEA_URL`: tokens travel in request headers, so a plain
  `http://` URL sends them unencrypted. `check` warns about it.

## Install

```sh
git clone git@github.com:malahmen/holonet-sync.git
cd holonet-sync
chmod +x holonet-sync.sh
./holonet-sync.sh --help
```

## Usage

```sh
# Write the example config + repo list, then fill them in
./holonet-sync.sh init

# Validate tools, git version, tokens, repo access and push mirrors
./holonet-sync.sh check

# See exactly what a run would do, without touching a remote
./holonet-sync.sh run --dry-run -v

# Reconcile everything, or a single pair
./holonet-sync.sh run
./holonet-sync.sh run --repo me/homelab

# Last recorded result per repo (no network)
./holonet-sync.sh status

# Forget what the two sides last agreed on; the next run re-seeds
./holonet-sync.sh reset --repo me/homelab
```

Run it on a timer once `check` passes:

```cron
*/15 * * * * /path/to/holonet-sync.sh run >> /var/log/holonet-sync.log 2>&1
```

## Commands

| Command | What it does |
| --- | --- |
| `init` | Write an example config and repo list (never overwrites) |
| `check` | Validate tools, git version, tokens, repo access, Gitea push mirrors |
| `run` | Reconcile every repo in the list (or one, with `--repo`) |
| `status` | Last recorded result per repo (no network) |
| `reset` | Forget sync state for `--repo` (next run re-seeds; deletes nothing) |
| `config` | Print the resolved config/repos/state paths as `key=value` |
| `repos` | Print the valid repo pairs from the list as TSV |
| `version` | Print version |

## Flags

| Flag | Meaning |
| --- | --- |
| `--config PATH` | Config file (default `~/.config/holonet-sync/holonet-sync.conf`) |
| `--repo OWNER/NAME` | Limit to one Gitea repo from the list |
| `--dry-run` | Plan and report, push nothing |
| `--allow-deletions` | Bypass `MAX_DELETIONS` and the empty-side guard for this run |
| `--no-api` | Skip API lookups and twin creation (both repos must already exist) |
| `-v`, `--verbose` | Debug logging |
| `-h`, `--help` | Show help |

## Configuration

`~/.config/holonet-sync/holonet-sync.conf` is sourced by bash; `init` writes a
commented example. `$HOLONET_SYNC_CONFIG` or `--config` points elsewhere.

| Setting | Meaning |
| --- | --- |
| `GITEA_URL`, `GITEA_USER` | Gitea base URL (no trailing slash) and account |
| `GITHUB_USER` | GitHub account |
| `GITEA_TOKEN_FILE`, `GITHUB_TOKEN_FILE` | Files holding the tokens; `GITEA_TOKEN` / `GITHUB_TOKEN` in the environment override them (k8s secrets, CI) |
| `REPOS_FILE` | Repo list (default: `repos.list` beside the config) |
| `DEFAULT_VISIBILITY` | Used when a repo list line has no third column |
| `PROTECTED_BRANCHES` | Globs never deleted by sync, restored if they vanish |
| `PROPAGATE_REWRITES` | `1` carries a force-push on one side to the other when the other side is unchanged since the last sync; `0` (default) only alerts |
| `EXCLUDE_BRANCHES` | Globs never synced in either direction |
| `MAX_DELETIONS` | Deletion cap per repo per run |
| `AUTO_MERGE` | `1` merges clean divergences, `0` only alerts |
| `AUTO_MERGE_PROTECTED` | Same, for `PROTECTED_BRANCHES`. Default `0`: a clean merge is not a reviewed one, so divergence on `main`/`master` alerts |
| `MERGE_AUTHOR_NAME`, `MERGE_AUTHOR_EMAIL` | Identity on auto-merge commits |
| `ALERT_CMD` | Command receiving the alert text on stdin |
| `ALLOW_LFS` | `1` syncs Git LFS repos anyway (refs and pointer files only); `0` (default) skips them with an alert |

`~/.config/holonet-sync/repos.list` — one pair per line:

```
# <gitea owner/name>   <github owner/name>   [private|public]
me/homelab             me/homelab            private
me/lan-locate          me/lan-locate         public
```

A pair whose twin doesn't exist yet is created on the other side (skip that with
`--no-api`).

### Alerts

`ALERT_CMD` receives the alert text on **stdin**, with the tokens stripped from
its environment:

```sh
ALERT_CMD='logger -t holonet-sync'
ALERT_CMD='curl -fsS -H "Title: holonet-sync" -d @- https://ntfy.example/holonet-sync'
```

Alerts are **deduplicated** by a hash of the situation, so an unresolved conflict
alerts once rather than on every tick; the stamps age out after 30 days.

## Tokens

- **Gitea:** `write:repository`, `read:user` (plus `write:organization` to create
  org repos).
- **GitHub:** a classic PAT with `repo` **and `workflow`** — without `workflow`,
  any push touching `.github/workflows/` is rejected, and `check` warns about it.
  A fine-grained token needs Contents, Workflows and Administration.

Credentials reach git through `GIT_CONFIG_*` environment variables and curl
through header files, so they never appear in `ps` output or in any repo's
`.git/config`.

## State

`~/.local/state/holonet-sync/` holds one bare workspace per repo, named
`repos/<owner>+<name>.git` (the mirrored refs plus the `refs/sync/base/*`
bookkeeping; workspaces from the older `<owner>__<name>.git` naming are moved
over automatically), the per-repo status lines, and the
alert dedup stamps. **Persist it.** Losing it loses no data, but the next run
re-seeds from scratch — and a re-seeding run can only create and merge, never
delete.

## Gitea push mirrors

If a Gitea repo has a **push mirror** pointing at its GitHub twin, remove it.
Mirrors force-push on their own schedule and will fight this tool over every ref.
`check` treats an existing push mirror as a hard failure for that repo.

## When an API call fails, who gets blamed

A failed call to Gitea or GitHub is reported by **what actually went wrong**,
not by assuming the credential did:

| What came back | What it is reported as |
| --- | --- |
| `401` / `403` | the credential was refused, quoting the API's own message |
| a body that is not JSON | a transport problem — "check `GITEA_URL` / `GITHUB_API`", quoting what the server said |
| nothing at all | no answer from the API, with `curl`'s reason |
| JSON with an error | the API declined it, in the API's own words |

This exists because of one incident. Gitea had moved to `https` while a config
still said `http`, so the server answered `400` with *"Client sent an HTTP
request to an HTTPS server."* The old code looked for a JSON `.message`, found
none, and reported **"gitea token rejected (HTTP 400)"** — sending the operator
to audit a token that was perfectly good. A transport problem must not read as
an authentication problem.

## Testing

Everything runs against `file://` bare repos: no network, no tokens.

```sh
tests/run-all.sh            # every tests/test-*.sh; non-zero exit if any fails
tests/test-local.sh         # the 19-scenario end-to-end run, each step asserted
```

**75 checks across 8 files:**

| File | Checks | What it covers |
| --- | ---: | --- |
| `test-local.sh` | 27 | the 19-scenario end-to-end run: fast-forwards, new and excluded branches, deletions, restores, clean and conflicting divergence, alert dedup, tags, dry-run, both guards, `reset`, a stale-lease rejection |
| `test-rewrites.sh` | 11 | a branch force-pushed on one side is never merged or fast-forwarded **back** to the commits it dropped |
| `test-api-diagnosis.sh` | 8 | the table above — including that a non-JSON `400` says nothing about the token |
| `test-workspace-key.sh` | 8 | `a__b/c` and `a/b__c` get separate workspaces, and state under the old key is migrated — unless two listed repos share it |
| `test-merge-failure.sh` | 7 | a merge commit that cannot be written leaves **both** sides untouched, rather than turning an empty sha into a branch deletion |
| `test-alerts.sh` | 6 | an alert raised while *planning* is not sent for a repo the guard then skips, and is sent once the run goes ahead |
| `test-lfs.sh` | 4 | a repo using LFS on any branch is skipped unless `ALLOW_LFS=1` — a refs-only sync would leave the twin with dangling pointers |
| `test-protected-merge.sh` | 4 | a clean divergence on a protected branch alerts, and merges only with `AUTO_MERGE_PROTECTED=1` |

Every scenario is followed by the checks it must pass, and the script exits
non-zero on the first run that breaks one.
`HOLONET_SYNC=/path/to/holonet-sync.sh` tests another copy of the engine.

### CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs `shellcheck` and
the whole suite on every push to `main`, every pull request, and on demand. It
needs **no tokens and no network** — which is the whole reason the suite is
built on `file://` remotes: a sync tool whose tests needed two live forges
could not be checked anywhere, least of all on a runner.

## Notes

- Status and logs go to **stderr**; `config`, `repos` and `status` print their
  data on **stdout**, so the engine composes in scripts.
- Unattended runs (no TTY) get plain UTC-timestamped log lines; a terminal gets
  colour instead.
- Auto-merge pushes the merge commit to **both** sides. If only one push lands,
  the base isn't updated and the next run sees a plain fast-forward.
- `reset` never touches either remote; it only forgets what they last agreed on.

## License

Released under the [Unlicense](LICENSE).
