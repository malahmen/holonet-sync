# holonet-sync

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
| Branches diverged, merge is clean | Auto-merges and pushes the merge to both sides |
| Branches diverged with conflicts | Leaves both alone and alerts |
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
| `EXCLUDE_BRANCHES` | Globs never synced in either direction |
| `MAX_DELETIONS` | Deletion cap per repo per run |
| `AUTO_MERGE` | `1` merges clean divergences, `0` only alerts |
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

`~/.local/state/holonet-sync/` holds one bare workspace per repo (the mirrored
refs plus the `refs/sync/base/*` bookkeeping), the per-repo status lines, and the
alert dedup stamps. **Persist it.** Losing it loses no data, but the next run
re-seeds from scratch — and a re-seeding run can only create and merge, never
delete.

## Gitea push mirrors

If a Gitea repo has a **push mirror** pointing at its GitHub twin, remove it.
Mirrors force-push on their own schedule and will fight this tool over every ref.
`check` treats an existing push mirror as a hard failure for that repo.

## Testing

`tests/test-local.sh` runs the whole engine against `file://` bare repos — no
network, no tokens — covering 19 scenarios including divergence, conflicts,
deletions, restores, both guards, `reset`, and a stale-lease rejection:

```sh
tests/test-local.sh
```

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
