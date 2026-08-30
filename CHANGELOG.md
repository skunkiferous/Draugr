# Changelog

All notable changes to Draugr are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Draugr uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The public surface — the thing semver applies to — is the `dr-*` commands, their exit codes, the
`DRAUGR_*` configuration keys and the hook names. `lib/common.sh` is internal: it is documented for
people reading the source, not for people calling it.

## [Unreleased]

### Added

### Removed

### Changed

### Fixed

## [0.2.0] — 2026-08-30

### Added

- **`DRAUGR_HOST_PORTS` and `dr-hostport`** — a service on your own machine that the agent is allowed
  to call, a local Ollama on the GPU being the case it was written for. The mirror image of
  `DRAUGR_PORTS`/`dr-ports`, and deliberately the same shape: declare it once in `.draugr.conf`, or
  reach for the command mid-session.

  The reason it exists as a feature rather than a line in the README telling you to run
  `dr-policy --allow 172.19.192.26:11434` is that the address in that line stops being true. WSL sits
  on a NAT'd network whose subnet is chosen per Windows boot and whose address within it comes from
  DHCP, and neither can be pinned — WSL 2.6.1 parses `networkingMode`, `dhcpTimeout` and
  `vmIdleTimeout` out of `.wslconfig` and contains no `natNetwork` or `natGateway` at all. So the
  rule is right until the next reboot and then fails **closed and silently**: measured, the
  connection is accepted by the sandbox's interception layer and dropped with no error to read, which
  is indistinguishable from the service being down.

  So only the port is ever named. `dr-up` re-resolves the address on every start — not only on the
  create, because the start that matters is the first one after a reboot — and removes the rules left
  behind for addresses this machine no longer has, which otherwise accumulate one per boot. Pruning
  is narrow on purpose: a rule is only ours if it is editable, scoped to this mound, and holds
  exactly one resource that is a bare IPv4 address on that port. A kit's rule, a rule naming a
  domain, and a rule bundling several hosts are all left alone, because the next thing that happens
  to a matched rule is `sbx policy rm`.

  Two things worth knowing independently of this feature, both measured against sbx 0.37.1:
  `sbx policy allow network` **accepts a CIDR and silently ignores it** — `172.19.192.0/20:11434` is
  stored as a rule, and then denied by both `sbx policy check` and real traffic. A wildcard last
  octet does work (`172.19.192.*:11434`), but only one label: `172.19.*` matches nothing. And
  `host.docker.internal` resolves inside a mound but does not reach the WSL host, so the Docker
  Desktop recipe for this does not transfer.

  `dr-hostport` also warns when the port is bound to loopback only, which is the mistake that sits
  next to this one: from inside the mound `127.0.0.1` is the mound, so the rule is perfect and the
  connection still fails.

- **The build-your-own-kit loop.** A new project's kit is the one thing you cannot write in advance,
  because you do not know what a build needs until it fails. Three additions make working it out an
  iteration inside one session rather than one recreate per host:

  - **`dr-policy --denied`** — the hosts this mound was refused, from `sbx policy log`. That is the
    proxy's own record, so it is right whatever the toolchain, and build output is not: measured
    against a single blocked host, `curl` printed nothing at all, `git` named it exactly, and `pip`
    reported `Could not find a version that satisfies the requirement`. One silent, one perfect, one
    actively misleading — the proxy logged all three identically.
  - **`dr-kit adopt`** — writes the hosts that were actually opened into the project's kit, read back
    from the daemon rather than remembered by hand. Skips what the kit already declares, so running
    it twice is a no-op, and edits only `caps.network.allow`. A kit whose shape it does not recognise
    is reported and left untouched rather than guessed at.
  - **`dr-skills install`** — puts Draugr's own skills into the shared store. `sbx skills import`
    cannot: it scans five fixed host directories and takes no path. Its own verb rather than
    something `dr-setup` does quietly, because the store is shared by every mound and its contents
    are instructions.

  The loop turns on a measured fact: **`dr-policy --allow` takes effect on the running mound.** A
  host that answered `Blocked by network policy` answered with its own 404 immediately afterwards,
  same mound, no restart. So the kit is written once at the end rather than being the mechanism
  during. What stays manual is the grant itself — you see each host before it opens, which is the
  review gate and is deliberately not automated.

- **A `draugr-kit` skill**, shipped in `share/skills/` and installed with `dr-skills install`. It
  teaches the agent its half of that loop: run the build, do **not** guess which host was refused,
  stop and ask for `dr-policy --denied`. It also draws the line between the two writers of
  `spec.yaml` — `caps.network.allow` belongs to `dr-kit adopt` on the host, `commands.install`
  belongs to the agent — because both editing it would mean a conflicting change in the clone. One
  `SKILL.md` serves both agents: measured, Claude Code and Codex each list a store skill by name.

- **`dr-up` prints what sandboxd recorded when a create fails.** sbx reports it as
  `500 Internal Server Error: failed to run sandbox container` and stops, while its own daemon log
  holds the failing command, its exit code and its captured output. Reading an undocumented file is a
  coupling, so every step of it is best-effort: no log, no `jq`, or a shape that has moved, and the
  advice is exactly what it was before. A byte offset taken before the attempt, rather than a
  timestamp, keeps last week's failure out of this one's report.

- **The install-time rule, which is what makes that failure worth explaining.** `commands.install`
  runs **before the repository is in the workspace** — the working directory is empty, and the repo
  is read-only at `/run/sandbox/source`. Measured against sbx 0.37.1 in both clone and mount mode. So
  `uv pip install -r requirements.txt` in a kit fails with `File not found` however right it looks,
  and until now said so only as a 500. `dr-up` now names the rule when the failure mentions
  `commands.install`; `share/kit.example/spec.yaml` shows the working form; and the `draugr-kit`
  skill states it outright, along with the fact that an agent **cannot test an install command** —
  they run only at create, which is the one thing it cannot do. The kit template previously offered
  `npm ci` as the example, which is exactly the shape that cannot work.

- **Codex is a supported agent.** `DRAUGR_AGENT=codex` works with the commands that already exist —
  including Ctrl+Z, verified end to end against a real mound. Everything except memory was already
  agent-agnostic: the attach path quotes `$DRAUGR_AGENT`, and the clone, the mirrored paths,
  `dr-sync`, `dr-send` and `dr-data` never knew which agent was in there.
- **`lib/agents/<agent>.sh`** — one file per agent for the parts that genuinely differ, chosen by
  `dr_agent_load` at the end of the config cascade. `lib/agents/default.sh` is both the interface and
  what an unmeasured agent gets, and a test fails if any module omits a function: sourcing a partial
  one would leave the previous agent's answers standing, which is how Claude's memory path ends up in
  a Codex mound with nothing on screen to say so.
- The other eight agents now get an honest refusal from `dr-mem` instead of a warning followed by a
  copy into a directory that agent will never read. Everything else about them works.
- Documented the **Codex model trap**, which fails every prompt in a way that reads as a broken
  login: `sbx` sets `model_provider` in the mound's `config.toml` but no `model`, so Codex falls back
  to a built-in default that a ChatGPT-plan account is often not entitled to, and the API answers
  `The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT account`. `sbx secret ls`
  reads `openai (oauth configured)` throughout, and `sbx` never reads `~/.codex/auth.json` from
  either home, so there is nothing to copy and nothing to sign into. The fix is
  `DRAUGR_AGENT_ARGS="--model gpt-5.6-terra"`, applied at attach rather than at creation.
  `~/.codex/models_cache.json` on a host Codex lists what the account actually has. Deliberately
  *not* a `dr-doctor` check: Draugr cannot see the entitlements from outside the mound, and the only
  check it could write would fire for everyone who never hits this.
- `dr-doctor` reports a missing agent credential. `sbx` warns about one when it creates a sandbox and
  never again, which is the wrong moment — by the time it matters you are looking at a logged-out
  agent. The token stays on the host either way: sbx's proxy authenticates per request, so signing in
  after a mound was built needs no rebuild. Measured — a claude mound reports
  `SBX_CRED_ANTHROPIC_MODE=none` while `sbx secret ls` shows the OAuth token configured.

### Changed

- **The memory store is now keyed by project *and agent*:** `<project-key>/<agent>/`. Two agents'
  memories of one project are different things in different shapes — Claude Code's is a directory of
  markdown, Codex's is markdown plus SQLite — and they must not overwrite each other. A store written
  before this is moved under `claude/` by the first `dr-mem` or `dr-status` after upgrading, and says
  so. Moved under `claude/` specifically, never under whatever agent is configured now.
- **`dr-init` no longer writes `requires: agent:` into the kit it generates.** Measured: the field is
  optional, an agent-less kit composes with any agent, and a pinned one fails at creation with
  `400 Bad Request: … requires base agent "claude" but was composed with "codex"`. Freezing today's
  choice into a committed file would make trying another agent an edit rather than a setting. Almost
  nothing in a kit is agent-specific anyway — network rules, install commands and ports belong to the
  project.
- `DRAUGR_KIT` entries resolve `<entry>.<agent>` before `<entry>`, so `.draugr/kit.codex` beats
  `.draugr/kit` and a library kit `lua.codex` beats `lua`. The escape hatch for kits that genuinely
  differ, without duplicating the ninety per cent that does not. A suffix rather than a subdirectory,
  because `.draugr/kit/codex/` would be indistinguishable from a kit that happens to contain a
  directory of that name.
- `dr-skills` no longer claims the store mounts at `~/.claude/skills`. There is **one** store — `sbx`
  collapses five per-agent host directories into a single namespace, per `sbx skills import --help` —
  and it varies only where that store appears: `~/.claude/skills` for claude, `~/.agents/skills` for
  codex. Both are read by their agent, measured on each side by asking the agent itself to list its
  skills with shell use forbidden. A marker sitting only in the store was named by Claude Code in a
  claude mound and by Codex in a codex one, and a second marker added *after* the codex mound was
  built appeared with no restart. So a skill in the store is in reach of every mound on the machine,
  whichever agent it runs — which is what makes reviewing it worth a command of its own.

### Fixed

- **`dr-skills` no longer skips hidden directories.** `list`, `diff` and `accept` globbed `*/`, which
  does not match a name beginning with a dot — so the review commands had a blind spot exactly where
  someone would want one. Measured against Claude Code 2.1.221: a store entry named `.hidden-probe`
  appears in Claude's own list of available skills like any visible one, while anything a level
  deeper is ignored. Depth is the limit, not the dot. Not hypothetical either — Codex writes
  `.system/` into its skills directory the first time it runs.
- **`dr-rm` and `dr-up --recreate` refuse while a host is open and not in the kit.** A rule added by
  `dr-policy --allow` is scoped to the sandbox and does not outlive it — measured, after `sbx rm`
  looking one up by id gives `policy or rule not found`. Recreating is exactly what you do once the
  build finally works, so without this the list that made it work would be destroyed in the act of
  making it permanent. Same shape as the existing refusal over unfetched commits, and cleared the
  same way: write it down, with `dr-kit adopt`.
- `dr-up`, `dr-kit validate` and `dr-doctor` catch a kit pinned to a different agent **before**
  creation, naming both agents. `sbx kit validate` accepts such a kit — the mismatch exists only at
  compose time — so Draugr reading the field itself is the only thing that could catch it. Same class
  as the kit-slug failure fixed in 0.1.0: sbx's own words, two steps from the cause.
- That check runs **before** `dr-up --recreate` removes anything. Written the obvious way first, it
  refused at the point of creation — which is *after* the removal, so a working mound was destroyed
  over a problem that had been visible on disk the whole time. Found by running it, not by reading
  it.
- The **first `dr-up` on a new project no longer reports "auto memory import failed"**. With
  `DRAUGR_MEM_SYNC=auto` the import runs on every `dr-up`, and a project that has never had a session
  has nothing in the store — which is the ordinary state of affairs, not a failure. `--if-empty` now
  treats an empty store as the no-op it is. Asked for explicitly, `dr-mem import` still says there is
  nothing there.

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
