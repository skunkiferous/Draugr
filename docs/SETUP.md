# Setup

From a machine with nothing installed to a working session. Do these steps in order. `dr-doctor`
tests each step, and names the fix for each missing part.

## What you need

| | |
|---|---|
| Windows 11 Pro, x86_64 | with the Hypervisor Platform feature enabled |
| WSL2 | Draugr runs here. Ubuntu tested. |
| `sbx` ≥ 0.37 | Docker Desktop is **not** necessary |
| git ≥ 2.40 | on both sides |
| `jq` | (WSL) `sudo apt install jq`. Draugr parses `sbx ls --json` with it, not by hand |
| A repo on a Windows drive | refer to [the constraint](#why-your-repo-must-live-under-mntdrive) below |

## 1. Enable the hypervisor

In an **Administrator** PowerShell:

```powershell
dism.exe /online /enable-feature /featurename:HypervisorPlatform /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

Reboot. If you skip the reboot, `sbx` later reports that it cannot start a VM. That is the most
common cause of that error.

## 2. Install sbx

In an Administrator PowerShell:

```powershell
winget install Docker.sbx
```

Then, as your normal user:

```powershell
sbx version          # expect 0.37.1 or newer
sbx login            # sign in to Docker
```

The daemon starts on demand. You do not need to start it yourself. If something looks wrong at this
stage, use `sbx diagnose`. It tests the host configuration, which Draugr cannot do.

## 3. Install Draugr

In WSL:

```bash
git clone https://github.com/skunkiferous/draugr.git ~/draugr
echo 'export PATH="$HOME/draugr/bin:$PATH"' >> ~/.bashrc
exec bash
```

There is no build step, and no dependencies except `git`, `jq` and `rsync`. Each command is a bash
script that you can read fully. For a tool that is about containment, that is the purpose.

## 4. Teach WSL how to reach sandboxes

```bash
dr-setup
```

**People often forget this step.** `sbx setup ssh` sets up only the *Windows* SSH client. WSL has
its own `~/.ssh/config`. Without the matching block, neither `ssh <name>.sbx` nor the `ssh://` git
transport works from WSL. `dr-sync` uses that transport to move the commits of the agent to you.

`dr-setup` writes the block, with your Windows username in it. It is idempotent.
`dr-setup --print` shows what it writes, and does not write it.

It also creates [`DRAUGR_KIT_STORE`](CONFIG.md#draugr_kit_store) (by default
`~/.config/draugr/kits`), your library of named kits. These are the two things that Draugr needs for
the machine. All steps after this are for each repository. The library starts empty.
`dr-kit save <name>` in any project puts a reusable kit in it.

## 5. Check everything

```bash
dr-doctor
```

It tests each condition, and prints the exact command to fix each missing part: the hypervisor,
`sbx` and its version, the daemon, `jq`, `rsync`, the SSH configuration on both sides, and whether
your current directory is usable.

Do not continue past a red line here. Each one causes a confusing failure later.

---

## Per project

```bash
cd /mnt/c/src/myproject
dr-init
```

This writes three things, and touches nothing else:

- **`.draugr.conf`**: the configuration of the project. Commit it. That is how a teammate gets the
  same sandbox as you.
- **`.draugr/kit/spec.yaml`**: a starter [kit](https://docs.docker.com/ai/sandboxes/customize/kits/).
  It declares the network rules and setup commands for the *inside* of the mound. Commit it too.
- **`.gitignore` entries**: for the configuration of the user, and the own records of Draugr for
  each checkout.

Then edit the kit. Put `npm ci`, `uv sync` and `apt-get install -y libfoo-dev` there, with the
domains that your build needs:

```yaml
caps:
  network:
    allow:
      - internal-registry.example.com
commands:
  install:
    - command: "npm ci"
      user: "1000"
```

> **Your kit is not the full allowlist.** `sbx` has ~190 machine allow rules. They cover package
> managers, OS packages, the common code hosts and the AI endpoints. `npm`, `pip` and `github.com`
> already work with no kit. What you write is *added* to that set. `dr-policy` shows all rules in
> force, with their source. Refer to [SECURITY.md](SECURITY.md#the-network-policy).

Last:

```bash
dr-go
```

The first run creates the mound, applies the kit, runs your install commands, imports memory, and
starts the agent. Later runs only attach.

---

## Working in a directory that is not a repository

Clone mode needs a git repository. Thus by default, Draugr refuses a plain directory, and does not
silently use a less safe mode. For a folder of documents or data:

```bash
DRAUGR_ON_MISSING_REPO=create-data-only dr-init
```

That creates a repository that tracks nothing, because its `.gitignore` is a single `*`. It also
sets `DRAUGR_DATA="*"`, so that each file travels by `dr-data`. `git status` stays empty forever, so
the dirty-tree test never fires. Refer to
[`DRAUGR_ON_MISSING_REPO`](CONFIG.md#draugr_on_missing_repo).

---

## Why your repo must live under `/mnt/<drive>/`

`sbx.exe` is a Windows binary, and its workspaces are Windows paths. A repository on the ext4
filesystem of WSL (`~/code/myproject`) has no path that `sbx` can mount. Thus Draugr refuses it with
a clear error, and does not fail in a strange way later.

The cost: WSL reaches `/mnt/c` through a translation layer. Thus the git operations that Draugr runs
from WSL (`status`, `diff`, `fetch`) are slower on a large repo than on ext4. From Windows, the same
files are native NTFS, with no extra cost. Thus a Windows editor is not affected. The clone of the
agent is on ext4 *inside* the microVM, so the compile side is not affected either.

A drive letter mapped to a WSL path with `subst` does not solve this. We tested it, and the full
sequence is in [DESIGN.md](DESIGN.md#repos-on-ext4-via-a-subst-drive).

---

## Editing in the mound

```bash
dr-code
```

Opens VS Code with a Remote-SSH connection into the sandbox, on the clone of the agent. You get a
normal editor on the code that the agent works on, while `dr-go` runs the agent itself in your
terminal.

Use the two-window model on purpose: **the mound window edits the clone, and your host window edits
your tree.** They are different repositories. Watch for a save in the wrong one. `dr-status` always
tells you which commits are where.

It needs the Remote-SSH extension and a working `dr-setup`, because it uses the same `*.sbx` host
block.
