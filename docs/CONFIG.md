# Configuration reference

Every `DRAUGR_*` key, what it does, and what happens if you get it wrong.

`tests/docs.bats` fails if a key exists in `lib/common.sh` but not in this file, so this list cannot
quietly fall behind the code. It can still fall behind in *accuracy* — if something here contradicts
what a command does, the command is right and this is a bug worth reporting.

## Where settings come from

Four files, all plain shell (`KEY=value`, `#` comments), sourced in order:

| File | Scope | Commit it? |
|---|---|---|
| `~/.config/draugr/config` | every project on this machine | n/a |
| `<repo>/.draugr.conf` | this project, shared with the team | **yes** |
| `<repo>/.draugr.local.conf` | this project, just you | no — gitignored by `dr-init` |

Precedence, lowest to highest:

```
built-in defaults → user config → project config → project-local → DRAUGR_* env → flags
```

`dr-config` prints the merged result with the origin of each value, and `dr-config --changed` shows
only what differs from the defaults. Use it before assuming anything on this page applies to you.

> **A project config is executed, not parsed.** Sourcing a file from a cloned repository runs its
> code. Draugr records the hash of each project config the first time you accept it and refuses to
> source one it has not seen. Editing your own re-prompts once. Run `dr-trust` to accept.

**A refused config is the failure mode that looks like nothing happening.** Trust is per *content*,
so editing a file you already accepted revokes it — and from then on the table shows built-in
defaults, which is indistinguishable from a file that set nothing. `dr-config` therefore says so
twice: once where it happens, and again in red at the very bottom, which is the end you actually
read.

```
DRAUGR_STOP_ON_EXIT        false                              built-in default

dr-config: 1 config file was NOT sourced, because it is untrusted:
  /mnt/c/src/myproject/.draugr.conf
  Nothing set there appears above. If a setting is not what you
  wrote, that is why. Review it, then:  dr-trust
```

It is loud rather than fatal: nothing has failed, so the exit status stays `0`. `dr-config --files`
answers the same question as a table, and `dr-trust` with no arguments offers every unaccepted config
and hook at once.

---

## The agent and the mound

### `DRAUGR_AGENT`
Default `claude`. One of `claude`, `codex`, `copilot`, `cursor`, `docker-agent`, `droid`, `gemini`,
`kiro`, `opencode`, `shell`. Passed to `sbx create` as the agent name.

Everything except **memory** works the same for all of them: attaching, Ctrl+Z, the clone, kits,
`dr-sync`, `dr-send`, `dr-data`. Memory is each agent's own private layout, so Draugr keeps one file
per agent in `lib/agents/` and only claims to know the ones it has measured:

| | memory | `dr-mem` |
|---|---|---|
| `claude` | `~/.claude/projects/<PATH-KEY>/memory/`, per project | full |
| `codex` | `$CODEX_HOME/memories/` plus its SQLite state, **not** per project, **off by default** | full |
| anything else | not measured | refuses, and says so |

An agent Draugr has no module for still works — `dr-mem` declines rather than copying a directory
into a place the agent will never read. Turn the automatic half off with `DRAUGR_MEM_SYNC=off`.

Switching this on an existing repository is reported by `dr-up` as creation drift: the agent is
frozen into the sandbox spec, so it takes a `dr-up --recreate`. One mound holds one agent. If you
want a Claude mound and a Codex mound for the same project at once, give them separate names and
separate remotes in `.draugr.local.conf`:

```bash
DRAUGR_SANDBOX=draugr-myproject-codex
DRAUGR_REMOTE=draugr-codex
```

Credentials are held by `sbx` on the host, not inside the mound — its proxy authenticates on the
agent's behalf, so nothing is baked in at creation and signing in later needs no rebuild.
`sbx secret set -g anthropic --oauth` for Claude, `sbx secret set -g openai --oauth` for Codex.
`dr-doctor` reports a missing one.

### `DRAUGR_AGENT_ARGS`
Default empty. Arguments handed to the agent after `--` on every `dr-go`, for flags you would
otherwise retype every session:

```bash
DRAUGR_AGENT_ARGS="--continue"        # dr-go resumes by default
```

The command line **replaces** these rather than adding to them, following the same precedence as
every other setting — and it is the only way to drop a configured argument for one run:

| | |
|---|---|
| `dr-go --bare` | pass the agent nothing |
| `dr-go -- --model opus` | pass these instead |

These are the agent's own flags, passed through without being interpreted — so the spelling is the
agent's, not Draugr's. "Carry on from last time" is `--continue` for Claude Code and
`resume --last` for Codex, which is a subcommand rather than a flag and works here all the same:

```bash
DRAUGR_AGENT_ARGS="resume --last"     # dr-go resumes the last Codex thread
```

Neither means anything to `shell`.

> ### Codex on a ChatGPT plan usually needs a model named here
>
> `sbx` writes only `model_provider = "sandboxd"` into the mound's `config.toml` and no `model`, so
> the image's Codex falls back to its own built-in default. On a ChatGPT-plan account that default is
> frequently not one you are entitled to, and **every prompt fails** with:
>
> ```text
> ERROR: {"detail":"The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT account."}
> ```
>
> That is not a credentials problem, and no amount of signing in fixes it — `sbx secret ls` will
> happily show `openai (oauth configured)` throughout. Name a model your account has instead:
>
> ```bash
> DRAUGR_AGENT_ARGS="--model gpt-5.6-terra"
> ```
>
> `-m/--model` is accepted by both `codex` and `codex exec`, checked against the 0.146.0 in `sbx`'s
> image. To see what your account is offered, look at the model cache written by a Codex you have
> logged in on the host:
>
> ```bash
> jq -r '.. | .id? // empty' ~/.codex/models_cache.json | sort -u
> ```

### `DRAUGR_ATTACH`
Default `ssh`. How `dr-go` and `dr-shell` get a terminal inside the mound. The other value is `sbx`.

**`ssh` is the only one where Ctrl+Z works**, and that is the whole reason for the setting.

| | |
|---|---|
| `ssh` | Ctrl+Z suspends the agent and hands you a shell **in the mound**; `fg` goes back |
| `sbx` | Ctrl+Z kills the session with `ERROR: inspect exec: context deadline exceeded` |

`sbx run` and `sbx exec` reach the sandbox through `sbx.exe`, a *Windows* binary that WSL runs over
interop. The terminal you are typing at belongs to WSL; the process reading it does not. Ctrl+Z
therefore suspends the relay rather than anything inside the sandbox — the keystroke never arrives,
the daemon stops hearing from its client, and a few seconds later the whole session dies. Measured
against `sbx 0.37.1`, both ways.

ssh has no such seam: a native Linux client, a real pty at the far end, and job control happening
inside the sandbox where it belongs. It is also the transport `dr-sync` and `dr-data` already use,
so the `*.sbx` block `dr-setup` writes is the only setup either mode needs.

Over ssh the agent runs as a job of an interactive bash, started from `PROMPT_COMMAND` — putting it
in the rcfile instead **hangs**, because bash has not enabled job control while it is still running
its startup files. When the agent exits normally the session ends and `dr-go` returns its status,
exactly as `sbx run` did; only Ctrl+Z is different, and that is by design:

```text
Ctrl+Z   →  $? is 148 (128 + SIGTSTP)  →  stay, and you have the mound's shell
exit     →  the agent's own status      →  leave
```

Set `DRAUGR_ATTACH=sbx` if a future `sbx` changes its ssh proxy, or to compare behaviour. You lose
Ctrl+Z, and `dr-shell --root` goes back to `-u root` instead of `sudo`.

### `DRAUGR_SANDBOX`
Default `draugr-<repo folder name>`. `sbx` rejects underscores and most punctuation, so the name is
filtered to letters, digits, `.`, `+` and `-`: `my_project` becomes `draugr-my-project`.

Set it explicitly to attach Draugr to a sandbox created by hand.

### `DRAUGR_MEMORY`
Default empty, meaning `sbx`'s own default — 50% of host RAM, capped at 32 GiB. Binary units:
`8g`, `1024m`.

### `DRAUGR_CPUS`
Default empty, meaning all host CPUs.

### `DRAUGR_CLONE`
Default `true`. The agent works on a private clone inside the mound; your working tree is mounted
**read-only** at `/run/sandbox/source`.

`false` bind-mounts your real working tree read-write, which is the thing Draugr exists to prevent.
`dr-go` confirms interactively every single time and no config key can silence that prompt. See
[SECURITY.md](SECURITY.md).

### `DRAUGR_TEMPLATE`
Default empty. A container image to use instead of the agent's default.

---

## What the agent may reach

### `DRAUGR_KIT`
Default `.draugr/kit`. A **space-separated list** of directories, ZIPs, git refs or OCI images
holding [`sbx` kits](https://docs.docker.com/ai/sandboxes/customize/kits/).

**Network rules and setup commands are not Draugr keys.** They belong to the kit, which is a
first-party declarative format that already does the job and works with plain `sbx run --kit` too.
`dr-init` writes a starter `spec.yaml`; commit it.

It is a list because `sbx` **merges** kits rather than choosing between them — verified, two mixins on
one sandbox contributed both their install commands and both their network rules. So a shared kit
*adds* to the project's:

```bash
DRAUGR_KIT=".draugr/kit lua"     # this project's kit, plus the library's "lua"
```

Each entry resolves in order: absolute path → a directory in the repo → a named kit in
`DRAUGR_KIT_STORE` → anything containing `:` or `@`, passed through as an OCI or git reference. The
repo is searched before the library so a local directory of the same name always wins.

Each of those is tried twice — with `.<agent>` appended, then plain. So `.draugr/kit.codex` beats
`.draugr/kit` under `DRAUGR_AGENT=codex`, and a library kit `lua.codex` beats `lua`. Most kits need
nothing of the sort: network rules, install commands and ports are properties of the project, not of
the agent running in it. An OCI or git reference gets no suffix — it is not Draugr's to invent a tag
in somebody else's registry.

A kit **may** pin itself with `requires: agent: claude`, and `sbx` then refuses to compose it with
any other agent:

```text
ERROR: request failed: 400 Bad Request: kit_artifacts: compose:
kit "myproject" requires base agent "claude" but was composed with "codex"
```

`sbx kit validate` accepts such a kit — the mismatch only exists at creation — so Draugr reads the
field itself and refuses first, in `dr-up`, `dr-kit validate` and `dr-doctor`. `dr-init` does not
write the field, because freezing today's agent into a committed file would make trying another one
an edit rather than a setting.

`dr-up` warns when the list has changed since the mound was built, because applying it recreates the
container — that must be a decision, not a side effect. `dr-kit apply` does it. A remote reference
contributes only its *name* to that comparison; a tag that moved under you is drift Draugr cannot see,
and `dr-kit drift` says so rather than implying a clean bill of health.

### `DRAUGR_KIT_STORE`
Default `~/.config/draugr/kits`. Your library of named kits, shared across repositories — "the Lua
toolchain" is a fact about you, not about one repo.

| | |
|---|---|
| `dr-kit save <name>` | copy this project's own kit into the library |
| `dr-kit list` | what is in there, with each `displayName` |
| `dr-kit adopt` | write hosts opened with `dr-policy --allow` into this project's kit |

`adopt` is the end of the build-your-own-kit loop described in
[WORKFLOW.md](WORKFLOW.md#letting-the-agent-build-the-kit). It reads back what was actually opened
for the mound, skips whatever the kit already declares, and writes the rest into
`caps.network.allow` — so nothing has to be remembered while the loop runs. It edits only that one
block; a kit it does not recognise is reported and left untouched rather than guessed at.

`save` copies rather than symlinks, so editing one side never silently changes the other. Editing the
library copy does put every repo that uses it into drift until its next `dr-kit apply` — which is the
point of drift detection, not a flaw in it. For sharing across *machines*, `sbx kit pack` and
`sbx kit push` already work, and an OCI reference is a valid `DRAUGR_KIT` entry.

### `DRAUGR_PORTS`
Default empty. Space-separated `HOST:SANDBOX` pairs, published to Windows loopback:

```bash
DRAUGR_PORTS="5173:5173 8080:8080"
```

A kit can declare `publishedPorts` too. Use the kit for ports the project always needs and this —
or `dr-ports`, mid-session — for today's.

### `DRAUGR_HOST_PORTS`
Default empty. Space-separated **port numbers** on this machine that the mound is allowed to reach:

```bash
DRAUGR_HOST_PORTS="11434"        # a local Ollama on the host's GPU, say
```

The mirror image of `DRAUGR_PORTS`. That publishes a port *out* of the mound so a Windows browser can
reach in; this opens a port *into* your machine so the agent can call out. `dr-up` applies it on
every start, and `dr-hostport` is the mid-session equivalent — the same pairing as
`DRAUGR_PORTS` and `dr-ports`.

Only the port is ever named. The address is resolved each time this is applied, because WSL's is
handed out per boot and cannot be pinned — WSL 2.6.1 has no `natNetwork` setting at all. A rule
written with a literal IP is correct until the next reboot and then fails **closed and silently**:
the connection is accepted by the sandbox's interception layer and dropped, with no error to read.
Rules left behind for addresses this machine no longer has are removed as they are found.

The service has to be listening on `0.0.0.0`, not `127.0.0.1` — from inside the mound, `127.0.0.1` is
the mound. `dr-hostport` warns when it can see that mistake.

> This is a hole from the sandbox to your machine, and the more serious of the two directions: on the
> other side is a process outside the mound. Anything the agent can reach there, it can use. Declaring
> it in a project's `.draugr.conf` takes effect only after you have accepted that file with `dr-trust`,
> which is where the consent lives.

### `DRAUGR_MOUNTS`
Default empty. Extra host directories, space-separated, each `PATH[:ro]`:

```bash
DRAUGR_MOUNTS="/mnt/c/Docs/api:ro"
```

Paths are translated to the Windows spelling `sbx` requires, and must be on a Windows drive. **A
sandbox can read every byte of anything you mount into it** — never mount `~/.claude`, which holds
your agent credentials.

**A mount lands at the mirrored path**, the same rule the repo itself follows: `C:\Code\TabuLua`
appears at `/c/Code/TabuLua`. So a sibling project stays a sibling, and a relative path across the
two keeps working unchanged:

```bash
# in C:\Code\SurvivalGameData/.draugr.conf
DRAUGR_MOUNTS="/mnt/c/Code/TabuLua:ro"
```

```text
/c/Code/SurvivalGameData      ← the clone, writable
/c/Code/TabuLua               ← the mount, read-only
```

`../TabuLua` resolves from inside the clone with nothing rewritten. Measured: the agent reads it,
`echo >>` and `touch` both fail with `:ro`, and the clone stays writable.

**The mount is your live working tree, not a clone.** Uncommitted edits on the host are visible
inside the mound immediately — no commit, no push, no `dr-sync`. That is the difference from
packaging a dependency into a kit, which would freeze it at whatever you last published.

Two things follow. The agent sees your work in progress, including a half-finished refactor. And
`dr-scan` does **not** look inside extra mounts — it scans the repository you are in — so a
credential-shaped file in a mounted directory is readable and unreported.

> **Mounts are fixed when the mound is built.** Adding one to `.draugr.conf` does nothing to a
> sandbox that already exists. `dr-up` says so and names the setting; `dr-up --recreate` rebuilds.

---

## Moving code

### `DRAUGR_BRANCH`
Default empty, meaning whatever branch is checked out. Fixes the branch `dr-sync` fetches.

### `DRAUGR_REMOTE`
Default `draugr`. The name of the git remote pointing at the mound. Your `origin` is never touched.

### `DRAUGR_REQUIRE_CLEAN`
Default `true`. Refuses `dr-go` when the working tree is dirty, because a clone contains *committed
history only* — uncommitted work simply is not in it, and the agent would quietly build on stale
code. `dr-go --dirty` overrides for one run.

Paths matching `DRAUGR_DATA` are exempt: they travel by a different mechanism and are never expected
to be committed.

**The exemption is all-or-nothing.** One dirty file that is *not* data still stops the session — the
point of the check is that the agent would be working from stale code, and one stale file is enough.
The refusal names only the files that blocked, and counts the rest:

```text
dr-go: your working tree has uncommitted changes
?? skills.txt
?? skills/
dr-go: 15 more match DRAUGR_DATA and are exempt - these are not
```

### `DRAUGR_STOP_ON_EXIT`
Default `false`. When true, `dr-go` stops the mound after you leave the agent — last of all, once the
sync, the memory export and the data pull have run, because each of those needs it alive.

Off by default for two reasons. Stopping silently kills anything the kit starts through
`publishedPorts` or `startup` commands, which is a workflow the kit format exists to support; and
`dr-go` is re-entered constantly, where a cold start costs measurably more than an attach.

| measured on one machine | |
|---|---|
| RAM a running mound holds | ~1.4 GB, fully recovered on stop |
| cold start (`stopped → running`) | 4.2 s |
| attach to a running mound | 0.36 s |

Worth turning on per-project for anything that serves nothing, or in `~/.config/draugr/config` if you
would rather pay the four seconds. It is **not** a durability measure — what protects the agent's
work is the `dr-sync` that has already run. See
[the durability model](WORKFLOW.md#what-is-durable-and-what-is-not).

### `DRAUGR_AUTO_SYNC`
Default `true`. Runs `dr-sync` when you leave the agent. It only fetches — nothing is merged and your
branch does not move — so the worst case is a few seconds and a remote-tracking branch you ignore.

### `DRAUGR_ON_MISSING_REPO`
Default `fail`. What to do when you point Draugr at a directory that is not a git repository.

| Value | |
|---|---|
| `fail` | Refuse, naming the alternatives. Clone mode needs a repository, and clone mode is what keeps your files read-only to the agent. |
| `create-add-all` | `git init` and commit everything. For *"this is a code project I forgot to `git init`"*. Credential-shaped names and `DRAUGR_DATA` patterns are gitignored **first**, never committed. |
| `create-data-only` | `git init` with a `.gitignore` of `*`, so git tracks nothing and `git status` is empty forever. Files travel by `DRAUGR_DATA`, which is set to `*` for you. For folders of documents or data. |

Only `dr-init` and `dr-up` will ever create a repository. `dr-status`, `dr-scan` and the rest still
refuse — a command you run to find out what is going on must not change what is going on.

`create-data-only` gives up `dr-diff` and `dr-merge`: there are no commits to compare. Review is
`dr-data status`, which reports which files differ rather than what changed inside them.

---

## Moving data

Large or half-processed files travel beside git rather than through it. See
[WORKFLOW.md](WORKFLOW.md#working-with-data-files).

### `DRAUGR_DATA`
Default empty. Space-separated, repo-relative patterns. Three shapes, and the shape decides the
meaning:

| Entry | Means |
|---|---|
| `scratch/raw/` | trailing slash: that directory and everything under it |
| `tmp/**` | contains a slash: a path pattern, anchored at the repo root |
| `*.parquet` | no slash: a bare name or extension, matched at **any** depth |

`.git` and `.draugr` are always excluded, whatever you write here — without that, `DRAUGR_DATA="*"`
would push your `.git` over the mound clone's, and even `*.sample` would reach into `.git/hooks/`.

### `DRAUGR_DATA_PUSH`
Default `auto`. Host → sandbox, before the agent starts. `auto`, `manual` or `off`.

The first transfer of a large tree is a real wait, and it happens inside `dr-up` at the moment you
expected a prompt. That is what `dr-data status` is for, and why `manual` exists.

### `DRAUGR_DATA_PULL`
Default `manual`. Sandbox → host, when you detach. A pull overwrites host files, so it is opt-in.

### `DRAUGR_DATA_DELETE`
Default `false`. Whether a transfer propagates deletions (`rsync --delete`). Even when `true`, each
run asks: the destructive case is the one where you tidied one side and forgot the other holds your
only copy.

### `DRAUGR_DATA_CHMOD`
Default `D755,F644`. Files on `/mnt/c` are mode 777 under WSL, and a naive transfer carries that into
the mound. This normalises on the way **in**.

It does nothing on the way **out**, and it is worth knowing why: DrvFs ignores `chmod`, so a file
pulled onto `/mnt/c` lands `-rwxrwxrwx` whatever this is set to. Measured — the pulled file passes
`test -x` and runs. Do not read this key as a guard against the sandbox landing something executable
on your host; [`dr-data diff`](SECURITY.md#the-data-channel-has-no-commit-to-read) is that guard.

### `DRAUGR_DATA_DIFF_MAX`
Default `262144` (256 KB). The per-file ceiling for `dr-data diff`. Text files at or under it are
shown as a real unified diff; anything larger is reported by name and size instead, because a diff of
a 4 GB CSV helps nobody. Binary files are never shown regardless of size. Raise it when you have a
large generated file you genuinely need to read.

---

## Memory

### `DRAUGR_MEM_SYNC`
Default `auto`.

| Value | |
|---|---|
| `auto` | Import on `dr-up`, export when you leave the agent. The import only ever fills a mound with **no** memory — the store is by definition the older copy. |
| `manual` | No automatic transfers, but `dr-rm` still refuses to destroy unexported memory and `dr-status` still reports it. |
| `off` | You do not keep agent memory: no transfers, no refusal, no memory section. |

### `DRAUGR_MEM_STORE`
Default `~/.local/share/draugr/memory`. Where `dr-mem export` writes: by the host form of the project
key, then by agent.

```text
~/.local/share/draugr/memory/
└── c--Code-TabuLua/          the project, host-keyed so it never starts with "-"
    ├── claude/
    │   ├── .draugr-export    what was exported, from where, when
    │   ├── memory/           the exported copy
    │   └── memory.previous/  the one it replaced — one `mv` from getting it back
    └── codex/
        └── memory/           memories/*.md, and the SQLite session state
```

Two agents' memories of one project are different things in different shapes, so they get separate
corners; the project comes first so everything about it stays in one place. A store written before
0.2.0 had `memory/` sitting directly in the project's corner — the first `dr-mem` or `dr-status`
after upgrading moves it under `claude/` and says so.

May live anywhere, including WSL's own filesystem — Draugr stages transfers through the repo because
`sbx cp` is a Windows binary that will not write to a WSL path.

---

## Safety rails

### `DRAUGR_SCAN`
Default `true`. Runs `dr-scan` before the mound exists, which is the point: a credential should be
found before anything can read it.

### `DRAUGR_SCAN_PATTERNS`
Default `.env *.pem *.key id_rsa id_ed25519 credentials.json secrets.*`. Globs matched against the
**basename** of every file git is not tracking — ignored or not, which is the whole point.

### `DRAUGR_SCAN_FAIL`
Default `block`. `block` turns a finding into a refusal; `warn` reports and continues.

Leave it at `block`. `.gitignore` hides files from git, not from the filesystem: an untracked `.env`
is fully readable through the read-only mount even though it is absent from the agent's clone.

---

## Hooks

Not keys, but the same job. Executable scripts at
`.draugr/hooks/{pre-up,post-up,post-create,pre-attach,post-attach,post-sync,pre-rm}`.

They run on the **host**, in WSL, with the merged config in the environment — which is precisely what
a kit's commands cannot do, since a kit runs inside the mound and cannot see your machine. A hook
that exits non-zero aborts the command, so hooks can veto.

`post-create` fires only when a sandbox is actually built; `post-up` fires on every `dr-up`,
including the ones that just start a stopped mound.
