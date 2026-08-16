# Setup

From a machine with nothing installed to a working session. Follow this in order; `dr-doctor`
checks each step and names the fix for anything missing.

## What you need

| | |
|---|---|
| Windows 11 Pro, x86_64 | with the Hypervisor Platform feature enabled |
| WSL2 | Draugr runs here. Ubuntu tested. |
| `sbx` ≥ 0.37 | Docker Desktop is **not** required |
| git ≥ 2.40 | on both sides |
| `jq` | (WSL) `sudo apt install jq` — Draugr parses `sbx ls --json` with it rather than by hand |
| A repo on a Windows drive | see [the constraint](#why-your-repo-must-live-under-mntdrive) below |

## 1. Enable the hypervisor

In an **Administrator** PowerShell:

```powershell
dism.exe /online /enable-feature /featurename:HypervisorPlatform /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

Reboot. Skipping the reboot is the commonest reason `sbx` later reports that it cannot start a VM.

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

The daemon starts on demand; you do not need to run it yourself. `sbx diagnose` is worth knowing
about if anything looks wrong at this stage — it checks the host configuration Draugr cannot.

## 3. Install Draugr

In WSL:

```bash
git clone https://github.com/skunkiferous/draugr.git ~/draugr
echo 'export PATH="$HOME/draugr/bin:$PATH"' >> ~/.bashrc
exec bash
```

There is no build step and no dependencies beyond `git`, `jq` and `rsync`. Every command is a bash
script you can read in full — which, for a tool whose premise is containment, is the point.

## 4. Teach WSL how to reach sandboxes

```bash
dr-setup
```

**This is the step people miss.** `sbx setup ssh` configures the *Windows* SSH client only. WSL has
its own `~/.ssh/config`, and without the matching block neither `ssh <name>.sbx` nor the `ssh://`
git transport works from WSL — which is how `dr-sync` moves the agent's commits to you.

`dr-setup` writes the block with your Windows username filled in. It is idempotent, and
`dr-setup --print` shows what it would write without writing it.

It also creates [`DRAUGR_KIT_STORE`](CONFIG.md#draugr_kit_store) — `~/.config/draugr/kits` by
default — your library of named kits. These are the two machine-level things Draugr needs;
everything after this is per-repository. The library starts empty, and `dr-kit save <name>` from any
project puts a reusable kit in it.

## 5. Check everything

```bash
dr-doctor
```

It verifies each precondition and prints the exact command to fix whatever is missing: the
hypervisor, `sbx` and its version, the daemon, `jq`, `rsync`, the SSH config on both sides, and
whether your current directory is usable.

Do not continue past a red line here. Every one of them turns into a confusing failure later.

---

## Per project

```bash
cd /mnt/c/src/myproject
dr-init
```

This writes three things and touches nothing else:

- **`.draugr.conf`** — the project's settings. Commit it; it is how a teammate gets the same
  sandbox you have.
- **`.draugr/kit/spec.yaml`** — a starter [kit](https://docs.docker.com/ai/sandboxes/customize/kits/)
  declaring the network rules and setup commands for the *inside* of the mound. Commit it too.
- **`.gitignore` entries** — for the per-user config and Draugr's own per-checkout bookkeeping.

Then edit the kit. This is where `npm ci`, `uv sync` and `apt-get install -y libfoo-dev` go, along
with the domains your build needs:

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

> **Your kit is not the whole allowlist.** `sbx` ships ~190 machine-wide allow rules covering package
> managers, OS packages, the common code hosts and the AI endpoints. `npm`, `pip` and `github.com`
> already work without appearing in any kit; what you write is *added* to that set. `dr-policy`
> shows everything in force with its source. See [SECURITY.md](SECURITY.md#the-network-policy).

Finally:

```bash
dr-go
```

First run creates the mound, applies the kit, runs your install commands, imports memory, and drops
you into the agent. Later runs just attach.

---

## Working in a directory that is not a repository

Clone mode requires a git repository, so Draugr refuses a plain directory by default rather than
silently falling back to something less safe. If what you have is a folder of documents or data:

```bash
DRAUGR_ON_MISSING_REPO=create-data-only dr-init
```

That creates a repository that tracks nothing — its `.gitignore` is a single `*` — and sets
`DRAUGR_DATA="*"` so every file travels by `dr-data` instead. `git status` stays empty forever, so
the dirty-tree check can never fire. See [`DRAUGR_ON_MISSING_REPO`](CONFIG.md#draugr_on_missing_repo).

---

## Why your repo must live under `/mnt/<drive>/`

`sbx.exe` is a Windows binary and its workspaces are Windows paths. A repository on WSL's own ext4
filesystem (`~/code/myproject`) has no path `sbx` can mount, so Draugr refuses it with a clear error
rather than failing mysteriously later.

The cost is that WSL reaches `/mnt/c` through a translation layer, so the git operations Draugr runs
from WSL — `status`, `diff`, `fetch` — are slower on a large repo than they would be on ext4.
Reaching the same files from Windows is native NTFS access and costs nothing, so a Windows-side
editor is unaffected. The agent's clone lives on ext4 *inside* the microVM, so the side doing the
compiling is unaffected either way.

Mapping a drive letter to a WSL path with `subst` does not work around this; it was tested and the
full sequence is in [DESIGN.md](DESIGN.md#repos-on-ext4-via-a-subst-drive).

---

## Editing in the mound

```bash
dr-code
```

Opens VS Code with a Remote-SSH connection into the sandbox, on the agent's clone. You get a normal
editor over the code the agent is actually working on, while `dr-go` runs the agent itself in your
terminal.

The two-window model is worth adopting deliberately: **the mound window edits the clone, your host
window edits your tree.** They are different repositories, and saving in the wrong one is the
mistake to watch for. `dr-status` always tells you which commits are where.

Requires the Remote-SSH extension and a working `dr-setup`, since it uses the same `*.sbx` host
block.
