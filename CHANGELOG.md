# Changelog

All notable changes to Draugr are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Draugr uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The public surface — the thing semver applies to — is the `dr-*` commands, their exit codes, the
`DRAUGR_*` configuration keys and the hook names. `lib/common.sh` is internal: it is documented for
people reading the source, not for people calling it.

## [Unreleased]

Nothing yet.

## [0.1.0] — 2026-08-15

First release that is ready to be used rather than read. Everything below was verified against
Docker Sandboxes `v0.37.1` on Windows 11 + WSL2, and 320 tests run in CI.

### The daily loop

- `dr-go` — preflight, create-or-start the mound, attach, launch the agent. The one command a
  session needs.
- `dr-sync`, `dr-log`, `dr-diff`, `dr-merge` — fetch what the agent committed onto
  `draugr/<branch>`, review it, accept it. Your `origin` is never touched.
- `dr-send`, `dr-cp` — push host commits into a running mound; pull uncommitted files back out.
- `dr-up`, `dr-shell`, `dr-stop`, `dr-rm`, `dr-ls`, `dr-status` — lifecycle, all idempotent.

### Configuration

- Four layers — built-in defaults, `~/.config/draugr/config`, `<repo>/.draugr.conf`,
  `<repo>/.draugr.local.conf` — then `DRAUGR_*` environment variables, then flags.
- `dr-config` prints the merged result with the origin of every value.
- Trust on first use: a project config is executed when sourced, so its hash is recorded in
  `~/.config/draugr/trusted` and an unseen one is refused until `dr-trust` accepts it.
- 27 keys, all documented in [docs/CONFIG.md](docs/CONFIG.md), with a test that fails if a key
  exists in code but not in the documentation.
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
- `dr-rm` refuses to destroy unfetched commits or unexported memory.
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
