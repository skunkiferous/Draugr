# Changelog

All notable changes to Draugr are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Draugr uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The public surface — the thing semver applies to — is the `dr-*` commands, their exit codes, the
`DRAUGR_*` configuration keys and the hook names. `lib/common.sh` is internal: it is documented for
people reading the source, not for people calling it.

## [Unreleased]

### Added

### Changed

### Removed

### Fixed

## [0.1.0] — 2026-08-19

### Fixed

- `dr-up` notices when a **creation-time setting** has changed since the mound was built — the mounts,
  the ports, the memory cap, the image, the agent. Those are frozen into the sandbox spec, so editing
  one and re-running `dr-up` was a silent no-op: you add a read-only mount for a sibling project,
  start a session, and the directory simply is not there with nothing on screen to say why. It now
  names the settings that differ and points at `dr-up --recreate`, or `dr-ports` when only ports
  changed. Recorded in `.draugr/create.applied`, gitignored beside `kit.applied`.
- A mound built before that record existed is not reported as drift. Unknown is not a change, and
  crying wolf on every `dr-up` is how a warning stops being read.
- `dr-status` and `dr-send` count `DRAUGR_DATA` files apart from uncommitted work, the way `dr-go`
  already did. `dr-status` was not merely noisy but **wrong**: "16 uncommitted change(s) — the clone
  will not have them" was false of every one of those files, which arrive by rsync before the agent
  starts. It now reads `clean apart from data` with the data on its own row, named with its
  transport. `dr-send` no longer lists them under a warning about work it could not send, since they
  were never travelling that way.
- `dr-sync` and `dr-status` tell **"the mound has never seen these"** apart from **"it has them and
  the agent has not merged them"**. `dr-send` leaves your commits at `refs/remotes/host/<branch>`
  inside the mound and deliberately does not move the agent's branch, so `draugr/<branch>` stays
  behind afterwards — and both commands answered "send them with `dr-send`" for ever. Sending again
  was a no-op, so the messages had no way out of the loop. They now say `dr-send --merge` once the
  commits are delivered. Told apart by mirroring the mound's own `host/*` refs into
  `refs/draugr/sent/*` on the existing fetch: no extra round trip, and outside `refs/remotes/` so it
  is never mistaken for a branch of the agent's to review.
- `dr-go` warns when a dirty data file is exempted from the clean-tree check while
  `DRAUGR_DATA_PUSH` is not `auto`. The exemption assumes something will carry the file; with push
  off nothing does, and the agent silently works from whatever the clone was built with — the exact
  staleness `DRAUGR_REQUIRE_CLEAN` exists to prevent, reached through the setting meant to make it
  safe.

### Documented

- **Where an extra mount lands**, which was nowhere in the docs and is the whole question when one
  project depends on the one next door. It appears at the mirrored path, so `C:\Code\TabuLua` is
  `/c/Code/TabuLua` and a sibling stays a sibling — `../TabuLua` from the clone resolves unchanged.
  Measured, along with `:ro` actually refusing writes and host edits being visible live.
- The mount is your **live working tree**, not a clone: uncommitted changes are readable inside the
  mound immediately. That is the difference from packaging a dependency as a kit, which freezes it at
  whatever you last published. Also that `dr-scan` does **not** look inside extra mounts.

First release that is ready to be used rather than read. Everything below was verified against
Docker Sandboxes `v0.37.1` on Windows 11 + WSL2, and 390 tests run in CI.

### The daily loop

- `dr-go` — preflight, create-or-start the mound, attach, launch the agent. The one command a
  session needs.
- `dr-sync`, `dr-log`, `dr-diff`, `dr-merge` — fetch what the agent committed onto
  `draugr/<branch>`, review it, accept it. Your `origin` is never touched.
- `dr-send`, `dr-cp` — push host commits into a running mound; pull uncommitted files back out.
- `dr-up`, `dr-shell`, `dr-stop`, `dr-rm`, `dr-ls`, `dr-status` — lifecycle, all idempotent.
- `dr-stop --all` stops every running sandbox on the machine, listing them and asking first. It
  deliberately reaches past the ones Draugr named, because a running mound holds a Hyper-V microVM
  open whoever created it. Needs no repository.

### Attaching

- **Ctrl+Z works.** It suspends the agent and hands you a shell inside the mound; `fg` returns to the
  session as you left it. One window, no second connection, no restart.
- `dr-go` and `dr-shell` attach over **ssh** rather than `sbx run` / `sbx exec`. Those reach the
  sandbox through `sbx.exe`, a *Windows* binary WSL runs over interop, so Ctrl+Z suspends the relay
  instead of the agent: the keystroke never arrives, the daemon stops hearing from its client, and
  the session dies with `inspect exec: context deadline exceeded`. Job control was the reason for
  running in WSL at all, and the original `sbx run` attach threw it away.
- The agent runs as a job of an interactive bash, started from `PROMPT_COMMAND`. Starting it from
  the rcfile instead hangs — bash has not enabled job control while it is still running its startup
  files. A normal exit is unchanged: the session ends and `dr-go` returns the agent's status, which
  works because a suspended job leaves `$?` at 148 and an exited one does not.
- `DRAUGR_ATTACH=sbx` keeps the old transport, without Ctrl+Z. `dr-shell --root` uses `sudo -s`
  under ssh, since ssh authenticates as the agent and the agent has passwordless sudo.

### Configuration

- Four layers — built-in defaults, `~/.config/draugr/config`, `<repo>/.draugr.conf`,
  `<repo>/.draugr.local.conf` — then `DRAUGR_*` environment variables, then flags.
- `dr-config` prints the merged result with the origin of every value.
- Trust on first use: a project config is executed when sourced, so its hash is recorded in
  `~/.config/draugr/trusted` and an unseen one is refused until `dr-trust` accepts it.
- A refused config is reported again, in red, at the **bottom** of `dr-config`. It was already
  warned about at the top, which is the wrong end of a thirty-row table to put the one line
  explaining why the table is wrong — and a skipped layer is otherwise indistinguishable from one
  that set nothing. Exit status stays `0`: nothing failed. `--files` marks it too.
- 29 keys, all documented in [docs/CONFIG.md](docs/CONFIG.md), with a test that fails if a key
  exists in code but not in the documentation.
- `DRAUGR_STOP_ON_EXIT` stops the mound when you leave the agent — last of all, after the sync, the
  memory export and the data pull, each of which needs it alive. Off by default: an idle mound holds
  ~1.4 GB, but a cold start costs 4.2 s against 0.36 s to attach to a live one, and stopping kills
  anything the kit serves through `publishedPorts` or `startup` commands.
- Every command's `--help` **is** its header comment, printed by `dr_help`, so the two cannot drift.
  It replaced a hand-counted `sed -n '2,Np' "$0"` in each script, where `N` had gone stale in 17 of
  27 commands — each ending its help with a stray `set -euo pipefail`, while `dr-status` had drifted
  the other way and truncated its own help mid-sentence. A test fails if any help contains a line of
  code.

### Safety

- `dr-scan` finds credential-shaped files the agent could read through the read-only mount.
  `DRAUGR_SCAN_FAIL=block` is the default, because `.gitignore` hides files from git, not from the
  filesystem. It also reports how many stashes exist, which it cannot see into: the read-only mount
  includes `.git`, so stashing a file removes it from the scan without removing it from the agent's
  reach.
- Hooks are trust-checked like configs. `.draugr/hooks/*` are scripts that run on the host, as you,
  so an agent-authored one arriving through a merge would otherwise execute at the next `dr-up`.
  `dr-trust` with no arguments offers the hooks alongside the configs.
- `dr-data pull` is reviewed rather than merely reported. It classifies what is arriving, warns about
  anything shaped like something you would run, and asks before transferring it. Paths are validated
  by Draugr itself — absolute, `..` or control characters stop the pull — rather than left to rsync's
  own sanitising.
- The `*.sbx` ssh block sends `LANG LC_*` instead of `*`. The wildcard leaked nothing against
  `sbx 0.37.1`, which honours no `AcceptEnv` at all, but it stood ready to forward every WSL variable
  the day that changes.
- `DRAUGR_REQUIRE_CLEAN` refuses to start a session with uncommitted work the clone cannot contain.
- `dr-rm` refuses to destroy unfetched commits or unexported memory, checking **every** branch in the
  mound. It previously asked about `DRAUGR_BRANCH` alone, so an agent that committed to a branch of
  its own — which agents habitually do — was reported as "nothing to lose".
- `dr-sync` and `dr-status` name any mound branch holding commits you have not merged. The fetch
  always covered every branch (`+refs/heads/*`); only the report was narrow, which made a session's
  work appear to vanish while it sat fetched on the host's own disk. Review one with
  `DRAUGR_BRANCH=<name> dr-diff`.
- `dr-sync --no-fetch` no longer requires the mound to exist, so "what did I keep?" is answerable
  after `dr-rm`.
- `dr-kit` wraps `sbx kit` and detects drift between the kits and the mound built from them.
- The kit `name:` `dr-init` writes is a slug of the project name, because `sbx` requires lowercase
  alphanumeric with hyphens. A repository called `TabuLua` previously produced a kit that failed at
  `dr-up` with an sbx error two steps from the cause; `displayName` keeps the original spelling.
  `dr-up` now names `dr-kit validate` when creation fails and kits are in play.
- `DRAUGR_KIT` is a **list**, because `sbx` merges kits rather than choosing between them — so a
  shared kit adds to the project's instead of replacing it. `dr-kit save <name>` and `dr-kit list`
  keep a library of named kits at `DRAUGR_KIT_STORE` (`~/.config/draugr/kits`), which any repo can
  name in one word. `dr-setup` creates it, alongside the ssh block — those are the only two
  machine-level things Draugr sets up. Drift covers the whole list, so a library kit another project
  edited shows up here.
- `dr-policy` shows the network rules actually in force, including the ~190 machine-wide defaults
  that apply whether or not your kit mentions them.

### Data and context

- `DRAUGR_DATA` moves large or half-processed files beside git rather than through it, by `rsync`
  over the same `ssh://` transport. One direction at a time, always.
- The `DRAUGR_REQUIRE_CLEAN` refusal names **only the files that blocked**, and says how many were
  exempt. It printed `git status --short` in full, so a repo with fifteen churning `.tsv` files and
  one stray script showed sixteen lines with the only real one at the bottom — and read as
  "`DRAUGR_DATA` is being ignored" when the exemption was working exactly as intended.
- `dr-data diff` shows what a pull would change as a real unified diff — the review step the data
  channel otherwise lacks, since there is no commit to read. Text files up to `DRAUGR_DATA_DIFF_MAX`
  are shown in full; binaries and anything larger are reported by name and size.
- `dr-mem` carries agent memory across `dr-rm`, translating the project key — which differs on
  every side of the boundary, and produces a directory the agent silently never reads if you copy
  it across untranslated.
- `dr-skills` treats the shared skills store as a reviewable artifact. It is the one path by which a
  sandbox can leave bytes on the host.

### Directories that are not repositories

- `DRAUGR_ON_MISSING_REPO=fail|create-add-all|create-data-only`. Clone mode requires a git
  repository, so the default is to refuse rather than fall back to something weaker. `create-data-only`
  builds a repo that tracks nothing, for folders of documents or data.

### Known limitations

- WSL on Windows only. The whole path story is WSL-specific.
- `dr-code` opens VS Code against the mound but does not manage extensions inside it.
- Review in `create-data-only` mode is `dr-data status` and `dr-data diff` rather than `dr-diff` and
  `dr-merge`; there are no commits, so there is no history to compare against and no partial accept.
- `DRAUGR_DATA_CHMOD` cannot keep a pulled file non-executable. DrvFs ignores `chmod`, so anything
  landing on a Windows drive is mode 0777 — which is why `dr-data` flags runnable-looking files by
  name instead.
- One repository per mound.

[Unreleased]: https://github.com/skunkiferous/draugr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/skunkiferous/draugr/releases/tag/v0.1.0
