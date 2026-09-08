# Draugr

**Bind your coding agent to a mound it cannot leave.**

Draugr is a thin, config-driven workflow layer that runs Claude Code (or Codex, Gemini, Copilot,
…) inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) microVM, driven entirely from
a WSL shell. The agent gets its own kernel, its own Docker daemon, and a private clone of one
repository. It cannot touch your Windows drive, your SSH keys, your other projects, or your
credentials — so you can stop approving every command and let it work.

In Norse folklore a *draugr* is an undead creature that guards its burial mound. It is immensely
strong, and it never leaves. That is the deal here: the agent is powerful inside the mound and has
no reach outside it.

**WARNING:** This entire project has been "vibe-coded" by [Claude Code](https://claude.ai).

> **Status: 0.2.0 — ready to be used rather than read.** Every command in the tables below exists
> and has tests; the mechanics are verified against `sbx` v0.37.1 on Windows 11 + WSL2. It has not
> yet been used by anyone but its author, so expect rough edges in the places nobody has walked.
>
> This file is the specification: it was written before the code, and where the two disagree the
> code is the bug.

## Documentation

| | |
|---|---|
| [docs/SETUP.md](docs/SETUP.md) | From a bare machine to a working session |
| [docs/WORKFLOW.md](docs/WORKFLOW.md) | The daily loop, review, data, memory, skills |
| [docs/CONFIG.md](docs/CONFIG.md) | Every `DRAUGR_*` key, and what happens if you get it wrong |
| [docs/CLAUDE_PLUGINS.md](docs/CLAUDE_PLUGINS.md) | Using Claude Code plugins in a mound without installing them on your host |
| [docs/SECURITY.md](docs/SECURITY.md) | What the agent can and cannot reach, and how that was measured |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptoms, causes, fixes |
| [docs/DESIGN.md](docs/DESIGN.md) | Why it is shaped this way, including what was tried and rejected |
| [docs/HACKING.md](docs/HACKING.md) | **Reading the source? Start here**, not with a script |
| [CHANGELOG.md](CHANGELOG.md) | What changed, and when |

---

## Why this exists

Running an agent with `--dangerously-skip-permissions` on your real machine is fast and reckless.
Approving every tool call is safe and miserable. Draugr takes the third option: make the blast
radius small enough that "let it run" is the *responsible* choice.

`sbx` already provides the isolation. What it does not provide is a workflow. Out of the box you
are hand-building git remotes, remembering that the git daemon is unreachable from WSL, discovering
that agent memory lives under a path-derived key that differs between host and sandbox, and
re-typing five commands per session. Draugr is the missing layer: **a layered config, a per-project
kit, and a set of one-purpose `dr-*` scripts.**

---

## The daily loop

This is the whole thing. Five commands, from one WSL terminal.

```bash
cd /mnt/c/src/myproject

dr-go                    # preflight, create-or-start the mound, attach, launch the agent
                         # ... the agent works and commits inside the sandbox ...
                         # Ctrl+Z for a shell in the mound, fg to go back
                         # Ctrl+D when you're done

dr-sync                  # fetch its commits onto draugr/main
dr-diff                  # review what it actually did
dr-merge                 # accept it
git push                 # publish, exactly as you always did
```

`dr-go` is idempotent and does everything a session needs: checks the daemon, scans for credentials
the agent should not see, creates the sandbox if it is missing — applying your project's kit, which
carries its network rules and setup commands — imports your agent memory, then drops you into the
agent. Second run, it just attaches.

**Ctrl+Z works.** It suspends the agent and leaves you at a prompt inside the mound, in the clone;
`fg` puts you back where you were. One window, no second connection. That is why Draugr runs in WSL
and attaches over ssh rather than through `sbx.exe` — see
[`DRAUGR_ATTACH`](docs/CONFIG.md#draugr_attach).

---

## The mental model

You have **three** repositories. Everything else follows from that.

```
      YOUR REMOTE  (origin)
           ▲  │
      push │  │ pull                    ← unchanged, exactly as you always did it
           │  ▼
      HOST REPO  ◄────── dr-sync ──────  SANDBOX CLONE
   /mnt/c/src/myproject                 (inside the microVM)
           │
           └──── mounted READ-ONLY ────►  visible to the agent at /run/sandbox/source
```

1. **Only you talk to the remote.** The sandbox has no credentials and no route to it.
2. **The sandbox cannot write to your repository.** That mount is read-only, enforced by the
   kernel — not by convention. (It is not the *only* thing mounted from the host, though: see
   [Safety model](#safety-model) for the one writable exception, which is not your project.)
3. **You pull *from* the sandbox.** It never pushes to you.

Treat the agent like a colleague who hands you a branch: fetch it, review it, merge it, push it
yourself.

**Nothing here is forge-specific.** Draugr never touches your `origin` — it only adds a second
remote pointing at the sandbox. GitHub, GitLab, Gitea, Forgejo, Bitbucket, a bare repo on a NAS, or
no remote at all: all identical, because the only thing Draugr needs from your project is that it
is a git repository.

---

## Requirements

| | |
|---|---|
| Windows 11 Pro, x86_64 | Hypervisor Platform feature enabled |
| WSL2 | Draugr runs here. Ubuntu tested. |
| `sbx` ≥ 0.37 | `winget install Docker.sbx`. Docker Desktop is **not** required. |
| git ≥ 2.40 | on both sides |
| A repo **on a Windows drive** | see below |

> ### Your repo must live under `/mnt/<drive>/…`
> `sbx.exe` is a Windows binary and its workspaces are Windows paths. A repository on WSL's own
> ext4 filesystem (`~/code/myproject`) has no usable host path, so Draugr refuses it with a clear
> error rather than failing mysteriously later. Keep sandboxed projects on `C:` (or any Windows
> drive) and work on them from WSL via `/mnt/c/…`.
>
> The only cost is that WSL reaches `/mnt/c` through a translation layer, so the git operations
> Draugr runs from WSL — `status`, `diff`, `fetch` — are slower on a large repo than they would be
> on ext4. Reaching the same files from Windows is native NTFS access and costs nothing, so a
> Windows-side editor or `git.exe` is unaffected. The agent's clone lives on ext4 *inside* the
> microVM, so the side doing the compiling is unaffected either way.
>
> **And no, a `subst` drive does not get you out of it.** Mapping `W:` to
> `\\wsl.localhost\Ubuntu\home\me` does give a WSL directory a Windows-looking path, and `sbx` will
> even create a *bind-mount* sandbox on it. But `--clone` — the mode this entire project is built on
> — fails: git resolves the drive back to the UNC path and rejects it for dubious ownership, and
> once you allow that, the container itself refuses to start, because the microVM cannot bind-mount
> a path behind the Windows network redirector. Measured end to end; the full sequence is in
> [docs/DESIGN.md](docs/DESIGN.md#repos-on-ext4-via-a-subst-drive).

---

## Install

```bash
git clone https://github.com/YOU/draugr.git ~/draugr
echo 'export PATH="$HOME/draugr/bin:$PATH"' >> ~/.bashrc
exec bash

dr-setup      # one-time: writes the *.sbx block into your WSL ~/.ssh/config
dr-doctor     # verifies everything, tells you exactly what is missing
```

`dr-setup` is the piece people miss. `sbx setup ssh` configures the **Windows** SSH client only;
WSL has its own `~/.ssh/config`, and without the matching block neither `ssh <name>.sbx` nor the
`ssh://` git transport works from WSL. `dr-setup` writes it, with your Windows username filled in.

Then, in each project:

```bash
cd /mnt/c/src/myproject
dr-init       # writes a starter .draugr.conf and trusts it
```

---

## Configuration

Three files, all plain shell (`KEY=value`, comments with `#`, sourced in order):

| File | Scope | Commit it? |
|---|---|---|
| `~/.config/draugr/config` | every project on this machine | n/a |
| `<repo>/.draugr.conf` | this project, shared with the team | **yes** |
| `<repo>/.draugr.local.conf` | this project, just you | no — gitignore it |

Precedence, lowest to highest:

```
built-in defaults  →  user config  →  project config  →  project-local  →  DRAUGR_* env  →  flags
```

`dr-config` prints the merged result with the origin of every value, so "why is it doing that"
is always one command away.

> ### `.draugr.conf` is executed, so it is trusted on first use
> Sourcing a file from a cloned repository means running its code. Draugr records the hash of each
> project config in `~/.config/draugr/trusted` the first time you accept it, and refuses to source
> a config it has not seen before until you run `dr-trust`. Editing your own config re-prompts
> once. This is the same bargain your shell makes with `direnv`, and for the same reason.

### What you will actually want to change

**Which agent, and how big a mound**

```bash
DRAUGR_AGENT=claude                  # claude|codex|copilot|cursor|docker-agent|droid|gemini|
                                     # kiro|opencode|shell
DRAUGR_AGENT_ARGS=                   # passed to the agent every time, e.g. "--continue"
DRAUGR_SANDBOX=                      # default: draugr-<repo-folder-name>
DRAUGR_MEMORY=8g                     # default: 50% of host RAM, capped at 32 GiB
DRAUGR_CPUS=                         # default: all
DRAUGR_CLONE=true                    # false = bind-mount your tree READ-WRITE. Think first.
DRAUGR_TEMPLATE=                     # custom container image
```

`DRAUGR_CLONE=false` hands the agent your actual working tree with write access. Draugr will make
you confirm it interactively every single time, because that is the setting that undoes the entire
point of the project.

`DRAUGR_AGENT_ARGS` is for the flags you would otherwise retype on every session. If you almost
always want to pick up where you left off:

```bash
DRAUGR_AGENT_ARGS="--continue"       # Claude Code
DRAUGR_AGENT_ARGS="resume --last"    # Codex — a subcommand, and it works here too
```

These are the agent's own flags, handed over uninterpreted, so the spelling is the agent's.
Now `dr-go` resumes by default, and the attach line says so. Two ways out of it for a single run:

| | |
|---|---|
| `dr-go --bare` | pass the agent **nothing** — a clean session |
| `dr-go -- --model opus` | pass these **instead** — the command line replaces the config, it does not add to it |

Replacing rather than appending is deliberate: it follows the same precedence as every other
setting, and it is the only way to *drop* a configured argument for one run. These are the agent's
own flags — `--continue` is Claude's spelling and means nothing to `shell` — so Draugr passes them
through without interpreting them.

**What the agent is allowed to reach, and what is installed for it** — a kit, not a Draugr setting

```bash
DRAUGR_KIT=.draugr/kit              # default. A directory, ZIP, git ref or OCI image.
```

Network rules and setup commands are **not** Draugr config keys. They belong to
[`sbx kit`](https://docs.docker.com/ai/sandboxes/customize/kits/), a first-party declarative format
that already does this job properly, and `dr-init` generates a starter one for you:

```yaml
# .draugr/kit/spec.yaml — commit this
schemaVersion: "2"
kind: mixin
name: myproject

caps:
  network:
    allow:
      - internal-registry.example.com   # ADDS to the defaults — see below
    deny:
      - telemetry.example.com           # deny wins over allow

commands:
  install:                          # runs once, at creation
    - command: "npm ci"
      user: "1000"
      description: Install dependencies
```

> ### Your kit is not the whole allowlist
> `sbx` ships a machine-wide policy of **~190 allow rules** — package managers, OS packages, the
> common code hosts, the AI service endpoints — applying to every sandbox. So `npm`, `pip` and
> `github.com` already work without appearing in any kit, and what you list above is *added to*
> that set rather than replacing it.
>
> Default-deny is still real: anything matching no rule anywhere is refused, with
> `no matching allow rule (default deny)`. But "deny by default" and "only what I listed" are
> different claims, and it is worth knowing which one you have. `dr-policy` shows everything in
> force with its source, `dr-policy --defaults` shows the rules you did not write, and
> `dr-policy --check <host>` answers for one host. To narrow the defaults, add a `deny` above.

This is where `npm ci`, `uv sync` and `apt-get install -y libfoo-dev` go. Commit it: it is the
difference between a teammate cloning your repo and being productive in one command, versus half an
hour of guessing. Because it is a standard kit and not a Draugr invention, it also works with plain
`sbx run --kit .draugr/kit`, and it can be published to a registry and shared across repositories.

Draugr's contribution is noticing when it changes: `dr-up` warns if the kit differs from the one the
sandbox was built with, because applying it recreates the container. `dr-kit validate` checks it
before you find out the hard way. `dr-policy --allow <host>` opens a hole in a *running* sandbox
when you need one now — treat that as temporary and graduate it into the kit.

**A library of named kits**

"The Lua toolchain" is a fact about *you*, not about one repository. `DRAUGR_KIT` is a space-separated
list, and `sbx` **merges** kits rather than choosing between them — verified: two mixins on one
sandbox contributed both their install commands and both their network rules. So a shared kit *adds*
to the project's rather than replacing it:

```bash
dr-kit save lua                  # from the repo that already has the kit you want to reuse
dr-kit list                      # what is in your library

# then in any other Lua project's .draugr.conf:
DRAUGR_KIT=".draugr/kit lua"     # its own kit, plus the shared one
```

The library lives at `DRAUGR_KIT_STORE`, `~/.config/draugr/kits` by default. That is on WSL's own
ext4, which is deliberate and worth one line of explanation: a *workspace* cannot live there, because
the microVM cannot bind-mount a path behind the Windows network redirector — but a *kit* is only read
on the host and packed, so the UNC spelling works. Measured end to end.

`save` copies rather than links, so no repo silently changes another. Editing the library copy does
put every repo using it into drift until its next `dr-kit apply` — which is the point of drift
detection rather than a flaw in it.

**Ports and extra material**

```bash
DRAUGR_PORTS="5173:5173 8080:8080"   # published to Windows loopback
DRAUGR_HOST_PORTS="11434"            # ports on THIS machine the mound may reach
DRAUGR_MOUNTS="/mnt/c/Docs/api:ro"   # extra read-only workspaces
```

A kit can declare `network.publishedPorts` too, but **a kit cannot pin the host side** — its
`PublishedPort` has no field for it, so `sbx` assigns an ephemeral port that changes on every
recreate, and the service is never twice at the same URL. Measured: `host`, `hostPort`, `published`
and `publishedPort` are all rejected as *"field not found in type spec.PublishedPort"*.

So the split is not "permanent in the kit, temporary here". Use the kit to declare that a port
exists; use `DRAUGR_PORTS` when you want it at an address you can bookmark, and `dr-ports`
mid-session for one you do not.

`DRAUGR_HOST_PORTS` is the other direction, and the more serious one: a service on *your* machine
that the agent is allowed to call — a local Ollama on the GPU being the case it was written for. It
names bare port numbers, never an address, because WSL's address is handed out per boot and cannot be
pinned; a rule written with a literal IP is right until the next reboot and then fails **closed and
silently**. `dr-up` re-resolves it on every start and drops the rules left over from addresses this
machine no longer has, so a reboot costs you nothing. `dr-hostport` is the mid-session equivalent.

> The service must be listening on `0.0.0.0` — from inside the mound, `127.0.0.1` is the mound. And
> on the far side of this hole is a process outside the sandbox: whatever the agent can reach there,
> it can use. In a project's `.draugr.conf` it takes effect only once you have accepted the file with
> `dr-trust`.

**Running the agent on your own model**

```bash
DRAUGR_MODEL="qwen3.8:27b"           # run the AGENT on this, not on its vendor's cloud
DRAUGR_MODEL_URL="11435"             # a port here (resolved per boot), or a full URL elsewhere
DRAUGR_HOST_PORTS="11435"            # required for a bare port - dr-go refuses without it
```

Note what this is *not*. `DRAUGR_HOST_PORTS` on its own lets **the code you are working on** call a
local Ollama. `DRAUGR_MODEL` changes what **the agent** is. They share a port and are otherwise
unrelated, and you may want both.

It is not about the credential — the agent's token never entered the mound anyway, because `sbx`
authenticates on the host. It changes where the agent *sends* your code. That is a smaller claim than
it sounds, and the reason is worth reading before you rely on it: a mound still carries `sbx`'s ~190
default allow rules, **the AI service endpoints among them**, so the agent can still reach the
network it always could. A local model closes the channel Draugr points it down; it does not close
the others. Making "my code does not leave this machine" true needs kit `deny` rules as well — see
[docs/SECURITY.md](docs/SECURITY.md#running-the-agent-on-a-local-model), which is honest about what
that costs you.

The default `11435` is the query-only proxy in [`share/ollama-proxy/`](share/ollama-proxy/) rather
than Ollama's own `11434`, which serves `DELETE /api/delete` through the same door as inference.
`dr-doctor` checks that what answers there really is the proxy.

Applied at attach, not at creation, so switching models is `Ctrl+D` and another `dr-go` rather than a
rebuild. Expect a model that fits on one GPU to be noticeably worse at long tool chains than the
hosted one: this is a tier for work that cannot leave the building, not a cheaper way to do the same
work. See [docs/CONFIG.md](docs/CONFIG.md#running-the-agent-on-a-local-model).

**Data files that are not ready to commit** — see [Working with data files](#working-with-data-files)

```bash
DRAUGR_DATA="tmp/** *.parquet scratch/raw/"   # repo-relative globs
DRAUGR_DATA_PUSH=auto                # auto|manual|off   host → sandbox, before the agent starts
DRAUGR_DATA_PULL=manual              # auto|manual|off   sandbox → host, when you detach
DRAUGR_DATA_DELETE=false             # propagate deletions (rsync --delete)
DRAUGR_DATA_CHMOD=D755,F644          # /mnt/c is mode 777 under WSL; normalise on the way in
```

**Git behaviour**

```bash
DRAUGR_BRANCH=main
DRAUGR_REMOTE=draugr                 # name of the git remote pointing at the sandbox
DRAUGR_REQUIRE_CLEAN=true            # refuse dr-go with a dirty tree — the clone only sees commits
DRAUGR_AUTO_SYNC=true                # dr-sync automatically when you detach
```

`DRAUGR_REQUIRE_CLEAN` catches the single most common beginner mistake: the sandbox clones
*committed history only*, so uncommitted work simply is not there and the agent quietly works from
stale code. **Paths matching `DRAUGR_DATA` are exempt from the check** — they are handled by a
different mechanism and are never expected to be committed.

**Directories that are not repositories**

```bash
DRAUGR_ON_MISSING_REPO=fail          # fail|create-add-all|create-data-only
```

`sbx --clone` requires a git repository, and clone mode is what makes the host tree read-only — so
by default Draugr refuses a plain directory rather than quietly falling back to something less safe.
The two other values let it create the repository for you, and they are for different situations:

| | |
|---|---|
| `create-add-all` | *"this is a code project I forgot to `git init`."* Commits what is there and hands you an ordinary repo — including the dirty-tree check on every session after. Credential-shaped names and `DRAUGR_DATA` patterns are gitignored first, never committed. |
| `create-data-only` | *"this is not a code project."* Creates a repo whose `.gitignore` is a single `*`, so git tracks nothing and `git status` is empty forever. Your files travel by `dr-data` instead, and `DRAUGR_DATA="*"` is written for you. |

The second is the one to use for a folder of documents or data. Nothing is ever committed, so the
dirty-tree check can never fire and there is no commit-before-each-session discipline to remember —
but you also give up `dr-diff` and `dr-merge`, because there are no commits to compare. Review means
`dr-data status` for which files differ and `dr-data diff` for what changed inside them — a real
unified diff for text files, names and sizes for binaries and anything over
[`DRAUGR_DATA_DIFF_MAX`](docs/CONFIG.md#draugr_data_diff_max).

Only `dr-init` and `dr-up` will create a repository. `dr-status`, `dr-scan` and the rest still
refuse, for the same reason `dr-status` will not start a stopped mound: a command you run to find
out what is going on must not change what is going on.

> Creating a repository in a directory writes real files into it — `.git/`, a `.gitignore`, and a
> `.draugr.conf`. That is why the default is `fail`: it should be something you asked for.

**Memory**

```bash
DRAUGR_MEM_SYNC=auto                 # auto|manual|off
DRAUGR_MEM_STORE=~/.local/share/draugr/memory
```

`auto` imports on `dr-up` and exports when you leave the agent. `manual` does neither, but `dr-rm`
still refuses to destroy unexported memory and `dr-status` still reports it. `off` means you do not
keep agent memory at all: no transfers, no refusal, no memory section.

The store may live anywhere, including WSL's own filesystem as above — Draugr stages transfers
through the repo because `sbx cp` is a Windows binary that will not write to a WSL path.

**Safety rails**

```bash
DRAUGR_SCAN=true
DRAUGR_SCAN_PATTERNS=".env *.pem *.key id_rsa credentials.json secrets.*"
DRAUGR_SCAN_FAIL=block               # warn|block
```

See [Safety model](#safety-model) — this one matters more than it looks.

**Hooks**, if the config keys are not enough: executable scripts at
`.draugr/hooks/{pre-up,post-up,post-create,pre-attach,post-attach,post-sync,pre-rm}`. They run on
the *host* (WSL) with the merged config in the environment — which is precisely what a kit's
commands cannot do, since a kit runs inside the mound and cannot see your machine. A hook that
exits non-zero aborts the command, so they can veto.

`post-create` fires only when a sandbox is actually built; `post-up` fires on every `dr-up`,
including the ones that just start a stopped mound.

---

## Commands

Every command is its own small bash script under `bin/`, even the one-liners. That is deliberate:
you can read any single behaviour without reading a framework, override one by putting your own
earlier on `PATH`, and call them from Makefiles and other scripts. `dr <verb>` is a dispatcher for
`dr-<verb>` if you prefer a single entry point.

### Lifecycle

| Command | |
|---|---|
| `dr-init` | Write a starter `.draugr.conf` into this repo |
| `dr-up` | Create-or-start the mound: kit, ports, memory. Idempotent, no attach |
| `dr-go` | `dr-up`, then attach and launch the agent — **the command you run every day** |
| `dr-shell` | An extra shell in the mound, alongside the running agent |
| `dr-status` | This repo: sandbox state, unfetched commits, dirty tree, unexported memory |
| `dr-ls` | All Draugr mounds on this machine |
| `dr-stop` | Shut down. Filesystem, login and memory all survive |
| `dr-rm` | **Destroy.** Refuses unless commits are synced and memory exported (`--force` to override) |

### Moving code

| Command | |
|---|---|
| `dr-sync` | Fetch the agent's commits onto `draugr/<branch>` |
| `dr-log` | What is new that you have not seen |
| `dr-diff` | Review it properly |
| `dr-merge` | Accept it (merge, or `--pick <sha>` to cherry-pick) |
| `dr-send` | Push *your* new host commits into the running sandbox |
| `dr-cp` | Pull uncommitted files out of the sandbox |

`dr-sync` uses git's `ssh://` transport, not the `git://` daemon. The daemon is published on
Windows loopback only, which WSL cannot reach across its NAT, and its port is randomised on every
start. `ssh://` needs no port, crosses no NAT, and starts a stopped sandbox by itself.

### Moving data

| Command | |
|---|---|
| `dr-data status` | Dry run, both directions: what would move, and how much |
| `dr-data diff` | What a pull would **change**, as a real diff where it can |
| `dr-data push` | Host → sandbox, for paths matching `DRAUGR_DATA` |
| `dr-data pull` | Sandbox → host, same paths |

### Context

| Command | |
|---|---|
| `dr-mem status` | Where memory is on each side, and how much of it |
| `dr-mem export` | Sandbox memory → `$DRAUGR_MEM_STORE`. Do this before `dr-rm` |
| `dr-mem import` | Store → sandbox. Do this *before* launching the agent |
| `dr-mem import --from-host` | The agent's own memory on your host → sandbox — the migration |
| `dr-mem diff` | What each side knows that the other does not |
| `dr-mem check` | Would `dr-rm` lose memory? For scripts: `0` no, `1` yes, `2` unreachable |
| `dr-skills list` | What is in the shared skills store, and whether it can be declined |
| `dr-skills diff` | What has appeared or changed in it since you last accepted |
| `dr-skills accept` | Record the store's current contents as reviewed |
| `dr-skills import` | Seed the store from your own host skill directories |
| `dr-skills install` | Put Draugr's own skills into the store, so agents can use them |
| `dr-plugin` | What the plugin library holds, and whether your mounds are pointed at it |
| `dr-plugin add <owner>/<repo>` | Register the **marketplace** and install every plugin it lists |
| `dr-plugin add <owner>/<repo> <plugin>…` | The same, but install only the plugins you name |
| `dr-plugin update` | Refresh the catalogues and the plugins |
| `dr-plugin remove <plugin>@<mkt>` | Uninstall, deregister, disable — and actually reclaim the space |
| `dr-plugin enable` / `disable` | The switch only. No mound, instant |
| `dr-plugin clean` | Drop superseded versions, which nothing else reaps |
| `dr-plugin rollback` | Swap back to the previous library |

A plugin is **code that runs** — hooks, MCP servers, `bin/` on the Bash tool's `PATH` — so it is
never installed on your host. `dr-plugin` builds the library inside a mound it throws away, and your
host only ever stores the result, mounted back read-only. Set `DRAUGR_PLUGIN_STORE`, then run
`dr-plugin` with no arguments: it prints the rest. See [docs/CLAUDE_PLUGINS.md](docs/CLAUDE_PLUGINS.md).

`dr-mem import` refuses to run unattended against a store Draugr did not write itself. Its own
export carries a marker naming the repo; anything else is somebody's instructions and gets a
prompt. With `DRAUGR_MEM_SYNC=auto` the import happens on `dr-up` and the export on detach — the
import only ever fills a mound that has *no* memory, since the store is by definition the older
copy and must never overwrite what the agent has learned since.

> ### The project-key trap, handled
> Claude Code derives its memory folder name from the project's **absolute path**, so the same
> repository has a different key on every side of the boundary:
>
> | Where you ran the agent | Path | Project key |
> |---|---|---|
> | Windows | `C:\src\myproject` | `c--src-myproject` |
> | WSL | `/mnt/c/src/myproject` | `-mnt-c-src-myproject` |
> | Sandbox | `/c/src/myproject` | `-c-src-myproject` |
>
> Copy the folder across without translating and you get a directory the agent silently never
> reads — no error, no warning, just an agent that has forgotten everything. `dr-mem` translates.
> It also fixes ownership afterwards, because `sbx cp` lands files as `root:root` while the agent
> runs as uid 1000 and would be unable to write new memories.

**Memory is the one thing that differs per agent**, so it lives in `lib/agents/<agent>.sh` — one
file each, and `lib/agents/default.sh` for an agent nobody has measured. Codex is a different shape
entirely: not filed per project, half markdown and half SQLite, and off until you enable it. The
same four commands cover it. Everything else — attaching, Ctrl+Z, the clone, kits, `dr-sync`,
`dr-send`, `dr-data` — never knew which agent was in the mound and still does not. See
[docs/WORKFLOW.md](docs/WORKFLOW.md#memory).

Both agents also read an instruction file from the repo — `AGENTS.md` for Codex, `CLAUDE.md` for
Claude Code — and those need nothing from Draugr: they are committed files, so they arrive with the
clone and come back through `dr-sync` like any other change. Prefer them for rules that must always
apply, and let memory be memory.

### Operations

| Command | |
|---|---|
| `dr-doctor` | Check every precondition and say exactly what to fix |
| `dr-config` | The merged config, with the origin of each value |
| `dr-scan` | Find credential-shaped files the agent would be able to read |
| `dr-kit` | `validate`, `show`, `apply` this project's kits — and warn when they have drifted |
| `dr-kit save`/`list` | keep a library of named kits, shared across repositories |
| `dr-policy` | Show the network rules in force; `--allow <host>` for a temporary hole |
| `dr-ports` | Publish a port to an already-running sandbox |
| `dr-hostport` | Let the mound reach a port on *this* machine, at whatever address it has today |
| `dr-code` | Open VS Code Remote-SSH into the mound, on the agent's clone |
| `dr-trust` | Accept a project config after reviewing it |

---

## Working with data files

Git is the right channel for source and the wrong channel for a half-processed 4 GB parquet file.
If your work involves data you are actively churning through and do not want in history until it is
valid, `DRAUGR_DATA` gives you a second channel that runs alongside git instead of through it.

```bash
# .draugr.conf
DRAUGR_DATA="tmp/** *.parquet scratch/raw/"
DRAUGR_DATA_PUSH=auto        # dr-up pushes before the agent starts
DRAUGR_DATA_PULL=manual      # you run dr-data pull when you want results back
```

Matching paths are transferred with `rsync` over the same `ssh://` transport `dr-sync` uses, and
land at the **same repo-relative path** inside the agent's clone — so a script that reads
`tmp/raw/2024.parquet` works unchanged on both sides. Four consequences worth having in mind:

- **They are exempt from `DRAUGR_REQUIRE_CLEAN`.** Data churn will not stop you starting a session.
- **Keep them gitignored.** Then they are ignored in the agent's clone too (`.gitignore` is
  committed, so both sides agree) and the agent will not accidentally commit 4 GB of scratch.
- **The delta algorithm survives the boundary.** Measured: appending 21 bytes to a 3 MB file put
  **375 bytes** on the wire on the next push. The first transfer of a large tree is expensive; every
  one after it is close to free.
- **Files land owned by `agent`, ready to write.** This is the reason rsync-over-ssh is the
  transport rather than `sbx cp` — `sbx cp` writes as `root:root`, which the agent (uid 1000) can
  read but never modify, so generated output would fail in ways that look like a broken script
  rather than a permissions problem.

> ### Direction is explicit, and that is on purpose
> Draugr will move data automatically, but only ever **one direction at a time**. There is no merge
> algorithm for a parquet file: if both sides changed it, any bidirectional sync silently picks a
> winner and destroys the other version. So each transfer declares a source of truth — `push` means
> the host wins, `pull` means the sandbox wins — and `dr-data status` shows a dry run of both before
> you commit to either.
>
> `DRAUGR_DATA_DELETE=false` is the default for the same reason: without it, a `push` after you
> tidied a directory on the host would delete the agent's newly generated output.

Two things are less simple than they look. **rsync has to exist inside the mound** — it is present
in the `claude` image (verified: `/usr/bin/rsync`), but that is not a guarantee across every agent
image, so `dr-up` installs it at creation if missing (`sudo -n apt-get install -y rsync`; the agent
user has passwordless sudo) and falls back to `tar` over ssh, which is always present but whole-file
rather than incremental. And **the first transfer is not free**: pushing tens of gigabytes into a
microVM is a real wait, and by default it happens inside `dr-up` at the moment you were expecting a
prompt. That is what `dr-data status` is for, and why `DRAUGR_DATA_PUSH=manual` exists.

One cosmetic wrinkle: files on `/mnt/c` are mode 777 under WSL, so a naive push carries that into
the mound. Draugr normalises with `--chmod=D755,F644` unless you set `DRAUGR_DATA_CHMOD`.

**If the agent only ever reads the data, do not use this.** Mount it read-only instead —
`DRAUGR_MOUNTS="/mnt/c/data:ro"` — and it appears in the sandbox with no copy, no transfer time and
no chance of the agent modifying your originals. `DRAUGR_DATA` is for data the agent writes back,
or data that must sit at a specific path inside the working tree.

---

## Safety model

What the agent can and cannot see, verified by direct test:

| | |
|---|---|
| Agent's clone contains committed history | yes |
| Agent's clone contains your uncommitted changes | **no** |
| Your working tree readable at `/run/sandbox/source` | **yes** |
| Writing to `/run/sandbox/source` | **blocked** — read-only filesystem |
| `.gitignore`d files present in the clone | no |
| `.gitignore`d files readable via `/run/sandbox/source` | **yes** |
| Anything outside the workspace — other repos, SSH keys, browser profiles | unreachable |
| Host directories mounted into the mound at all | **exactly four** |
| …of those, writable from inside | **one** — the shared skills store |

Only four host paths cross the boundary: your working tree at `/run/sandbox/source` (read-only),
`/etc/resolv.conf` and `/etc/hosts` (read-only), and `~/.claude/skills` — which is **read-write**.
`/mnt/c`, `/c/Users`, your other repositories and your host SSH keys are all simply absent.

Two things in that table are worth stopping on, because both are the *opposite* of what the summary
above would lead you to expect.

> ### Trap 1 — what the agent can read
> **`.gitignore` hides files from git, not from the filesystem.** An untracked `.env`,
> `secrets.env` or `credentials.json` sitting in your project folder is fully readable by the agent
> through the read-only mount, even though it is absent from the agent's clone. It cannot be
> modified — but it can be read, and therefore sent anywhere the network policy allows.
>
> This is what `dr-scan` is for, and why `DRAUGR_SCAN_FAIL=block` is the default. Real credentials
> do not belong in a directory you hand to an agent.

And the mirror image — not what the agent can read, but what it can write:

> ### Trap 2 — the skills store is a writable door out
> `~/.claude/skills` is mounted **read-write** from the host — it lives at
> `…\DockerSandboxes\sandboxes\state\agent-skills\` and is deliberately shared, so that skills
> survive `sbx rm` and are available to every sandbox. Verified by direct test: a file written
> inside the mound appeared on the host immediately.
>
> That is a useful feature and a real consequence. It is the one path by which a sandbox can put
> bytes on your machine, it is **shared across all your mounds**, and it **outlives the sandbox that
> wrote it**. Since skills are instructions loaded into agent context, a sandbox can in principle
> leave something behind that a later, unrelated sandbox reads and follows.
>
> Nothing here is broken — it is how `sbx skills` is designed to work. But "the sandbox cannot write
> to the host" is too strong a sentence, and this is the exception. `dr-skills` treats the store as a
> reviewable artifact rather than a dumping ground: `dr-skills accept` records what is there,
> `dr-skills diff` reports anything that has appeared or changed since, and `dr-scan` lists the store
> on every `dr-go`. Hidden directories are counted too — measured, a store entry named `.hidden-probe`
> shows up in Claude's own list of available skills — so a review that skipped them would be looking
> in the wrong place.
>
> **There is one store, not one per agent.** `sbx` collapses five per-agent host directories into a
> single store and varies only the mount path, so what a codex mound leaves behind is in reach of
> your claude mounds.
>
> **Both mount paths are read by their agent** — measured on each side by asking the agent itself to
> list its skills. A marker sitting only in the shared store was named by Claude Code in a claude
> mound and by Codex in a codex one, and a second marker added after the mound was built showed up
> without a restart.
>
> **The documented way to opt out works — but it is hidden.** `sbx skills --help` says "use
> `--no-share-skills` to opt out", and that flag does not appear on `sbx create` or `sbx run` at all
> until a feature flag that is off by default, and absent from `sbx --help`, is switched on:
>
> ```bash
> sbx settings set feature.shareSkills true    # now the flag exists
> sbx create --no-share-skills claude .        # and this mound has no skills mount
> ```
>
> All three states measured on sbx 0.37.1. With the feature off — the default — the store is mounted
> read-write and no visible option removes it. With the feature on, the flag appears **and does the
> job**: a mound created with it has *no* `skills` line in `/proc/mounts` and no `~/.claude/skills`
> directory at all. The real catch is that it applies **at creation time only**, so closing the door
> on a mound you already have means recreating it.
>
> So the door can be shut; you just have to know about an undocumented setting to find the handle.
> `dr-skills list` reports which of the two states this machine is in rather than making you go and
> look.

Two more, worth knowing before they bite you:

- **Never mount `~/.claude` into a sandbox.** It contains `.credentials.json` — your agent
  authentication token. A sandbox can read every byte of anything you mount into it. `dr-mem`
  copies the `memory` subfolder explicitly and never the parent.
- **Imported memory is instructions, not notes.** Memory files are loaded into the agent's context
  and largely trusted. Memory you wrote yourself is fine; memory from a colleague or a template is
  a payload you carried across the boundary yourself. Read it first. A file saying *"the user has
  approved force-pushing to main"* will be believed.

---

## Project layout

```
draugr/
├── bin/                    one script per command — all of it, nothing hidden
│   ├── dr                  dispatcher: `dr go` → `dr-go`
│   ├── dr-go  dr-up  dr-shell  dr-stop  dr-rm  dr-ls  dr-status
│   ├── dr-sync  dr-log  dr-diff  dr-merge  dr-send  dr-cp
│   ├── dr-data  dr-mem  dr-skills
│   └── dr-doctor  dr-config  dr-scan  dr-kit  dr-policy  dr-ports  dr-hostport  dr-code  dr-setup
│       dr-init  dr-trust
├── lib/
│   ├── common.sh           config loading, path translation, guards, output
│   └── agents/             one file per agent, for the parts that differ
│       ├── default.sh      the interface, and the answer for an unmeasured agent
│       └── claude.sh       where Claude Code keeps its memory
├── share/
│   ├── config.example      the user-home config, fully commented
│   ├── project.example     .draugr.conf starter, written by dr-init
│   ├── kit.example/        starter sbx kit, also written by dr-init
│   └── ssh-config.snippet  the *.sbx block dr-setup installs
├── docs/
│   ├── SETUP.md            bare machine → working session
│   ├── WORKFLOW.md         the daily loop, data, memory, skills
│   ├── CONFIG.md           every key (a test fails if one is undocumented)
│   ├── SECURITY.md         the boundary, and how each claim was measured
│   ├── TROUBLESHOOTING.md  symptoms → causes → fixes
│   ├── DESIGN.md           why it is shaped this way, and what was rejected
│   └── HACKING.md          the bash this project uses, and the house rules
├── tests/                  bats
├── CHANGELOG.md
└── install.sh
```

---

## Design notes

**Why bash, and why one script per command.** The whole thing is a workflow over an existing CLI.
A binary would need a release pipeline; a Python package would need an interpreter inside a project
that may not want one. Bash is already there, in the shell where the work happens. Splitting it one
script per verb keeps each file small enough to read in full before you trust it — which, for a tool
whose entire premise is containment, is the point.

**Why shell-syntax config instead of TOML/YAML.** No parser dependency, comments are free, and the
config can compute values (`DRAUGR_PORTS="$(cat .ports)"`). The cost is that sourcing a repo's
config executes its code, which is why trust-on-first-use exists.

**Why `sbx` specifically.** It is the only option on Windows that gives a genuine kernel boundary
without Docker Desktop, and its clone mode already implements exactly the read-only-host,
private-clone shape this workflow wants. Draugr does not abstract over it — the backend is visible
in the docs, and `sbx` commands keep working alongside `dr-*` ones.

**Why network rules and setup live in a kit rather than in `.draugr.conf`.** Because `sbx kit`
already does it, declaratively, versioned, and shareable beyond this tool. A Draugr-shaped
reimplementation would be a worse copy that only worked here, and it would have missed things kits
already handle — credentials brokered through a host-side proxy so the secret never enters the
microVM, for one. The rule Draugr follows: **kits configure the inside of the mound, Draugr
configures the boundary.** Anything a kit can express is a kit's job. What is left is what a kit
structurally cannot see — your WSL paths, your git remotes, your working tree, your machine's
memory store — and that is exactly Draugr's config surface.

**Why not just aliases.** Because the interesting part is not shortening commands, it is the
preflight checks, the path translation, the credential scan and the refusal to do destructive
things with unsynced work in the mound.

---

## License

MIT.

---

*Draugr is not affiliated with Docker, Inc. or Anthropic. "Docker Sandboxes" and "Claude Code" are
their respective owners' names for their own products.*
