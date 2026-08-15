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
Docker Sandboxes `v0.37.1` on Windows 11 + WSL2, and 215 tests run in CI.

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
- 25 keys, all documented in [docs/CONFIG.md](docs/CONFIG.md), with a test that fails if a key
  exists in code but not in the documentation.

### Safety

- `dr-scan` finds credential-shaped files the agent could read through the read-only mount.
  `DRAUGR_SCAN_FAIL=block` is the default, because `.gitignore` hides files from git, not from the
  filesystem.
- `DRAUGR_REQUIRE_CLEAN` refuses to start a session with uncommitted work the clone cannot contain.
- `dr-rm` refuses to destroy unfetched commits or unexported memory.
- `dr-kit` wraps `sbx kit` and detects drift between the kit and the mound built from it.
- `dr-policy` shows the network rules actually in force, including the ~190 machine-wide defaults
  that apply whether or not your kit mentions them.

### Data and context

- `DRAUGR_DATA` moves large or half-processed files beside git rather than through it, by `rsync`
  over the same `ssh://` transport. One direction at a time, always.
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
- Review in `create-data-only` mode is `dr-data status`, which reports *which* files differ rather
  than what changed inside them. There are no commits to diff.
- One repository per mound.

[Unreleased]: https://github.com/skunkiferous/draugr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/skunkiferous/draugr/releases/tag/v0.1.0
