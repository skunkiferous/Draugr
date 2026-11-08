# Design notes

Why Draugr has this shape, with the paths that we tried and abandoned. We keep the rejected ones,
because people are likely to ask about them again, usually right after they had the same good idea.

## Why this exists at all

An agent with `--dangerously-skip-permissions` on your real machine is fast and reckless. The
approval of each tool call is safe and slow. Draugr takes a third option. It makes the possible
damage so small that "let it run" is the *responsible* choice.

`sbx` already gives the isolation, but not a workflow. Without Draugr, you build git remotes by
hand. You must remember that WSL cannot reach the git daemon. Agent memory is under a key that
comes from the path, and the key is different on the host and in the sandbox. You type five
commands in each session.

### Prior art

Surveyed in August 2026, before any code existed. Wrappers around `sbx` exist:
[sbxgo](https://github.com/HenrikPoulsen/sbxgo), [sbx-toolkit](https://github.com/maxkrivich/sbx-toolkit),
[streamingfast/sbox](https://github.com/streamingfast/sbox),
[code-sandbox-console](https://github.com/ainova-systems/code-sandbox-console), and thinner ones in
[awesome-docker-sbx](https://github.com/ajeetraina/awesome-docker-sbx).

They share only the *configuration file* idea with Draugr. None has the sandbox→host git loop,
agent memory transfer, or data sync, and **none mentions WSL**. That last gap decides it. These
problems made Draugr worth building: `sbx.exe` is not on the `PATH` of WSL, paths need a three-way
translation, and the git daemon binds Windows loopback, where the NAT of WSL2 cannot reach it.

---

## Decisions, and what they cost

### Kits own the inside of the mound; Draugr owns the boundary

This is the largest decision, and it removed four planned configuration keys.

[`sbx kit`](https://docs.docker.com/ai/sandboxes/customize/kits/) is a declarative artifact from
Docker. It already declares network allow and deny lists, install commands that run once at
creation, startup commands, published ports, seeded files, environment variables, and extra agent
instructions. It also gives credentials through a proxy on the host, so that the secret never
enters the microVM.

A network-policy layer in `.draugr.conf` copies most of that, worse, and only for this tool.
Thus `DRAUGR_NET_STRICT`, `DRAUGR_NET_ALLOW`, `DRAUGR_NET_DENY` and `DRAUGR_BOOTSTRAP` do not
exist. There is a single `DRAUGR_KIT`, which points at a directory. `dr-policy` stays, as a viewer,
and as a way to add ad-hoc rules on a running mound.

**The rule that follows:** all that a kit can express is the job of the kit. The rest is what a kit
cannot see: your WSL paths, your git remotes, your working tree, the memory store of your machine.
That is exactly the configuration of Draugr.

Draugr sees when a kit changes. `dr-up` hashes the kit directory, and compares it to the hash from
creation. An apply of a kit recreates the container, and that must be a decision, not a side
effect.

### Bash, one script per verb

A binary needs a release pipeline. A Python package needs an interpreter, inside a project that
possibly does not want one. Bash is already there, in the shell where the work happens.

With one script for each verb, each file is small enough to read fully before you trust it. For a
tool that is about containment, that is the purpose. You can also override one command with your
own script earlier on `PATH`.

### Shell-syntax config rather than TOML or YAML

No parser dependency, free comments, and a configuration can compute values
(`DRAUGR_PORTS="$(cat .ports)"`). The cost: to source the configuration of a repo runs its code.
That is why trust on first use exists. Your shell makes the same deal with `direnv`, for the same
reason.

### Config provenance by snapshot-and-diff

Draugr sources each layer in turn, with a snapshot of each key before and after. Thus each file gets
the blame for exactly the keys that it changed. That costs a few variable copies. It gives
`dr-config` an exact origin for each key, with no records in the configuration files.

Know this result: each process must call `dr_load_config` **exactly once**. A second call sees the
values that the first call computed. It then decides that they came from the environment, and ranks
them above each configuration file.

### `--clone` is the default, and `DRAUGR_CLONE=false` prompts every time

No configuration key can stop that prompt. The project exists to prevent a bind-mounted working
tree. Thus if you want no confirmation, you are outside the purpose of the project.

### Names: `draugr-<leaf>` and the `draugr` remote

Sandbox names come from the repo folder, with only the characters that `sbx` accepts. It rejects
underscores, so `my_project` becomes `draugr-my-project`. The git remote is `draugr`. Neither name
collides with anything that `sbx` creates itself.

### `jq` is a dependency

The alternative is to parse `sbx ls --json` by hand in bash. That is exactly the fragile trick that
this project must not contain. `dr-doctor` makes sure that it is installed.

### The forge is off by default, and `dr-forge` speaks verbs

The forge is a Windows 11 VM that an agent controls: a GPU partition, an installed toolchain and a
desktop. A Linux microVM can give none of these. It is the least general part of Draugr. Two
decisions make sure that it costs nothing to the people who never want it.

**It does not exist unless [`DRAUGR_FORGE`](CONFIG.md#draugr_forge) names a VM.** The default is
empty. Thus there is no extra dependency, no prompt, no line in `dr-doctor` to explain, and no
change to the guarantees of [SECURITY.md](SECURITY.md). With the key empty, `dr-forge` says so and
stops. It does not adopt a VM that it found. The people who turn it on pay the cost, and it is a
real cost. The guest is a machine that the agent administers, not a mound. Thus almost none of the
guarantees of the mound apply
([SECURITY.md](SECURITY.md#the-forge-if-you-turn-it-on) gives the full, weaker claim).

**The surface of `dr-forge` is verbs, never the nouns of the backend**: `status`, `doctor`, `init`,
`up`, `down`, `screen`, `base`, `rollback`, `rm`, `exec`, `push`, `pull`. AppSandbox is behind them
today. A replacement must match the verbs, not the API. The one place where that abstraction is thin
on purpose is `base`/`rollback`. They give a single baseline, not a history, because of the
upstream bug in the risks below. The shape of a defect is visible in the surface.

[FORGE.md](FORGE.md) is the design, with its measurements.

---

## Directories that are not repositories

Supported since 0.1.0, through [`DRAUGR_ON_MISSING_REPO`](CONFIG.md#draugr_on_missing_repo), after
we found the real limit.

**Measured first.** `sbx create` does *not* need a git repository. Only `--clone` does, and it says
so clearly. Without `--clone`, a plain directory is bind-mounted read-write, and there is no
`/run/sandbox/source`. A write to `report.md` from inside the mound went directly to the host file,
and replaced it.

Thus "remove the git requirement" means `DRAUGR_CLONE=false`. That gives up the read-only host tree,
and the full safety model rests on it. The way out: keep clone mode, and give it something to clone.

Two creation modes, and they are **not symmetric**:

- `create-add-all` fixes only the first session. The next edit makes the tree dirty, and you must
  commit before each session again. That is correct for a code project, but wrong for a folder of
  documents.
- `create-data-only` keeps itself clean. All files are in .gitignore, so `git status` is always
  empty, and `DRAUGR_REQUIRE_CLEAN` never fires.

Three properties of the data-only repo, each tested with real git. The clone contains only the
committed setup files, and none of the files of the user. The tree stays clean after edits.
`git ls-files --others` still lists a `secrets.env`, so `dr-scan` still works under a `.gitignore`
of `*`. That last one is luck from an earlier choice. We chose bare `--others` because it lists
ignored files, and that pays off in a mode that it was not written for.

`create-add-all` fills `.gitignore` from `DRAUGR_SCAN_PATTERNS` **before** the commit. That is a
safety fix, not tidiness. `dr-scan` reports only untracked files. Thus a committed credential goes
into the clone of the agent and into history, and the scan that exists to find it goes silent.

Only `dr-init` and `dr-up` can create a repository. All other commands still refuse, for the same
reason that `dr-status` does not start a stopped mound. The function that a command calls enforces
that (`dr_context_create` or `dr_context`), not care.

---

## Repos on ext4, via a `subst` drive

**Tested, rejected.** The clear objection to "your repo must be on a Windows drive": you can make a
WSL path look like a Windows path:

```cmd
subst W: \\wsl.localhost\Ubuntu\home\me
```

It is a good idea, and it almost works. Measured end to end, in order:

1. `subst` accepts the UNC path on Windows 11. Before, it did not, so this is useful to know.
2. `sbx create claude W:\repo` **succeeds** in bind-mount mode. The workspace shows inside the
   mound at `/w/repo`, and its contents are readable.
3. `sbx create --clone …` **refuses**: *"requires a Git repository, but `W:\repo` is not in a Git
   repository"*, though it clearly is one.
4. The real cause is not `sbx`. `subst` is transparent to git. git resolves the drive back to
   `//wsl.localhost/Ubuntu/home/me/repo`, and refuses it for **dubious ownership**. The file owner
   across the WSL redirector does not match the Windows user.
5. Add a `safe.directory` exception, and git accepts it. Then `sbx` pulls the image, and dies with
   `500 Internal Server Error: failed to run sandbox container`. **The microVM cannot bind-mount a
   path behind the Windows network redirector.** That is the wall, and it is below all that Draugr
   can work around.

Thus only `DRAUGR_CLONE=false` works. The mode that Draugr rests on is the mode that fails.

**And a working `subst` drive does not make the code simpler.** That is the important part,
because the idea looks like a simplification:

- **Path translation gets worse.** `/mnt/c/x ↔ C:\x` is a fixed pure function. That is why
  `tests/paths.bats` runs in CI on machines with no WSL. A `subst` mapping is local to one machine,
  made by the user, found at runtime, ambiguous in reverse, and absent by default.
- **The project-key translation has the same size.** Still three forms.
- **`sbx cp` still needs a Windows path**, so the staging step stays exactly the same.
- **Files still arrive as mode 777** over that path, so `DRAUGR_DATA_CHMOD` is still necessary.

It gives **speed**, not simplicity. A repo on ext4 gets native-speed git from WSL, and that is
the one real cost of the current design. Look at it again only if a later `sbx` can mount a WSL path
directly.

---

## Deliberately not in v1

Named, so that nobody needs to ask whether we forgot them:

- **Multi-repo mounds.** One repository for each sandbox.
- **Linux or macOS hosts.** The full path design is specific to WSL.
- **The agent with no terminal, for CI.** `dr-shell -- <command>` is the closest option.
- **A TUI.** If you want one, `sbx tui` exists.
- **Anything that pushes to `origin` for you.** You publish. That is the model.
- **Data sync in both directions.** There is no merge algorithm for a parquet file. If both sides
  changed it, a sync in both directions silently selects one version, and destroys the other. Each
  transfer declares a source of truth.

---

## Standing risks

- **`sbx kit` calls itself EXPERIMENTAL**: "may change or be removed in future releases". So does
  `sbx skills`. Draugr wraps both, and does not copy them. That is the right choice while they
  exist, and a migration if they change shape.
- **A remote source can set `sbx` feature flags.** `feature.ssh` reads as `enabled:true` from the
  source `remote`, not from a local value. A statement about what `sbx` can do is true only today.
- **`sbx settings` has no documentation.** `sbx --help` does not show it, and Draugr reads
  `feature.shareSkills` through it. If that command changes, `dr-skills list` can no longer report
  whether you can decline the skills mount.
- **The backend of the forge is six months old, and the project of one person.** AppSandbox is at
  0.1.8. Its author treats pull requests as "suggestions and examples of possible solutions", which
  the author is "unlikely to formally review or merge", and uses them as a reference for their own
  fix (*read*: the PR template of the repository). Thus the author fixes a bug that Draugr finds on
  their own schedule, not on that of Draugr. Draugr must keep working on **released** versions,
  never on a patched build that nobody else has. Two facts make that acceptable, not reckless. The
  surface of `dr-forge` is verbs, so you can replace the backend. And the full feature is not
  visible unless `DRAUGR_FORGE` is set. One fact points the other way, and we must say it.
  AppSandbox ships EV-Authenticode-signed binaries, with drivers signed by Microsoft attestation.
  That is not maturity, but it shows that somebody is active.
- **The snapshot bug under the undo of the forge is open upstream, and a wait is no longer a
  plan.** Only the *first* snapshot of a VM captures its current state. Each later snapshot branches
  from the base disk, and silently discards the work that it was taken to protect
  ([#152](https://github.com/jamesstringer90/appsandbox/issues/152)). The author asked for a
  version that keeps parent disks immutable, and recovers from a failure halfway. That version is
  [#199](https://github.com/jamesstringer90/appsandbox/pull/199), in the form that the author asked
  for. Nothing says whether or when it lands. Thus "wait for upstream" means "wait forever". That is
  why `dr-forge base` takes one baseline and refuses a second, and does not claim to keep a history.
  If #199 lands, that limit can go, and nothing else in the design must move
  ([FORGE.md](FORGE.md#backup-and-rollback) has the call sequence).
