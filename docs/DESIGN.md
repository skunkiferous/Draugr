# Design notes

Why Draugr is shaped the way it is, including the paths that were tried and abandoned. Kept because
the rejected ones are the questions most likely to be asked again — usually by someone who has just
had the same good idea.

## Why this exists at all

Running an agent with `--dangerously-skip-permissions` on your real machine is fast and reckless.
Approving every tool call is safe and miserable. Draugr takes the third option: make the blast radius
small enough that "let it run" is the *responsible* choice.

`sbx` already provides the isolation. What it does not provide is a workflow — out of the box you
are hand-building git remotes, remembering that the git daemon is unreachable from WSL, discovering
that agent memory lives under a path-derived key that differs between host and sandbox, and re-typing
five commands per session.

### Prior art

Surveyed August 2026, before any code was written. Wrappers around `sbx` exist —
[sbxgo](https://github.com/HenrikPoulsen/sbxgo), [sbx-toolkit](https://github.com/maxkrivich/sbx-toolkit),
[streamingfast/sbox](https://github.com/streamingfast/sbox),
[code-sandbox-console](https://github.com/ainova-systems/code-sandbox-console), and thinner ones in
[awesome-docker-sbx](https://github.com/ajeetraina/awesome-docker-sbx).

They overlap Draugr on the *config-file* idea and nowhere else. None implements the sandbox→host git
loop, agent memory transfer, or data sync, and **none mentions WSL**. That last gap is the decisive
one: `sbx.exe` being absent from WSL's `PATH`, the three-way path translation, and the git daemon
binding Windows loopback where WSL2's NAT cannot reach it are the problems that made this worth
building.

---

## Decisions, and what they cost

### Kits own the inside of the mound; Draugr owns the boundary

The largest decision, and it removed four planned config keys.

[`sbx kit`](https://docs.docker.com/ai/sandboxes/customize/kits/) is a first-party declarative
artifact that already declares network allow/deny lists, install commands that run once at creation,
startup commands, published ports, seeded files, environment variables, appended agent instructions,
and credentials brokered through a host-side proxy so the secret never enters the microVM.

That is most of what a network-policy layer in `.draugr.conf` would have reimplemented, worse and
only for this tool. So `DRAUGR_NET_STRICT`, `DRAUGR_NET_ALLOW`, `DRAUGR_NET_DENY` and
`DRAUGR_BOOTSTRAP` do not exist; there is a single `DRAUGR_KIT` pointing at a directory. `dr-policy`
survives as a viewer plus an escape hatch for ad-hoc rules on a running mound.

**The rule that follows:** anything a kit can express is a kit's job. What is left is what a kit
structurally cannot see — your WSL paths, your git remotes, your working tree, your machine's memory
store — and that is exactly Draugr's config surface.

Draugr's own contribution is noticing when a kit changes: `dr-up` hashes the kit directory and
compares it to the hash recorded at creation, because applying a kit recreates the container and that
must be a decision rather than a side effect.

### Bash, one script per verb

A binary would need a release pipeline; a Python package would need an interpreter inside a project
that may not want one. Bash is already there, in the shell where the work happens.

One script per verb keeps each file small enough to read in full before you trust it — which, for a
tool whose entire premise is containment, is the point. It also means you can override any single
command by putting your own earlier on `PATH`.

### Shell-syntax config rather than TOML or YAML

No parser dependency, comments are free, and a config can compute values
(`DRAUGR_PORTS="$(cat .ports)"`). The cost is that sourcing a repo's config executes its code, which
is why trust-on-first-use exists — the same bargain your shell makes with `direnv`, for the same
reason.

### Config provenance by snapshot-and-diff

Each layer is sourced in turn with a before/after snapshot of every key, so a config file gets the
blame for exactly the keys it changed. Costs a handful of variable copies and gives `dr-config` an
exact origin per key with no bookkeeping in the config files themselves.

The consequence worth knowing: `dr_load_config` must be called **exactly once** per process. A second
call would see the values the first computed, decide they came from the environment, and rank them
above every config file.

### `--clone` is the default, and `DRAUGR_CLONE=false` prompts every time

No config key can silence that prompt. A bind-mounted working tree is the thing the project exists to
prevent, so if you want the confirmation gone you are outside the premise.

### Names: `draugr-<leaf>` and the `draugr` remote

Sandbox names come from the repo folder, filtered to `sbx`'s charset — it rejects underscores, so
`my_project` becomes `draugr-my-project`. The git remote is `draugr`. Neither collides with anything
`sbx` creates on its own.

### `jq` is a dependency

The alternative is hand-parsing `sbx ls --json` in bash, which is exactly the kind of fragile
cleverness this project should not contain. `dr-doctor` checks for it.

---

## Directories that are not repositories

Supported since 0.1.0, via [`DRAUGR_ON_MISSING_REPO`](CONFIG.md#draugr_on_missing_repo), after
establishing what the constraint actually is.

**Measured first.** `sbx create` does *not* require a git repository; only `--clone` does, and it
says so plainly. Without `--clone`, a plain directory is bind-mounted read-write and there is no
`/run/sandbox/source` at all — a write to `report.md` from inside the mound went straight through to
the host file, replacing it.

So "just drop the git requirement" means shipping `DRAUGR_CLONE=false`, giving up the read-only host
tree that the whole safety model rests on. The way out is to keep clone mode and give it something to
clone.

Two creation modes, and they are **not symmetric**:

- `create-add-all` fixes only the first session. The next edit dirties the tree and the
  commit-before-each-session discipline returns — correct for a code project, wrong for a folder of
  documents.
- `create-data-only` is self-sustaining. Everything is gitignored, so `git status` is empty forever
  and `DRAUGR_REQUIRE_CLEAN` can never fire.

Three properties of the data-only repo, each verified with real git: the clone contains only the
committed setup files and none of the user's; the tree stays clean through edits; and
`git ls-files --others` still lists a `secrets.env`, so `dr-scan` keeps working under a `.gitignore`
of `*`. That last one is luck earned earlier — bare `--others` was chosen because it lists ignored
files, and it pays off in a mode it was not written for.

`create-add-all` seeds `.gitignore` from `DRAUGR_SCAN_PATTERNS` **before** committing, and that is a
safety fix rather than tidiness: `dr-scan` only reports untracked files, so committing a credential
would put it in the agent's clone and in history while silencing the scan that exists to catch it.

Only `dr-init` and `dr-up` may create a repository. Every other command keeps refusing, for the
reason `dr-status` will not start a stopped mound — and that is enforced by which function a command
calls (`dr_context_create` versus `dr_context`), not by care.

---

## Repos on ext4, via a `subst` drive

**Tested, rejected.** The obvious objection to "your repo must live on a Windows drive" is that a WSL
path can be made to look like a Windows one:

```cmd
subst W: \\wsl.localhost\Ubuntu\home\me
```

It is a good idea and it very nearly works. Measured end to end, in order:

1. `subst` accepts the UNC path on Windows 11 — it historically did not, so this is worth knowing.
2. `sbx create claude W:\repo` **succeeds** in bind-mount mode. The workspace appears inside the
   mound at `/w/repo` and its contents are readable.
3. `sbx create --clone …` **refuses**: *"requires a Git repository, but `W:\repo` is not in a Git
   repository"* — though it plainly is one.
4. The real cause is not `sbx`. `subst` is transparent to git, which resolves the drive back to
   `//wsl.localhost/Ubuntu/home/me/repo` and refuses it for **dubious ownership**: file ownership
   across the WSL redirector does not match the Windows user.
5. Add a `safe.directory` exception and git accepts it — then `sbx` pulls the image and dies with
   `500 Internal Server Error: failed to run sandbox container`. **The microVM cannot bind-mount a
   path behind the Windows network redirector.** That is the wall, and it sits below anything Draugr
   could work around.

So the only mode that survives is `DRAUGR_CLONE=false`. The mode Draugr is built on is the one that
fails.

**And it would not have simplified the code even if it had worked**, which is the part worth
recording, because the appeal of the idea is that it looks like a simplification:

- **Path translation gets worse.** `/mnt/c/x ↔ C:\x` is a deterministic pure function, which is why
  `tests/paths.bats` runs in CI on machines with no WSL at all. A `subst` mapping is machine-local,
  user-created, discovered at runtime, ambiguous in reverse, and absent by default.
- **The project-key translation is unchanged in size.** Still three forms.
- **`sbx cp` still demands a Windows path**, so the staging hop stays exactly as it is.
- **Files still arrive mode 777** over that path, so `DRAUGR_DATA_CHMOD` is still needed.

What it would have bought is not simplicity but **speed** — a repo on ext4 gets native-speed git from
WSL, which is the one genuine cost of the current design. Worth revisiting only if a future `sbx` can
mount a WSL path directly.

---

## Deliberately not in v1

Named so nobody has to wonder whether they were forgotten:

- **Multi-repo mounds.** One repository per sandbox.
- **Linux or macOS hosts.** The whole path story is WSL-specific.
- **Running the agent non-interactively for CI.** `dr-shell -- <command>` is as close as this gets.
- **A TUI.** `sbx tui` exists if you want one.
- **Anything that pushes to `origin` on your behalf.** You publish; that is the model.
- **Bidirectional data sync.** There is no merge algorithm for a parquet file: if both sides changed
  it, any bidirectional sync silently picks a winner and destroys the other version. Each transfer
  declares a source of truth instead.

---

## Standing risks

- **`sbx kit` self-identifies as EXPERIMENTAL** — "may change or be removed in future releases". So
  does `sbx skills`. Draugr wraps both rather than reimplementing them, which is the right call while
  they exist and a migration if they change shape.
- **`sbx` feature flags can be set remotely.** `feature.ssh` reads as `enabled:true` from source
  `remote`, not from anything local. A capability statement about `sbx` is a statement about today.
- **`sbx settings` is undocumented** — absent from `sbx --help` — and Draugr reads
  `feature.shareSkills` through it. If that command changes, `dr-skills list` loses its ability to
  report whether the skills mount can be declined.
