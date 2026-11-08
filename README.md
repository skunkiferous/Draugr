# Draugr

**Bind your coding agent to a mound that it cannot leave.**

Draugr is a small workflow layer, controlled by configuration files. It runs Claude Code (or
Codex, Gemini, Copilot, …) inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/)
microVM, and you control it from a WSL shell. The agent gets its own kernel, its own Docker
daemon, and a private clone of one repository. It cannot touch your Windows drive, your SSH keys,
your other projects, or your credentials. Thus you can stop the approval of each command, and let
it work.

In Norse folklore, a *draugr* is an undead creature that guards its burial mound. It is very
strong, and it never leaves. Draugr works the same way: the agent is strong inside the mound, and
has no reach outside it.

Draugr can also use a Windows VM. A mound is Linux, so an agent in it can write Windows code, but
cannot compile or run it. The *forge* fills that gap. It is a Windows 11 VM on the host, which a
mound controls through [AppSandbox](https://github.com/jamesstringer90/appsandbox). It has no
network adapter of its own, and one filtered way out. Use it to build Windows software, or to run
something that you do not want on your host, for example an unknown mod from GitHub. It is **off
unless `DRAUGR_FORGE` names a VM**. Thus a machine that needs no forge works as before. Refer to
[docs/FORGE.md](docs/FORGE.md).

**WARNING:** [Claude Code](https://claude.ai) "vibe-coded" this full project.

> **Status: 0.6.0, ready to use.** Each command in the tables below exists and has tests. The
> mechanics were tested with `sbx` v0.37.1 on Windows 11 + WSL2. Only its author used it until now, so
> expect rough edges in the places that nobody tried.
>
> This file is the specification. It was written before the code. If the two do not agree, the
> code has the bug.

## Documentation

| | |
|---|---|
| [docs/SETUP.md](docs/SETUP.md) | From a bare machine to a working session |
| [docs/WORKFLOW.md](docs/WORKFLOW.md) | The daily loop, review, data, memory, skills |
| [docs/CONFIG.md](docs/CONFIG.md) | Each `DRAUGR_*` key, and what happens if you get it wrong |
| [docs/CLAUDE_PLUGINS.md](docs/CLAUDE_PLUGINS.md) | Claude Code plugins in a mound, with no install on your host |
| [docs/FORGE.md](docs/FORGE.md) | The optional Windows VM: what it is for, and the boundary that it keeps |
| [docs/SECURITY.md](docs/SECURITY.md) | What the agent can and cannot reach, and how we measured it |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptoms, causes, fixes |
| [docs/DESIGN.md](docs/DESIGN.md) | Why it has this shape, with the rejected alternatives |
| [docs/HACKING.md](docs/HACKING.md) | **Start here if you read the source**, not with a script |
| [CHANGELOG.md](CHANGELOG.md) | What changed, and when |

---

## Why this exists

An agent with `--dangerously-skip-permissions` on your real machine is fast and reckless. The
approval of each tool call is safe and slow. Draugr takes a third option. It makes the possible
damage so small that "let it run" is the *responsible* choice.

`sbx` already gives the isolation, but not a workflow. Without Draugr, you build git remotes by
hand. You must remember that WSL cannot reach the git daemon. Agent memory is under a key that
comes from the path, and the key is different on the host and in the sandbox. You type five
commands in each session. Draugr is the missing layer: **a layered configuration, a kit for each
project, and a set of `dr-*` scripts that each do one thing.**

---

## The daily loop

This is all of it: five commands, from one WSL terminal.

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

`dr-go` is idempotent (safe to run again), and does all that a session needs. It makes sure that
the daemon runs, and scans for credentials that the agent must not see. If the sandbox is missing,
it creates it, with the kit of your project. The kit holds the network rules and setup commands.
Then `dr-go` imports your agent memory, and starts the agent. On a second run, it only attaches.

**Ctrl+Z works.** It suspends the agent, and gives you a prompt inside the mound, in the clone.
`fg` takes you back. One window, and no second connection. That is why Draugr runs in WSL, and
attaches over ssh, not through `sbx.exe`. Refer to [`DRAUGR_ATTACH`](docs/CONFIG.md#draugr_attach).

---

## The mental model

You have **three** repositories. All else follows from that.

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

1. **Only you talk to the remote.** The sandbox has no credentials, and no route to it.
2. **The sandbox cannot write to your repository.** The kernel makes that mount read-only. It is
   not only a convention. But other host directories are also mounted. Refer to
   [Safety model](#safety-model) for the one writable exception, which is not your project.
3. **You pull *from* the sandbox.** It never pushes to you.

Treat the agent as a colleague who gives you a branch. Fetch it, review it, merge it, and push it
yourself.

**Draugr works with all git hosts.** Draugr never touches your `origin`. It only adds a second
remote that points at the sandbox. GitHub, GitLab, Gitea, Forgejo, Bitbucket, a bare repo on a
NAS, or no remote: all work the same. Draugr needs only one thing from your project: it must be a
git repository.

---

## Requirements

| | |
|---|---|
| Windows 11 Pro, x86_64 | Hypervisor Platform feature enabled |
| WSL2 | Draugr runs here. Ubuntu tested. |
| `sbx` ≥ 0.37 | `winget install Docker.sbx`. Docker Desktop is **not** necessary. |
| git ≥ 2.40 | on both sides |
| A repo **on a Windows drive** | refer to the next section |
> ### Your repo must live under `/mnt/<drive>/…`
> `sbx.exe` is a Windows binary, and its workspaces are Windows paths. A repository on the ext4
> filesystem of WSL (`~/code/myproject`) has no usable host path. Thus Draugr refuses it with a
> clear error, and does not fail in a strange way later. Keep sandboxed projects on `C:` (or any
> Windows drive), and work on them from WSL through `/mnt/c/…`.
>
> The only cost: WSL reaches `/mnt/c` through a translation layer. Thus the git operations that
> Draugr runs from WSL (`status`, `diff`, `fetch`) are slower on a large repo than on ext4. From
> Windows, the same files are native NTFS, with no extra cost. Thus a Windows editor or `git.exe`
> is not affected. The clone of the agent is on ext4 *inside* the microVM, so the compile side is
> not affected either.
>
> **A `subst` drive does not solve this.** If you map `W:` to `\\wsl.localhost\Ubuntu\home\me`, a
> WSL directory gets a path that looks like Windows. `sbx` even creates a *bind-mount* sandbox on
> it. But `--clone` fails, and the full project rests on that mode. git resolves the drive back to
> the UNC path, and rejects it for dubious ownership. If you allow that, the container refuses to
> start. The microVM cannot bind-mount a path behind the Windows network redirector. We measured
> this end to end. The full sequence is in
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

People often forget `dr-setup`. `sbx setup ssh` sets up only the **Windows** SSH client. WSL has
its own `~/.ssh/config`. Without the matching block, neither `ssh <name>.sbx` nor the `ssh://` git
transport works from WSL. `dr-setup` writes it, with your Windows username in it.

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
| `~/.config/draugr/config` | each project on this machine | n/a |
| `<repo>/.draugr.conf` | this project, shared with the team | **yes** |
| `<repo>/.draugr.local.conf` | this project, only you | no, add it to .gitignore |

The order, from lowest to highest:

```
built-in defaults  →  user config  →  project config  →  project-local  →  DRAUGR_* env  →  flags
```

`dr-config` prints the merged result, with the origin of each value. Thus one command always
answers "why does it do that".

> ### `.draugr.conf` is executed, so you trust it on first use
> To source a file from a cloned repository is to run its code. When you first accept a project
> configuration, Draugr records its hash in `~/.config/draugr/trusted`. Draugr refuses to source a
> new configuration until you run `dr-trust`. If you edit your own configuration, Draugr asks once
> again. Your shell makes the same deal with `direnv`, for the same reason.

### What you will want to change

**The agent, and the size of the mound**

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

`DRAUGR_CLONE=false` gives the agent your real working tree, with write access. Each time, Draugr
asks you to confirm it, because that value removes the full purpose of the project.

`DRAUGR_AGENT_ARGS` holds the flags that you otherwise type in each session. If you usually want to
continue where you stopped:

```bash
DRAUGR_AGENT_ARGS="--continue"       # Claude Code
DRAUGR_AGENT_ARGS="resume --last"    # Codex — a subcommand, and it works here too
```

These are the flags of the agent, so the agent sets their spelling. Now `dr-go` continues by
default, and the attach line says so. For one run, you have two ways out:

| | |
|---|---|
| `dr-go --bare` | pass the agent **nothing**: a clean session |
| `dr-go -- --model opus` | pass these **instead**: the command line replaces the configuration, and does not add to it |

The replacement is on purpose. It follows the same order as all other values, and it is the only
way to *drop* a configured argument for one run. Draugr does not interpret these flags.
`--continue` is the spelling of Claude, and means nothing to `shell`.

**What the agent can reach, and what is installed for it**: a kit, not a Draugr value

```bash
DRAUGR_KIT=.draugr/kit              # default. A directory, ZIP, git ref or OCI image.
```

Network rules and setup commands are **not** Draugr configuration keys. They belong to
[`sbx kit`](https://docs.docker.com/ai/sandboxes/customize/kits/), a declarative format from
Docker that already does this job well. `dr-init` makes a starter kit for you:

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

> ### Your kit is not the full allowlist
> `sbx` has a machine policy of **~190 allow rules**, for each sandbox. They cover package
> managers, OS packages, the common code hosts, and the AI service endpoints. Thus `npm`, `pip`
> and `github.com` already work with no kit. What you list above is *added to* that set. It does
> not replace it.
>
> Default-deny is still real. A host that matches no rule is refused, with
> `no matching allow rule (default deny)`. But "deny by default" and "only what I listed" are
> different claims. Know which one you have. `dr-policy` shows all rules in force, with their
> source. `dr-policy --defaults` shows the rules that you did not write. `dr-policy --check <host>`
> answers for one host. To narrow the defaults, add a `deny` above.

Put `npm ci`, `uv sync` and `apt-get install -y libfoo-dev` here, and commit it. With it, a
teammate clones your repo and works after one command. Without it, they guess for half an hour. It
is a standard kit, not a Draugr format. Thus it also works with plain `sbx run --kit .draugr/kit`.
You can also publish it to a registry, and share it between repositories.

Draugr sees when the kit changes. `dr-up` warns if the kit is different from the kit of the
sandbox, because an apply recreates the container. `dr-kit validate` tests it before it fails.
If you need a host now, `dr-policy --allow <host>` opens a hole in a *running* sandbox. Use that
only for a short time, then move the host into the kit.

**A library of named kits**
"The Lua toolchain" is a fact about *you*, not about one repository. `DRAUGR_KIT` is a list,
separated by spaces. `sbx` **merges** the kits, and does not select one. A test showed this: two
mixins on one sandbox gave both their install commands and both their network rules. Thus a shared
kit *adds* to the kit of the project, and does not replace it:

```bash
dr-kit save lua                  # from the repo that already has the kit you want to reuse
dr-kit list                      # what is in your library

# then in any other Lua project's .draugr.conf:
DRAUGR_KIT=".draugr/kit lua"     # its own kit, plus the shared one
```

The library is at `DRAUGR_KIT_STORE`, by default `~/.config/draugr/kits`. That is on the ext4 of
WSL, on purpose. A *workspace* cannot be there, because the microVM cannot bind-mount a path behind
the Windows network redirector. But the host only reads and packs a *kit*, so the UNC spelling
works. We measured this end to end.

`save` copies, and does not link, so no repo silently changes another. But if you edit the library
copy, each repo that uses it shows drift until `dr-up --recreate` rebuilds it. That is the purpose
of drift detection, not a fault in it.

**Ports and extra material**

```bash
DRAUGR_PORTS="5173:5173 8080:8080"   # published to Windows loopback
DRAUGR_HOST_PORTS="11434"            # ports on THIS machine the mound may reach
DRAUGR_MOUNTS="/mnt/c/Docs/api:ro"   # extra read-only workspaces
```

A kit can also declare `network.publishedPorts`, but **a kit cannot set the host side**. Its
`PublishedPort` has no field for it. Thus `sbx` gives a random port that changes on each recreate,
and the service is never twice at the same URL. Measured: `host`, `hostPort`, `published` and
`publishedPort` are all rejected as *"field not found in type spec.PublishedPort"*.

Thus the split is not "permanent in the kit, temporary here". Use the kit to declare that a port
exists. Use `DRAUGR_PORTS` for a port at an address that you can bookmark. Use `dr-ports` during a
session for a port that you do not need to bookmark.

`DRAUGR_HOST_PORTS` is the other direction, and the more serious one. It is a service on *your*
machine that the agent can call, for example a local Ollama on the GPU. It names only port
numbers, never an address. WSL gets a new address at each boot, so you cannot set it. A rule with
a literal IP works until the next reboot. Then it fails **closed and silently**. `dr-up` resolves
it again on each start, and removes the rules for old addresses of this machine. Thus a reboot
costs you nothing. `dr-hostport` does the same during a session.

> The service must listen on `0.0.0.0`. Inside the mound, `127.0.0.1` is the mound. And on the far
> side of this hole is a process outside the sandbox. The agent can use all that it can reach
> there. In the `.draugr.conf` of a project, it applies only after you accept the file with
> `dr-trust`.

**The agent on your own model**

```bash
DRAUGR_MODEL="qwen3.8:27b"           # run the AGENT on this, not on its vendor's cloud
DRAUGR_MODEL_URL="11435"             # a port here (resolved per boot), or a full URL elsewhere
DRAUGR_HOST_PORTS="11435"            # required for a bare port - dr-go refuses without it
```

Know what this is *not*. `DRAUGR_HOST_PORTS` alone lets **the code that you work on** call a local
Ollama. `DRAUGR_MODEL` changes what **the agent** is. They share a port, but are not otherwise
related. You can want both.

It is not about the credential. The token of the agent never entered the mound, because `sbx`
authenticates on the host. It changes where the agent *sends* your code. That claim is smaller
than it sounds. Read the reason before you trust it. A mound still has the ~190 default allow
rules of `sbx`, **with the AI service endpoints**. Thus the agent can still reach the same network
as before. A local model closes the channel that Draugr sends it to. It does not close the others.
For "my code does not leave this machine", you also need kit `deny` rules. Refer to
[docs/SECURITY.md](docs/SECURITY.md#running-the-agent-on-a-local-model), which gives the cost.

The default `11435` is the query-only proxy in [`share/ollama-proxy/`](share/ollama-proxy/), not
the `11434` of Ollama. `11434` serves `DELETE /api/delete` through the same door as inference.
`dr-doctor` makes sure that the proxy really answers there.

It applies at attach, not at creation. Thus to change models, press `Ctrl+D` and run `dr-go`
again, with no rebuild. A model that fits on one GPU is clearly worse at long tool chains than the
hosted one. Use this level for work that cannot leave the building. It is not a cheaper way to do
the same work. Refer to [docs/CONFIG.md](docs/CONFIG.md#running-the-agent-on-a-local-model).

**Data files that are not ready to commit**: refer to [Working with data files](#working-with-data-files)

```bash
DRAUGR_DATA="tmp/** *.parquet scratch/raw/"   # repo-relative globs
DRAUGR_DATA_PUSH=auto                # auto|manual|off   host → sandbox, before the agent starts
DRAUGR_DATA_PULL=manual              # auto|manual|off   sandbox → host, when you detach
DRAUGR_DATA_DELETE=false             # propagate deletions (rsync --delete)
DRAUGR_DATA_CHMOD=D755,F644          # /mnt/c is mode 777 under WSL; normalise on the way in
```

**Git behavior**

```bash
DRAUGR_BRANCH=main
DRAUGR_REMOTE=draugr                 # name of the git remote pointing at the sandbox
DRAUGR_REQUIRE_CLEAN=true            # refuse dr-go with a dirty tree — the clone only sees commits
DRAUGR_AUTO_SYNC=true                # dr-sync automatically when you detach
```

`DRAUGR_REQUIRE_CLEAN` stops the most common beginner mistake. The sandbox clones *only the
committed history*. Thus uncommitted work is not there, and the agent silently works from old code.
**Paths that match `DRAUGR_DATA` are exempt from this test.** A different mechanism handles them,
and you never commit them.

**Directories that are not repositories**

```bash
DRAUGR_ON_MISSING_REPO=fail          # fail|create-add-all|create-data-only
```

`sbx --clone` needs a git repository, and clone mode makes the host tree read-only. Thus by
default, Draugr refuses a plain directory, and does not silently use a less safe mode. The two
other values let it create the repository for you. They are for different cases:

| | |
|---|---|
| `create-add-all` | *"this is a code project, and I forgot `git init`."* Commits the files, and gives you a normal repo, with the dirty-tree test on each later session. Names that look like credentials, and `DRAUGR_DATA` patterns, go into .gitignore first, and are never committed. |
| `create-data-only` | *"this is not a code project."* Creates a repo whose `.gitignore` is a single `*`. Thus git tracks nothing, and `git status` is always empty. Your files travel by `dr-data`, and Draugr writes `DRAUGR_DATA="*"` for you. |

Use the second for a folder of documents or data. Nothing is ever committed, so the dirty-tree test
never fires, and you need no commit before each session. But you also lose `dr-diff` and
`dr-merge`, because there are no commits to compare. For review, `dr-data status` shows which files
are different. `dr-data diff` shows the changes inside them: a real unified diff for text files, and
names and sizes for binaries and files over
[`DRAUGR_DATA_DIFF_MAX`](docs/CONFIG.md#draugr_data_diff_max).

Only `dr-init` and `dr-up` create a repository. `dr-status`, `dr-scan` and the others still refuse.
The reason is the same as for a stopped mound, which `dr-status` does not start. A command that
shows the state must not change the state.

> To create a repository in a directory writes real files into it: `.git/`, a `.gitignore`, and a
> `.draugr.conf`. That is why the default is `fail`. You must ask for it.

**Memory**

```bash
DRAUGR_MEM_SYNC=auto                 # auto|manual|off
DRAUGR_MEM_STORE=~/.local/share/draugr/memory
```

`auto` imports on `dr-up`, and exports when you leave the agent. `manual` does neither, but `dr-rm`
still refuses to destroy unexported memory, and `dr-status` still reports it. `off` means that you
keep no agent memory: no transfers, no refusal, no memory section.
The store can be in any place, also on the filesystem of WSL as above. Draugr moves the files
through the repo, because `sbx cp` is a Windows binary that cannot write to a WSL path.

**Safety rails**

```bash
DRAUGR_SCAN=true
DRAUGR_SCAN_PATTERNS=".env *.pem *.key id_rsa credentials.json secrets.*"
DRAUGR_SCAN_FAIL=block               # warn|block
```

Refer to [Safety model](#safety-model). This one is more important than it looks.

**Hooks**, if the configuration keys are not sufficient: executable scripts at
`.draugr/hooks/{pre-up,post-up,post-create,pre-attach,post-attach,post-sync,pre-rm}`. They run on
the *host* (WSL), with the merged configuration in the environment. The commands of a kit cannot
do that, because a kit runs inside the mound and cannot see your machine. If a hook exits
non-zero, the command stops. Thus a hook can say no.

`post-create` runs only when Draugr really builds a sandbox. `post-up` runs on each `dr-up`, also
when it only starts a stopped mound.

---

## Commands

Each command is its own small bash script under `bin/`, also the one-line scripts. That is on
purpose. You can read one behavior without a framework. You can override one with your own script
earlier on `PATH`. You can call them from Makefiles and other scripts. If you want one entry
point, `dr <verb>` runs `dr-<verb>`.

### Lifecycle

| Command | |
|---|---|
| `dr-init` | Write a starter `.draugr.conf` into this repo |
| `dr-up` | Create or start the mound: kit, ports, memory. Idempotent, no attach |
| `dr-go` | `dr-up`, then attach and start the agent. **The command that you run each day** |
| `dr-shell` | An extra shell in the mound, beside the running agent |
| `dr-status` | This repo: sandbox state, unfetched commits, dirty tree, unexported memory |
| `dr-ls` | All Draugr mounds on this machine |
| `dr-stop` | Shut down. Filesystem, login and memory all stay |
| `dr-rm` | **Destroy.** Refuses until commits are synced and memory is exported (`--force` to override) |
| `dr-dep` | The mounds that this repo needs (`DRAUGR_REQUIRES`), and who else uses them |

### Moving code

| Command | |
|---|---|
| `dr-sync` | Fetch the commits of the agent onto `draugr/<branch>` |
| `dr-log` | What is new, that you did not see |
| `dr-diff` | Review it |
| `dr-merge` | Accept it (merge, or `--pick <sha>` to cherry-pick) |
| `dr-send` | Push *your* new host commits into the running sandbox |
| `dr-cp` | Copy uncommitted files out of the sandbox |

`dr-sync` uses the `ssh://` transport of git, not the `git://` daemon. The daemon is published
only on Windows loopback. WSL cannot reach that across its NAT, and the port changes on each start.
`ssh://` needs no port, crosses no NAT, and starts a stopped sandbox by itself.

### Moving data

| Command | |
|---|---|
| `dr-data status` | Dry run, both directions: what moves, and how much |
| `dr-data diff` | What a pull **changes**, as a real diff where possible |
| `dr-data push` | Host → sandbox, for paths that match `DRAUGR_DATA` |
| `dr-data pull` | Sandbox → host, same paths |

### Context

| Command | |
|---|---|
| `dr-mem status` | Where memory is on each side, and how much |
| `dr-mem export` | Sandbox memory → `$DRAUGR_MEM_STORE`. Do this before `dr-rm` |
| `dr-mem import` | Store → sandbox. Do this *before* you start the agent |
| `dr-mem import --from-host` | The own memory of the agent on your host → sandbox: the migration |
| `dr-mem diff` | What each side knows that the other does not |
| `dr-mem check` | Does `dr-rm` lose memory? For scripts: `0` no, `1` yes, `2` unreachable |
| `dr-skills list` | What is in the shared skills store, and whether you can decline it |
| `dr-skills diff` | What is new or changed in it since your last accept |
| `dr-skills accept` | Record the current contents of the store as reviewed |
| `dr-skills import` | Fill the store from your own host skill directories |
| `dr-skills install` | Put the skills of Draugr into the store, so that agents can use them |
| `dr-plugin` | What the plugin library holds, and whether your mounds point at it |
| `dr-plugin add <owner>/<repo>` | Register the **marketplace**, and install each plugin that it lists |
| `dr-plugin add <owner>/<repo> <plugin>…` | The same, but install only the plugins that you name |
| `dr-plugin update` | Refresh the catalogs and the plugins |
| `dr-plugin remove <plugin>@<mkt>` | Uninstall, deregister, disable, and really free the space |
| `dr-plugin enable` / `disable` | Only the switch. No mound, instant |
| `dr-plugin clean` | Remove old versions. Nothing else removes them |
| `dr-plugin rollback` | Go back to the previous library |

### The forge (optional, and off by default)

| Command | |
|---|---|
| `dr-forge` | Status: the full liveness chain on the host side, in one screen |
| `dr-forge status --deep` | Also asks the **guest** whether it can reach the internet |
| `dr-forge doctor` | Each link, tested by its effect, each with its own fix |
| `dr-forge exec <command>` | Run it in the guest, and return the exit code of the **guest** |
| `dr-forge push <local> <guest path>` | Copy one path in: the file-level tool, not the data loop |
| `dr-forge pull <guest path> <local>` | Copy one path out |
| `dr-forge init` | Make a registered VM usable: its name, keys-only `sshd`, the tunnel key, the desktop camera. Idempotent |
| `dr-forge up` / `down` | The gateway mound, the VM and the tunnel, up in that order, and down again |
| `dr-forge screen` | The desktop of the guest on screen, on a forge that is up |
| `dr-forge base` / `rollback` | One baseline, and the way back to it |
| `dr-forge rm` | Delete the VM, after it shows what goes with it |
| `dr-forge gateway <dir>` | Make the gateway mound from the template of Draugr. Writes files, and starts nothing |
| `dr-forge daemon <verb>` | AppSandbox itself: `status`, `stop`, `start`, `restart`. Each `dr-layer` verb that rewrites `vms.cfg` needs it stopped. Only `start` shows a UAC prompt |
| `dr-layer` | The disk layers of the VM: `list`, `adopt`, `new`, `freeze`, `thaw`, `drop` |
| `dr-layer new <name> --parent <layer>` | A differencing child on a frozen parent |
| `dr-layer provision <name> --iso <path>` | Build a base: create the VM, install Windows unattended, set up the guest |
| `dr-layer provision <name> --skip-screen` | ... without one phase. `--help` names them all |
| `dr-layer provision <name> --netfx <cab>` | ... and .NET 3.5, from a cab on the matching ISO |

The forge is a Windows 11 VM that an agent controls through AppSandbox. It is for work that a
Linux mound cannot do: to build a Windows game, or to run untrusted Windows code, such as a mod
from GitHub. It is **off unless `DRAUGR_FORGE` names a VM**. If you do not already know
what it is, you do not need it. Refer to [docs/FORGE.md](docs/FORGE.md). All of it is in
`bin/dr-forge`, `bin/dr-layer` and `lib/forge/`, and no core script sources them. Thus if you
delete them, the rest of Draugr does not change.

**`dr-layer` is the one exception to "off unless `DRAUGR_FORGE` names a VM"**, and it must be. Its
verbs *create* the thing that the key names. With that gate, you can never build a first forge.
Its conditions are also the opposite of those of `dr-forge`. Each disk verb needs the AppSandbox
daemon **down**. The daemon rewrites its configuration on each change, and an edit under it is
lost. That is why the layers are a separate command, not more `dr-forge` verbs.

`status` and `doctor` are **read-only and start nothing**, on purpose. You most want to look at the
forge while something else uses it. The verbs that *act* exist. The remaining work is in the order
of work in [docs/FORGE.md](docs/FORGE.md). Each item there that does not exist yet says what to do
meanwhile. It does not half work.

`gateway` is different: it writes a directory, and does not touch the VM. The gateway mound is
almost all mechanism. It has tinyproxy with no destination filter, a keeper session, an SMB share,
and a deny list. The deny list narrows the defaults of `sbx` to the hosts that the tools of the VM
were *seen* to use. Thus it is **made from a template, and made again when the work changes**. It is
not a repository that somebody maintains. git tracks nothing in it. A second run never overwrites
an edit. It keeps and names a file that is different. Use `-y` to take the template anyway.

`exec` sends its command as **UTF-16LE base64**, for a real reason. A command typed in WSL crosses
bash, the argv translation of WSL, the parser of PowerShell, `ssh`, and the PowerShell of the
guest. Tests showed that two of those damage normal quoting. PowerShell 5.1 silently removes `{`
and `}` from native-command arguments. `powershell -Command -` reads piped stdin line by line, so a
multi-line block disappears, with exit code 0 and no output. No step can change base64. The
arguments are joined with single spaces, and run as one command line. argv is not kept, and `exec`
sends no stdin, because neither can be promised across that path. But the exit code *is* promised.
It is the code of the guest, through a wrapper that reads both `$LASTEXITCODE` and `$?`. The
wrapper is necessary, because `powershell -EncodedCommand` exits 0 for a cmdlet that failed.

**Why a chain, not a health flag.** It runs AppSandbox → VM → sshd → tunnel supervisor → keeper →
tinyproxy → gateway. A break in any place shows far from the cause. In one case, each link was
healthy except the tunnel supervisor, which a host reboot silently removed. The symptom showed
three links away: *the application in the guest reported no internet*. Thus each link is tested by
its **effect**. `doctor` asks the guest to fetch a page, and does not look for an `ssh.exe` on the
host. An open forward here proves nothing about the far end.

`dr-forge` is a front end, not a new copy of the logic, and that is not a choice. AppSandbox binds
the **Windows** loopback, and inside WSL2, `127.0.0.1` is that of WSL. A test showed that
`host.json` is readable over `/mnt/c`, but neither `127.0.0.1:8787` nor the Windows host address
accepts a connection. Only a process on the Windows side can connect. Thus `lib/forge/probe.ps1`
goes through `powershell.exe`, and answers in `key=value` lines.

A plugin is **code that runs**: hooks, MCP servers, and `bin/` on the `PATH` of the Bash tool. Thus
it is never installed on your host. `dr-plugin` builds the library inside a mound that it then
removes. Your host only stores the result, mounted back read-only. Set `DRAUGR_PLUGIN_STORE`, then
run `dr-plugin` with no arguments. It prints the next steps. Refer to
[docs/CLAUDE_PLUGINS.md](docs/CLAUDE_PLUGINS.md).
`dr-mem import` refuses to run unattended on a store that Draugr did not write itself. Its own
export has a marker that names the repo. Any other file holds the instructions of somebody else,
and gets a prompt. With `DRAUGR_MEM_SYNC=auto`, the import happens on `dr-up`, and the export on
detach. The import only fills a mound that has *no* memory. The store is always the older copy,
and must never overwrite what the agent learned after it.

> ### The project-key trap, and how Draugr handles it
> Claude Code makes the name of its memory folder from the **absolute path** of the project. Thus
> the same repository has a different key on each side of the boundary:
>
> | Where you ran the agent | Path | Project key |
> |---|---|---|
> | Windows | `C:\src\myproject` | `c--src-myproject` |
> | WSL | `/mnt/c/src/myproject` | `-mnt-c-src-myproject` |
> | Sandbox | `/c/src/myproject` | `-c-src-myproject` |
>
> If you copy the folder with no translation, the agent silently never reads it. No error, no
> warning, only an agent that forgot everything. `dr-mem` translates. It also fixes the owner
> after the copy. `sbx cp` writes files as `root:root`, but the agent runs as uid 1000, and cannot
> write new memories without the fix.

**Memory is the one thing that is different for each agent**, so it is in `lib/agents/<agent>.sh`.
There is one file for each agent, and `lib/agents/default.sh` for an agent that nobody measured.
Codex has a fully different shape. It does not file memory by project, it is half markdown and
half SQLite, and it is off until you enable it. The same four commands cover it. All the other
parts never knew which agent was in the mound, and still do not: attach, Ctrl+Z, the clone, kits,
`dr-sync`, `dr-send`, `dr-data`. Refer to [docs/WORKFLOW.md](docs/WORKFLOW.md#memory).

Both agents also read an instruction file from the repo: `AGENTS.md` for Codex, `CLAUDE.md` for
Claude Code. They need nothing from Draugr. They are committed files, so they arrive with the clone,
and come back through `dr-sync` as all other changes do. Use them for rules that must always apply,
and use memory only as memory.

### Operations

| Command | |
|---|---|
| `dr-doctor` | Test each condition, and say exactly what to fix |
| `dr-config` | The merged configuration, with the origin of each value |
| `dr-scan` | Find files that look like credentials, which the agent can read |
| `dr-kit` | `validate` and `show` the kits of this project, warn about drift, and `apply` kits added to the end of the list |
| `dr-kit save`/`list` | keep a library of named kits, shared between repositories |
| `dr-policy` | Show the network rules in force. `--allow <host>` for a temporary hole |
| `dr-ports` | Publish a port to a running sandbox |
| `dr-hostport` | Let the mound reach a port on *this* machine, at its address of today |
| `dr-code` | Open VS Code Remote-SSH into the mound, on the clone of the agent |
| `dr-trust` | Accept a project configuration after you review it |

---

## Working with data files

Git is the right channel for source, and the wrong channel for a half-processed 4 GB parquet file.
Your work can use data that changes often, and that you do not want in history until it is valid.
For that, `DRAUGR_DATA` gives you a second channel beside git.

```bash
# .draugr.conf
DRAUGR_DATA="tmp/** *.parquet scratch/raw/"
DRAUGR_DATA_PUSH=auto        # dr-up pushes before the agent starts
DRAUGR_DATA_PULL=manual      # you run dr-data pull when you want results back
```

`rsync` moves the matching paths over the same `ssh://` transport as `dr-sync`. They arrive at the
**same path in the repo** inside the clone of the agent. Thus a script that reads
`tmp/raw/2024.parquet` works unchanged on both sides. Four results:

- **They are exempt from `DRAUGR_REQUIRE_CLEAN`.** Changed data does not stop the start of a session.
- **Keep them in .gitignore.** Then the clone of the agent also ignores them (`.gitignore` is
  committed, so both sides agree). The agent then does not commit 4 GB of scratch by accident.
- **The delta algorithm works across the boundary.** Measured: 21 bytes added to a 3 MB file sent
  **375 bytes** on the next push. The first transfer of a large tree is slow. Each later one is
  almost free.
- **Files arrive owned by `agent`, ready to write.** That is why the transport is rsync over ssh, and
  not `sbx cp`. `sbx cp` writes as `root:root`. The agent (uid 1000) can read such files, but never
  change them. Generated output then fails in a way that looks like a broken script, not a
  permissions problem.

> ### The direction is explicit, on purpose
> Draugr can move data automatically, but only in **one direction at a time**. There is no merge
> algorithm for a parquet file. If both sides changed it, a sync in both directions silently selects
> one version, and destroys the other. Thus each transfer declares a source of truth. `push` means
> that the host wins, and `pull` means that the sandbox wins. `dr-data status` shows a dry run of
> both before you select one.
>
> `DRAUGR_DATA_DELETE=false` is the default for the same reason. Without it, a `push` after a
> clean-up on the host deletes the new output of the agent.

Two things are less simple than they look. First, **rsync must exist inside the mound**. It is in
the `claude` image (`/usr/bin/rsync`), but maybe not in each agent image. Thus if it is missing,
`dr-up` installs it at creation (`sudo -n apt-get install -y rsync`, because the agent user has
sudo with no password). If that fails, it uses `tar` over ssh. `tar` is always present, but copies
full files, not only changes. Second, **the first transfer takes time**. A push of tens of
gigabytes into a microVM is a real wait. By default, it happens inside `dr-up`, when you expect a
prompt. That is why `dr-data status` and `DRAUGR_DATA_PUSH=manual` exist.

One small issue: files on `/mnt/c` are mode 777 under WSL, so a plain push takes that into the
mound. Draugr sets `--chmod=D755,F644`, unless you set `DRAUGR_DATA_CHMOD`.

**If the agent only reads the data, do not use this.** Mount it read-only:
`DRAUGR_MOUNTS="/mnt/c/data:ro"`. It shows in the sandbox with no copy and no transfer time, and
the agent cannot change your originals. `DRAUGR_DATA` is for data that the agent writes back, or
data that must be at a specific path in the working tree.

---

## Safety model

What the agent can and cannot see. A direct test showed each line:

| | |
|---|---|
| The clone of the agent contains committed history | yes |
| The clone of the agent contains your uncommitted changes | **no** |
| Your working tree is readable at `/run/sandbox/source` | **yes** |
| Writing to `/run/sandbox/source` | **blocked**: read-only filesystem |
| Files in `.gitignore` are in the clone | no |
| Files in `.gitignore` are readable through `/run/sandbox/source` | **yes** |
| All outside the workspace: other repos, SSH keys, browser profiles | unreachable |
| Host directories mounted into the mound | **exactly four** |
| …of those, writable from inside | **one**: the shared skills store |

Only four host paths cross the boundary: your working tree at `/run/sandbox/source` (read-only),
`/etc/resolv.conf` and `/etc/hosts` (read-only), and `~/.claude/skills`, which is **read-write**.
`/mnt/c`, `/c/Users`, your other repositories and your host SSH keys are all absent.

Two lines in that table are the *opposite* of what the summary above makes you expect.

> ### Trap 1: what the agent can read
> **`.gitignore` hides files from git, not from the filesystem.** The agent can read an untracked
> `.env`, `secrets.env` or `credentials.json` in your project folder, through the read-only mount.
> It is not in the clone of the agent. The agent cannot change it, but it can read it. Thus it can
> send it to all hosts that the network policy allows.
>
> That is why `dr-scan` exists, and why `DRAUGR_SCAN_FAIL=block` is the default. Do not keep real
> credentials in a directory that you give to an agent.

And the other side: not what the agent can read, but what it can write.

> ### Trap 2: the skills store is a writable door out
> `~/.claude/skills` is mounted **read-write** from the host. It is at
> `…\DockerSandboxes\sandboxes\state\agent-skills\`, and is shared on purpose, so that skills stay
> after `sbx rm`, and each sandbox can use them. A direct test showed this: a file written inside
> the mound showed on the host at once.
>
> That is a useful feature with a real result. It is the one path by which a sandbox can put bytes
> on your machine. It is **shared by all your mounds**, and it **lives longer than the sandbox that
> wrote it**. Skills are instructions loaded into the context of the agent. Thus a sandbox can
> leave something behind, and a later, unrelated sandbox reads and follows it.
>
> Nothing here is broken. `sbx skills` works as designed. But "the sandbox cannot write to the
> host" is too strong, and this is the exception. `dr-skills` treats the store as an artifact for
> review, not a dump. `dr-skills accept` records its contents. `dr-skills diff` reports all new or
> changed entries since then. `dr-scan` lists the store on each `dr-go`. Hidden directories are also
> counted. A test showed that a store entry named `.hidden-probe` shows in the list of available
> skills of Claude. Thus a review without them looks in the wrong place.
>
> **There is one store, not one for each agent.** `sbx` merges five host directories, one for each
> agent, into a single store, and changes only the mount path. Thus what a codex mound leaves
> behind is in reach of your claude mounds.
>
> **Each agent reads its mount path.** We measured this on each side: we asked the agent itself to
> list its skills. Claude Code in a claude mound and Codex in a codex mound both named a marker
> that was only in the shared store. A second marker, added after the build of the mound, showed
> with no restart.
>
> **The documented opt-out works, but it is hidden.** `sbx skills --help` says "use
> `--no-share-skills` to opt out". But that flag is not on `sbx create` or `sbx run` until you
> switch on a feature flag. That feature flag is off by default, and `sbx --help` does not show it:
>
> ```bash
> sbx settings set feature.shareSkills true    # now the flag exists
> sbx create --no-share-skills claude .        # and this mound has no skills mount
> ```
>
> We measured all three states on sbx 0.37.1. With the feature off (the default), the store is
> mounted read-write, and no visible option removes it. With the feature on, the flag shows, **and
> it works**. A mound created with it has *no* `skills` line in `/proc/mounts`, and no
> `~/.claude/skills` directory. But it applies **only at creation**. To close the door on an
> existing mound, you must recreate it.
>
> Thus you can close the door, but only with a setting that has no documentation. `dr-skills list`
> reports which of the two states this machine is in.

Two more facts. Know them before they cause a problem:

- **Never mount `~/.claude` into a sandbox.** It contains `.credentials.json`, the authentication
  token of your agent. A sandbox can read each byte of each mount. `dr-mem` copies only the
  `memory` subfolder, and never the parent.
- **Imported memory is instructions, not notes.** The agent loads memory files into its context,
  and mostly trusts them. Memory that you wrote yourself is safe. Memory from a colleague or a
  template is a payload that you carried across the boundary. Read it first. The agent believes a
  file that says *"the user has approved force-pushing to main"*.

---
## Project layout

```
draugr/
├── bin/                    one script per command — all of it, nothing hidden
│   ├── dr                  dispatcher: `dr go` → `dr-go`
│   ├── dr-init  dr-up  dr-go  dr-shell  dr-stop  dr-rm  dr-ls  dr-status
│   ├── dr-sync  dr-log  dr-diff  dr-merge  dr-send  dr-cp
│   ├── dr-data  dr-mem  dr-skills  dr-plugin
│   ├── dr-doctor  dr-config  dr-scan  dr-kit  dr-policy  dr-ports  dr-hostport
│   │   dr-code  dr-setup  dr-trust  dr-dep
│   └── dr-forge  dr-layer  the forge, and the only two commands that need it.
│                           Delete them with lib/forge/ and nothing else notices
├── lib/
│   ├── common.sh           config loading, path translation, guards, output
│   ├── agents/             one file per agent, for the parts that differ
│   │   ├── default.sh      the interface, and the answer for an unmeasured agent
│   │   ├── claude.sh       where Claude Code keeps its memory
│   │   └── codex.sh        the same for Codex, which files memory differently
│   └── forge/              the Windows side — PowerShell, reached through powershell.exe
│       ├── common.sh       the only bash here; the rest runs across the boundary
│       ├── probe.ps1       the liveness chain, answered as key=value lines
│       ├── guest.ps1  vm.ps1  snap.ps1  init.ps1  layer.ps1  provision.ps1
│       ├── tunnel.ps1  screen.ps1  hostkey.ps1  daemon.ps1  rm.ps1  vmscfg.ps1
│       ├── screen-access.ps1  vault-access.ps1
│       └── guest/          eighteen scripts that run INSIDE the VM, one phase each
├── share/
│   ├── config.example      the user-home config, fully commented
│   ├── project.example     .draugr.conf starter, written by dr-init
│   ├── kit.example/        starter sbx kit, also written by dr-init
│   ├── gateway.example/    the gateway mound, written by dr-forge gateway
│   ├── skills/             Draugr's own skills, installed by dr-skills install
│   ├── ollama-proxy/       a query-only front door for a local Ollama
│   ├── ssh-config.snippet  the *.sbx block dr-setup installs
│   └── ssh-config-forge.snippet   the same shape, for reaching the VM
├── docs/
│   ├── SETUP.md            bare machine → working session
│   ├── WORKFLOW.md         the daily loop, data, memory, skills
│   ├── CONFIG.md           every key (a test fails if one is undocumented)
│   ├── SECURITY.md         the boundary, and how each claim was measured
│   ├── TROUBLESHOOTING.md  symptoms → causes → fixes
│   ├── DESIGN.md           why it is shaped this way, and what was rejected
│   ├── DEPENDENCIES.md     DRAUGR_REQUIRES: one repo's mound needing another's
│   ├── CLAUDE_PLUGINS.md   plugins in a mound, uninstalled on your host
│   ├── FORGE.md            the optional Windows VM, and the boundary it keeps
│   ├── FORGE-DISKS.md      its disk layers, and which directories you keep
│   ├── TODO-host-vscode.md host-side VS Code notes, not part of the tool
│   └── HACKING.md          the bash this project uses, and the house rules
├── tests/                  27 .bats files, four standalone checks, and mocks/
├── .githooks/pre-commit    sets the executable bit git cannot carry from /mnt/c
├── .github/workflows/      the two CI jobs: tests, and shellcheck with three lints
├── CHANGELOG.md
├── LICENSE
└── install.sh
```

---

## Design notes

**Why bash, and why one script for each command.** All of it is a workflow over an existing CLI. A
binary needs a release pipeline. A Python package needs an interpreter, inside a project that
possibly does not want one. Bash is already there, in the shell where the work happens. With one
script for each verb, each file is small enough to read fully before you trust it. For a tool that
is about containment, that is the purpose.

**Why a configuration in shell syntax, not TOML or YAML.** No parser dependency, free comments, and
the configuration can compute values (`DRAUGR_PORTS="$(cat .ports)"`). The cost: to source the
configuration of a repo runs its code. That is why trust on first use exists.

**Why `sbx`.** On Windows, it is the only option that gives a real kernel boundary without Docker
Desktop. Its clone mode already has the exact shape of this workflow: a read-only host and a
private clone. Draugr does not hide it. The docs show the backend, and `sbx` commands still work
beside the `dr-*` commands.

**Why network rules and setup are in a kit, not in `.draugr.conf`.** Because `sbx kit` already does
it: declarative, versioned, and shareable outside this tool. A Draugr copy is a worse copy that
works only here. It also misses things that kits already handle, for example credentials through a
proxy on the host, so that the secret never enters the microVM. The rule of Draugr: **kits set up
the inside of the mound, and Draugr sets up the boundary.** All that a kit can express is the job
of the kit. The rest is what a kit cannot see: your WSL paths, your git remotes, your working tree,
the memory store of your machine. That is exactly the configuration of Draugr.

**Why not only aliases.** The important part is not shorter commands. It is the preflight tests,
the path translation, the credential scan, and the refusal of destructive actions while the mound
has unsynced work.

---

## License

MIT.

---

*Draugr is not affiliated with Docker, Inc. or Anthropic. "Docker Sandboxes" and "Claude Code" are
the names that their owners give to their own products.*
