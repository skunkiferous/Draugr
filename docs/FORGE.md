# The forge: a Windows VM your agent can build and test in

> ### Optional. Most people using Draugr will never want this.
> The forge is an extra feature: a Windows VM with GPU acceleration on your own machine. With it, an
> agent in a mound can build and test Windows software. If you do not set `DRAUGR_FORGE`, none of
> this exists. No command runs it, no test mentions it, and you install nothing. Refer to
> [Optional by construction](#optional-by-construction) for how Draugr enforces that.

> ### Status: partly built, and the built part is measured.
> `dr-forge status`, `doctor`, `up`, `down`, `screen`, `exec` and `push`/`pull` exist, and ran on a
> live forge. `dr-setup --forge` writes the route that WSL needs to reach one. `dr-forge init`
> applies what a new VM needs, and `dr-forge rm` removes one. `base` and `rollback` exist, and were
> tested live. `dr-forge gateway` makes the gateway mound. `dr-layer` has the six disk verbs.
> `provision` builds a base from an ISO with each component in it: MSYS2, the tool set, the
> automation and screen servers, the vault mount, VS Code, and `.NET 3.5` when `--netfx` names the
> cab that only a human can make. **Nobody ran all of `provision` end to end yet.** Nothing after
> the egress proof ran at all. Each stage lists what is tested.
> Claims have one of three labels, as in the rest of these docs: *measured* (run on this machine,
> with the result quoted), *read* (from source code or documentation, not run), and *unmeasured*.
> The network half is measured end to end. [FORGE-DISKS.md](FORGE-DISKS.md) tells how to protect
> the disk of the VM by hand while the snapshot bug exists.

An agent in a mound can write Windows C++, and reason about software that it can never run. The
mound is Linux, and the target is Windows. The forge fills that gap. The work can be a game, or
something that you do not want to host yourself, such as an unknown mod from GitHub. For that, a VM
that you can throw away is the full purpose.

---

## Optional by construction

The structure of the code enforces "optional". It does not depend on care:

- **One switch.** All of it is inert unless `DRAUGR_FORGE` names a VM. `dr-plugin` uses the same
  gate with `DRAUGR_PLUGIN_STORE`. While it is empty, `dr-doctor` says nothing about the forge.
- **Isolated code.** All of it is in `bin/dr-forge` and `lib/forge/`. No core script sources it,
  and `dr-up` and `dr-go` never call it unless the switch is set.
- **No new dependency for other users.** No Python, no AppSandbox, no PowerShell module on the
  default path.
- **Tests against a mock AppSandbox**, as `tests/mocks/sbx` stands in for `sbx`. The bash half runs
  on any machine, with no skips. `tests/forge-api.bats` also runs the PowerShell that talks to the
  daemon against `tests/appsandbox_mock.py`, where a Windows host makes that possible, and skips
  where it does not (*built*). Neither needs AppSandbox.
- **Its security claim is separate.** The forge makes a weaker promise than a mound. `SECURITY.md`
  keeps it in its own conditional section. Thus the core safety model stays exactly the same for all
  who never turn this on.
- **Nothing for games in core.** The Unreal network rules are with the gateway, not in `share/`.

The Draugr fixes from this work are the exception, and correctly so. They fix things that are wrong
for each Draugr user today, and none of them is specific to the forge.

---

## Where the line falls: Draugr owns the mechanism, you own the contents

*(decided)* The half of Draugr is all that stays the same, whatever the purpose of the VM.

| Draugr | the project that uses it |
|---|---|
| the VM as an object: create it on a parent disk, make it usable, throw it away | **which** parent, and what is inside it |
| the channel, the liveness chain, the screen, the git and file loops | nothing: these are the normal commands |
| the layer **mechanism**: differencing chains, `adopt`, `new`, `freeze`, `thaw`, `drop`, `list` | the **contents** of layer 1 and up |
| **layer-0**: a generic Windows base that an agent can control, and the list of components that it *can* have | which of those components to turn on, and each layer above it |
| no network policy of its own | the allowlist that the work really needs |

**Why the contents cannot belong to Draugr.** They depend on an account and an age.
[What is a layer, not the base](#what-is-a-layer-not-the-base) shows this with asset libraries. A
library bought over ten years needs one editor for each engine version, and *which* versions you
need depends on your purchases. Engine-layer logic in Draugr ships the library
layout of one person as a mechanism.

**Thus Unreal is in these documents, but in no Draugr code.** It is the use case that drove the
design, and the reason for each measurement here. A reader must know that. But `kits/unreal`, the
Visual Studio layer and the layer build for each engine belong to the project that wants them. That
project uses `dr-layer` and `dr-forge` as all other users do. That is also why *nothing for games
in core* in [Optional by construction](#optional-by-construction) needs no exception. On this line,
there is no game code to place.

**Draugr judges each item of layer-0 separately.** The test: *does a Windows VM built for a
different purpose want this?* MSYS2, the Unix tools, VS Code, the automation server, the screen
server and the desktop camera all pass. Thus they are always in it.

**What does not pass becomes an optional component, off by default** *(decided)*. A flag is better
than a decision in prose, because it records the choice where it is made. Without it, a reader must
guess why something is in a generic base. `.NET Framework 3.5` is the first. It came in because the
install of UE 4.27 showed the Windows message *"an app on your PC needs the following Windows
feature"*. A base for a different purpose must not have it, but a base for engine work must. Draugr
ships the component, and your project asks for it.

It has one condition, and Draugr refuses on it before the provision, not during it. It is a
**Feature on Demand**. A guest with no adapter has no Windows Update. Thus its only source is the
payload of the Windows ISO, which `install-netfx3.ps1` reads from the vault. If you enable the
component while that is not reachable, it fails half an hour in. Thus Draugr tests it first.

[Below](#which-directories-exist-and-which-of-them-you-keep) tells where each of these is, and which
directories you keep.

---

## Why not the obvious things

| | |
|---|---|
| UE5 in Linux/Docker | Makes a Linux build. A cross-compile of a *Windows* UE5 game from a Linux host is not a supported configuration. |
| Windows containers | Process isolation needs a guest build that matches that of the host. Hyper-V-isolated containers do not do GPU-PV. Neither runs the editor. |
| A second physical PC | Works, and is the honest baseline that this must beat. It costs a machine, and a network that the agent can reach. |
| **A Windows VM with GPU acceleration on this machine, controlled by the mound over ssh** | This. |

---

## The shape

The mental model of the README is three repositories, and the forge keeps all three. It changes
*where the build happens*: inside the VM, not inside a mound. The gateway mound stays, but only to
give that machine its way out. It holds no clone and no files:

```text
      YOUR REMOTE  (origin)
           ▲  │
      push │  │ pull
           │  ▼
      HOST REPO  ◄──────── dr-sync ────────►  FORGE CLONE
   /mnt/c/Code/MyGame                         (Windows 11 VM: UE5, MSVC,
           │                                   a slice of the GPU — and
           │                                   where the build runs)
           └── the vault, READ-ONLY ────────►            │
                                                         │ no network adapter
                                                         ▼
                                         GATEWAY MOUND ◄── ssh -R tunnel
                                         (tinyproxy; the sbx policy is the allowlist.
                                          EGRESS ONLY — no clone, no files)
                                                         │
                                                         ▼
                                                     internet
```

**The VM never reaches the network by itself.** It has no adapter of its own, and one ssh channel
out, through the gateway, under the same `sbx` policy as a mound. The agent stays in the mound of
the project, and controls the VM across that channel. Thus the gateway mound is a network
appliance, not a place to work: ["Two mounds, two policies"](#two-mounds-two-policies). There are
three separate planes:

| Plane | Between | Who holds it |
|---|---|---|
| **Control** | Draugr ↔ the API of AppSandbox: create, start, stop, snapshot, delete | Draugr, on the host, in WSL. Never the mound, and never the guest |
| **Data** | the host repo ↔ the clone of the VM, over ssh | Draugr, on the host: the normal git loop and file loop, with the VM as the far end |
| **Egress** | the VM → the internet, through the gateway | the `sbx` policy, exactly as for a mound |

---

## What the base image must contain

The forge VM is not disposable. It holds installs that you cannot copy in, only install, and only
[a flatten](FORGE-DISKS.md) protects them. Thus we must say clearly what a base image *is*, and
also what it is **not**.

**The base is what each forge needs, whoever owns it.** Nothing in it is specific to the account
of one person, one project, or one engine version:

| Capability | Why it must be in the image | How, today |
|---|---|---|
| **A shared screen** | a human must be able to take over the desktop that the agent controls. Refer to the next sections | TightVNC, loopback-only, over the ssh channel |
| **Host directories, read-only and read-write** | the vault cannot be in the VM, and the agent must fetch assets itself | SMB over the tunnel: `V:` read-only, `S:` writable |
| **git** | projects are versioned, and git *is* the replication path to the host | MSYS2 |
| **rsync** | to move artifacts and logs without a share | MSYS2 |
| **A package manager** | the agent installs what it needs, without a request for permission each time | MSYS2/pacman, pinned to one allowlisted host |
| **GUI automation** | installers and dialogs have no CLI. The tree covers all except Slate | a UIA-based MCP server in session 1 *(to build)* |
| **Autologin, unlocked** | session 0 cannot see any UI API | AppSandbox keeps the password from expiring |
| **The tunnel key and proxy settings** | the VM has no adapter. The gateway is its only way out | `guest/install-tunnel-key.ps1`, proxy at `127.0.0.1:3128` |
| **A dummy loopback adapter** | certificate revocation fails with no interface | refer to [below](#the-loopback-adapter) |
| **Windows Update off** | if not, the guest patches itself, and reboots during a build | set in the base image |
### The default base, item by item

Here are the decided contents of the shared base. Nothing here depends on an account, an engine or
a project. All that does belongs in a [layer](#what-is-a-layer-not-the-base).

**All of it is one command.** `dr-layer provision` builds this base from a new Windows 11 guest, on
the **host**. That is not a preference. The guest has no adapter. Until the host starts the mound
and the tunnel, the guest can reach nothing, and cannot set itself up. It is idempotent end to end.
Each phase has a `--skip-<phase>` flag, and `--only` names the phases that you want. Each phase
tests by effect. It names the four things that it *cannot* do: the install of AppSandbox, the
creation of the VM and the install of Windows, the **first** ssh key (the API has no route for exec
or key deployment), and sign-ins.

**GUI automation: Windows-MCP** ([CursorTouch](https://github.com/CursorTouch/Windows-MCP), MIT,
*read*). Its **transport** decides, not its tool list. It serves SSE/Streamable HTTP on a host and
port that you can set, and an `ssh -L` forward needs that. A server with only stdio cannot work
here. Stdio over ssh arrives in **session 0**, where UI Automation sees nothing. That is not
theory. The main alternative,
[deploymenttheory/windows-mcp-server](https://github.com/deploymenttheory/windows-mcp-server),
finds that it runs with no desktop, and *drops its desktop toolsets*. Windows-MCP reads the
accessibility tree, not pixels. It gives 0.2–0.5 s for each action. It has token authentication,
an IP allowlist and TLS. We need only the token and the loopback binding.

Its cost is a **Python runtime** in the base (3.14+, installed through `uv`). That adds allowlist
entries for `**.astral.sh`, `pypi.org` and `files.pythonhosted.org`. It also adds `github.com` and
`objects.githubusercontent.com`, where `uv` gets the interpreter itself, not from python.org.
Remember the second choice, because it has no runtime: one Go binary. It also documents this
architecture correctly. It recommends an unlocked session that is already signed in, with the
server started at logon. If Python must ever leave the base, the way back is a small stdio-to-TCP
shim in session 1.

**Elevation decides whether you can automate installers.** A third server,
[sbroenne/mcp-windows](https://github.com/sbroenne/mcp-windows), gives the rule clearly: *Windows
security prevents any non-elevated process from interacting with UAC prompts or elevated
(Administrator) windows*. Installers are the main reason why this VM needs GUI automation, and they
elevate.

**Measured, and it makes the problem much smaller.** The two ways into this guest do not have the
same rights:

| Reached by | Session | Elevated? |
|---|---|---|
| `ssh` | 0 | **yes**: `IsInRole(Administrator)` is true, so sshd gives a full token |
| the `PowerShell` tool of the MCP server | 1 | **no**: a filtered token, the normal desktop case |

The UAC settings of the guest are the defaults: `EnableLUA=1`, `ConsentPromptBehaviorAdmin=5`,
`PromptOnSecureDesktop=1`.

Thus **a software install is not the hard case**. Over ssh, it is already elevated, and no prompt
shows. That is why all in this base installs from a script, and nothing needed a policy change. The
hard case is narrow. A program that *already runs on the desktop* elevates while it runs. Its
consent dialog shows on the secure desktop, where UI Automation, AutoHotkey and VNC all see
nothing, by design.

When that case occurs, the narrow fix is `PromptOnSecureDesktop=0`. The prompt stays, but on the
normal desktop, where a tool can read and click it. The person who accepts it can set it at that
time, on one VM. It does **not** need to be in the base image, and neither does
`ConsentPromptBehaviorAdmin=0`. Nothing is set today, and nothing needed it yet.

**AutoHotkey v2: yes, for exactly one job.** Where the tree is visible, control of elements by name
is more reliable than coordinates. Thus the MCP server wins there. AutoHotkey is for the opposite
case: a replay of a known path through a **Slate** window, where [the tree is
empty](#what-the-tree-actually-sees-measured). There, each step otherwise costs a model call. A
frozen script runs that path with no model in the loop. It is so small that it costs nothing when
unused. As all else, it must run in session 1.

#### Both installed and driven end to end *(measured)*

`lib/forge/guest/install-automation.ps1` (that of the gateway, at the time of the measurement)
does all of it over ssh. None of it needed elevation or a prompt. It installed **uv 0.12.19** into
`%USERPROFILE%\.local\bin` in 4 s. Then one `uv tool install windows-mcp` in 40 s pulled
**CPython 3.14.7** and **windows-mcp 0.8.6** (on fastmcp 4.0.10). **AutoHotkey 2.0.28** was
unzipped into `C:\Tools\AutoHotkey`: no installer, no file association, nothing in `Program Files`.

| | Size |
|---|---|
| `uv` itself | 41.2 MB |
| CPython 3.14 | 60 MB |
| the server's environment | 153 MB |
| AutoHotkey | 4.3 MB |
| **total in the base** | **≈258 MB** |

The wheel cache is another 151 MB, and **`uv cache prune` frees none of it**. We measured 150.7 MB
before and after, because the own environment of the tool still uses each entry. `uv cache clean`
takes it to 0, and a base image wants that.

`windows-mcp install` registers its own scheduled task, and that is the useful part. The server
started **in session 1**, while all that controlled it was in session 0. From the host, through
`ssh -L 18765:127.0.0.1:8765`, `initialize` answered 200, and a `Snapshot` call returned the live
desktop: the real `1920x1080` display, the taskbar, each open window, each element with coordinates
and an `[action: click]`. Without a bearer token, the same request gets **401**.

**It runs on 8765, not on its own default of 8000**, because [the in-editor MCP plugin of
UE](#an-optimisation-not-the-target-unreals-own-mcp-plugin) serves `http://127.0.0.1:8000/mcp`
inside the editor process. With two servers on one port, the first to start wins, and the loser is
silent. 8000 stays reserved for the editor, and the tunnel already forwards it.

The clearest measurement is the same AutoHotkey script, run from both sides:

| Launched from | What `WinGetTitle("A")` and `WinGetList()` returned |
|---|---|
| `ssh` (session 0) | `<error: Target window not found.>`, and **no windows** |
| the `PowerShell` tool of the MCP server (session 1) | `C:\Windows\SYSTEM32\cmd.exe`, and the window list with `Program Manager` |

Same binary, same script, same user, same machine, one difference. It is the session-0 wall,
measured a second way. It is also why the task is more important than the server.

#### Pixels, and what they actually need

[Rung 5](#the-ladder-of-doors) is the last item with a claim to a place in the base, and it does
not get one. "Take a snapshot and process the pixels" is really three jobs, with very different
costs:

| the job | what it needs | cost |
|---|---|---|
| find known **text** on a window | OCR, and **Windows has one offline**: `Windows.Media.Ocr` | milliseconds, CPU, no download |
| find a known **icon** | template matching, of the OpenCV class | milliseconds, CPU |
| understand an **unfamiliar** screen | a vision-language model | the only one that needs a model |

For *"click the thing that says Launch"* in a Slate window, the first row is the full job, and
Windows already has it. Only the third needs a model, and it is rare **by design**. Discovery
happens once. Then [AutoHotkey replays the path](#discovery-is-expensive-repetition-should-not-be),
with no model in the loop.

**The third row also needs nothing new, because the agent already is a vision model.** A
screenshot given to it in its own mound is an image in its own conversation: no extra service, no
extra allowlisted host, nothing in the base image. `windows-mcp` already has a `Screenshot` tool,
installed and tested.

**To borrow the GPU of the VM is the wrong trade.** GPU-PV gives the GPU to the *VM*, not to the
mound. Thus "let the agent borrow it" means a model server **inside the forge**. That is several GB
in the base, and it breaks the own rule of the gateway, that nothing in the VM talks to a model. It
also competes for the one resource that the VM exists for: shader compilation, lighting builds and
the editor. A loaded VLM that holds VRAM during a lighting build is a loss, not a saving. Nobody
tested whether CUDA works reliably through GPU-PV, and that is not worth a test on the critical
path.

**If you ever want one, a local model on the host is the right shape, and most of it already
exists.** Draugr ships [`share/ollama-proxy`](../share/ollama-proxy/): nginx in front of Ollama,
with a default-deny allowlist. Ollama has no authentication and no read-only mode. The port that
serves inference also serves `DELETE /api/delete`. `DRAUGR_MODEL_URL` already has the default
`11435`, that proxy, not the `11434` of Ollama. Ollama loads models implicitly. The first request
loads the model, and it unloads after the keep-alive window. This host has an RTX 4090 (24 GB.
`Win32_VideoController` reports 4 GB, which is the 32-bit overflow of that field). Thus a 7B vision
model is small for it. Ollama is **not installed here today**, and the loopback rule comes first.
If a `localhost:<port>` rule also reaches Windows loopback for the model port, the proxy can bind
only loopback, which is strictly safer.

None of that is a question for the base image, because the host and the mound are both outside the
guest. Thus **the base gets nothing**. The condition that can change the decision is specific and
measurable: **many cheap looks, not a few expensive ones**. For example, to watch a progress bar,
or to wait for a build dialog. There, the latency and cost of each call start to be the largest
part. Rung 5 is still *not attempted*, so there is no evidence for it yet.

**The package set**, all from the pinned MSYS2 repository that is already on the allowlist. Thus
they need no policy change:

| Package | Why it is in the default base |
|---|---|
| `git` | projects are versioned. git *is* the replication path to the host |
| `rsync` | artifacts and logs without a share |
| `openssh` | keys, `ssh-keygen`, `scp` |
| `curl`, `wget` | fetches through the gateway proxy |
| `unzip`, `zip`, `p7zip` | assets arrive as archives |
| `jq` | `.uproject` is JSON. This sets `EngineAssociation` without a GUI |
| `diffutils`, `patch` | to compare and patch configuration between engine versions |
| `make` | build glue |
| `openssl` | hashes and certificates |
| `less`, `file`, `tree`, `nano` | the minimum for a human who must look around over ssh |
| `ripgrep`, `fd` | search of a 100+ GB tree at a usable speed (**UCRT64** builds, into `/ucrt64/bin`) |

*Measured*: the full set installed and tested, and MSYS2 grew from **439 MB to 487 MB**, **48 MB**
for all of it. Two traps. Both gave confident wrong answers first:

- **The native packages of MSYS2 are UCRT64 now.** The prefix is `mingw-w64-ucrt-x86_64-`, not
  `mingw-w64-x86_64-`, and the binaries go to `/ucrt64/bin`. The old names give no useful error.
  They report *"target not found"*, as if the package did not exist.
- **pacman needs stdin closed over ssh.** An ssh session has no terminal. Thus a prompt that
  `--noconfirm` does not cover blocks **forever**: no output, no CPU, no process, and nothing in
  `pacman.log` except the command line. `< /dev/null` changes that silent hang into a readable
  error. The same trap has a second edge. A redirect after a *pipeline* applies only to its last
  stage. Thus `foo | head -1 < /dev/null` reads nothing, and reports each tool as missing. Put the
  pipeline in a subshell.

**Not `python` from pacman.** The Python of MSYS2 is a POSIX build. The MCP server needs the
*Windows* interpreter for COM and UI Automation. The two do not work well together, and only one of
them can control the desktop. Thus the base has the Windows one through `uv`, and does not touch
that of pacman.

#### Licences, since this base installs itself

This is not legal advice. It is what the declared licence metadata says, read from the 26 MSYS2
packages and 90 Python distributions installed in a built guest.

Each component is OSI-approved open source. No proprietary component, no clickthrough EULA, no
registration, no per-seat term.

| | |
|---|---|
| GPL-2.0 | git, tree, AutoHotkey v2, TightVNC, `fuzzywuzzy` |
| GPL-3.0-or-later | rsync, wget, diffutils, patch, make, less, nano, bash, coreutils, grep, sed, gawk, `msys2-runtime` |
| MIT / BSD / Apache-2.0 / ISC / Unlicense | curl, jq, openssl, zip, openssh, ripgrep, fd, `uv`, and about 85 of the 90 Python packages |
| Other permissive | unzip (Info-ZIP), file, pillow (MIT-CMU), pywin32 and `typing_extensions` (PSF) |
| Weak copyleft | `certifi` (MPL-2.0) |

**These licences do not limit an automatic, unattended install.** They control copying, change and
*distribution*, not how you get or start a program. The GPL says so directly: GPLv2 §5 and GPLv3 §9
both say that you need not accept the licence to *run* the software. There is no agreement for a
script to click past. The licences that need interactive acceptance belong to proprietary software,
and the base contains none.

Also, the provision does not **redistribute** anything. It fetches each component from its own
upstream to the machine under build, as a package manager does. Thus the person who runs it gets
their own copy, and nothing passes through this project.

**Distribution starts when you give a built image to somebody else.** A VHDX, a snapshot or a disk
holds GPL binaries. GPLv2 §3 / GPLv3 §6 then require the matching source, or a written offer with
it. Most of this base is GPL-3.0, so that is real work, not a formality. That has a result for the
design: **a provisioning script is the cheap form of a base image for licences, and a shipped disk
is the expensive form.** That is a reason for `forge-provision.ps1` over a published prepared disk,
apart from size.

If you ever share an image, look at two items first:

- **`p7zip`** is LGPL *plus* `custom:unRAR`, the only component in the set that is not plainly OSI.
  The unRAR clause forbids use of that code to build a RAR-compatible archiver, and nothing here does
  that. Without p7zip (`bsdtar` covers most of its use), the base is fully OSI.
- **`fuzzywuzzy`** (GPLv2) and **`python-levenshtein`** (GPL-2.0-or-later) arrive as dependencies of
  `windows-mcp`, which itself is MIT. That is a consistency question for that project, not a duty for
  people who run it. But it means that the Python environment contains GPL code.

**What this page does not settle:** a licence and the terms of use of a website are different
documents. A site can limit automatic fetches, also where the software is permissive. For four of
the five sources, the question barely applies. PyPI and `repo.msys2.org` exist for package
managers. `astral.sh/uv/install.ps1` exists to be piped into a shell.
`autohotkey.com/download/2.0/version.txt` is the documented way to look for a new version. Nobody
compared `tightvnc.com` with its own terms. The fetch is one file, once, on the command of a human,
and `install-screen-access.ps1 -Msi` accepts a file that you got in any other way.
### What is a layer, not the base

**The engine does not belong in the base image**, and neither does the Epic Games Launcher. Both
are personal. The Launcher depends on an account, and the engine depends on an *age*.

The reason is a normal fact of asset libraries. Marketplace assets support the engine versions that
were current when they were sold. Authors stop their updates when sales stop. Thus a library bought
over ten years covers engine versions back to **4.x**. To use such an asset, you open it in the last
editor that supports it, put it into a project, and migrate that project forward. Thus a user with
a deep library needs *many* editors, one for each age. No single base image can hold them. At
100+ GB installed, a dozen versions is more than a terabyte of almost identical Windows.

Thus the minimum shape is **one base with no engine, and one layer for each engine version**. That
is the simple case of a chain that stacks further ([below](#layers-stack-and-only-the-top-one-is-appsandboxs)):

```text
layer-1.vhdx                 the accounts and toolchains layer   <- read-only parent
  +-- layer-2-ue427.vhdx     differencing child: one editor
  +-- layer-2-ue53.vhdx      differencing child: one editor
  +-- layer-2-ue58.vhdx      differencing child: one editor
```

**The mechanism is a differencing VHDX, not the snapshots of AppSandbox.** `New-VHD -ParentPath
<base> -Differencing` creates the child directly. AppSandbox takes `VhdxPath`
[exactly as written](FORGE-DISKS.md#how-appsandbox-stores-a-vm). Thus a child made by hand is a
normal VM disk, and the [snapshot bug](#it-has-a-bug-that-decides-the-design) does not apply. Each
child costs one engine, not one Windows.

Three rules come with it, and the first one is absolute:

- **Nothing writes to the parent after a child exists.** A change to it makes each child invalid.
  Thus it must be outside each VM folder. The [delete
  hazard](FORGE-DISKS.md#the-vms-folder-is-derived-from-the-disk-path-not-from-its-name) already
  requires that for archives.
- **Children collect general drift**, not only the engine. Windows updates, caches and settings all
  go into the child. They grow. The rule is harsher than it looks, because a differencing child
  grows by each block ever **written**, and never gives one back. If you delete a 10 GB file in the
  guest, the child keeps exactly the same size. The cost of a file is not what it holds. It is each
  block that it ever touched.

  *Measured on `ue-427-test`:* **31.0 GiB of delta over a 21.6 GiB parent** after five days of
  normal use. The engine itself was in the frozen parent, and nothing like it was in the child. The
  chain was intact and correct (`layer-0` flat → `layer-1` → `layer-2-ue427` → the VM). Thus none
  of it leaked out of the layers. Two Windows files explain most of it. Both are very large *and*
  always rewritten, which is the worst case under that rule. `pagefile.sys` grows with the commit
  charge, and has no limit in principle. `hiberfil.sys` is 40–75% of RAM, for a file that a VM
  never reads. The base image managed neither.

  *We say this because the clear claim is wrong, and these docs had it until a correction:*
  Microsoft publishes **no single system-managed formula**. The minimum follows the crash-dump
  value. The file grows with the commit charge, when that passes about 90% of the commit limit. With
  the default *automatic* dump, the file starts small, and only grows to min(RAM, 32 GB) after a
  second crash within four weeks. "1.5× RAM" and "3× RAM" are troubleshooting rules that became
  folklore. *Measured on the host:* 127.9 GiB of RAM, system-managed, **8192 MB allocated, peak use
  0**, about a sixteenth of RAM. Thus the reason to pin a pagefile is not that system management
  wastes space. The reason is that a file with no limit stays forever in a child.
  [`dr-forge init`](#making-a-forge-usable-and-unmaking-it-init-and-rm) now fixes both.

  **Why that fix is for each VM, and not in the base image:** in a base, each VM already built on an
  existing layer needs a rebuild of the full chain to get it. For each VM, it reaches any VM, on any
  layer, at any time. That is the difference between a fix and a migration. It stops the growth, but
  frees nothing. Blocks already in a child stay until a flatten of the chain or a rebuild of the VM.
- **Not proven.** Nothing here is measured yet. It is the clear next disk test, and it is cheap to
  try on a test VM.

### Where Visual Studio goes, and why it is one layer rather than many

**The Visual Studio requirement of the engine also follows its age.** Thus it cannot be in
the shared base. The own table of Epic for 4.27 lists *"4.22 or Later: VS 2017 / VS 2019"* and
*"4.25 or Later: VS 2019 (Default)"*, and does not mention VS 2022 for 4.x. 5.x moves on to VS 2022
(*read*). Thus a library that covers 4.x and 5.x needs at least two Visual Studios.

**But VS versions install side by side**, and that makes a single personal base possible. Microsoft
supports it explicitly. Each major version (2017 / 2019 / 2022) has its own folder, with its own
components (*read*). Thus several Visual Studios can be together in one layer.

In fact, they **must** be together, not one in each engine layer. SDKs, C++ toolsets and runtimes
are **shared** between installations. Thus a workload change in one version can change what another
sees, and an uninstall of one removes file associations for all. You cannot put components that
reach across each other cleanly into different disk layers. They belong in the same one.

One trap inside VS 2022 that a layer cannot fix: **UE 5.0 to 5.5 does not build with an MSVC
toolset newer than 14.38** (*read*). That rule applies only to those versions. **UE 5.8 built here
with the current toolset** (*measured*). But it means that an old engine and a new one want
different compilers. VS 2022 can hold several at the same time. Thus the fix is to pin the toolset,
not the Visual Studio. The layer must only hold both.

#### Where the installer comes from, and why the URL is also the checksum

Use the `aka.ms` redirector, because the guest can already reach that form:

```text
https://aka.ms/vs/17/release/vs_community.exe     ->  301
https://download.visualstudio.microsoft.com/download/pr/<guid>/<sha256>/vs_Community.exe
```

`kits/unreal` already has both hops: `aka.ms` as the redirector, and
`download.visualstudio.microsoft.com` under `**.visualstudio.microsoft.com`. **No new rule is
necessary.** For the compiler without the IDE, use `vs_BuildTools.exe` in place of
`vs_community.exe`.

**The number is the product version, not the year**, and the two are different enough to confuse
anyone. All three resolved, and their hashes matched:

| URL | Visual Studio | bootstrapper | SHA-256 (from the redirect) |
|---|---|---|---|
| `aka.ms/vs/15/release/vs_community.exe` | **2017** | 4,420,888 B | `1bf11fc98cf22d93498180d50794219a0cbb860a98880e29836bb66acadc0123` |
| `aka.ms/vs/16/release/vs_community.exe` | **2019** | 4,422,856 B | `d70a79f50e37c337227a928875fcef8d233b71056d4c967f070d92f1584d2c7e` |
| `aka.ms/vs/17/release/vs_community.exe` | **2022** | 4,474,136 B | `e6b61fd64e03ffa252060602e3873ef09dff477c168d3aeab233e07299e82344` |

**A WRONG VERSION NUMBER DOES NOT GIVE 404. IT GIVES HTTP 200 AND AN HTML PAGE.** An `aka.ms` short
link that does not exist redirects to Bing. `vs/19` and `vs/22` look like the clear spellings of
2019 and 2022, and both answer:

```text
302 -> https://www.bing.com?ref=aka&shorturl=vs/19/release/vs_community.exe
200    Content-Type: text/html
```

Thus `curl -O` or `Invoke-WebRequest -OutFile` writes a web page to disk under the name
`vs_community.exe`, and reports success. Measured, after exactly that mistake. This is the strongest
reason to compare the hash. A bad engine version, a bad product number or a typo all arrive as a
200, and only the hash tells them apart from the real file. The `Content-Type` is a cheaper first
test: `application/octet-stream` for a real bootstrapper, `text/html` for Bing.

**The second-to-last path segment of the redirect target is the SHA-256 of the file.** Measured:
`aka.ms/vs/17/release/vs_community.exe` resolved to a URL that ends
`.../e6b61fd64e03ffa252060602e3873ef09dff477c168d3aeab233e07299e82344/vs_Community.exe`, and
`sha256sum` on the 4,474,136-byte download returned exactly that. Thus a pinned download that you
can verify costs one `curl -I`. Resolve the redirect, keep the URL, and the hash is inside it. MSYS2
is the opposite. It publishes no `.sha256`, and you must make a pin by hand (refer to
`lib/forge/guest/install-msys2.ps1`).

The own download page of Microsoft gives
`c2rsetup.officeapps.live.com/c2r/downloadVS.aspx?sku=community&channel=Release&version=VS2022`.
It works, and serves the same bootstrapper (4,475,880 bytes, with different branding on the stub).
But `c2rsetup.officeapps.live.com` is a **different apex from all that the kit allows**. Thus its
use from the guest makes the policy wider, for no gain. Use the `aka.ms` form.

All of these are the ~4.3 MB **bootstrapper**, not the product. It then downloads payloads from
`download.visualstudio.microsoft.com`, so that host is more important than the installer link. The
payloads are also reachable. That was worth a test, because Microsoft moved older Visual Studio
releases behind a `my.visualstudio.com` sign-in before. Measured, with no credentials sent:

| | channel manifest | build it serves |
|---|---|---|
| `aka.ms/vs/15/release/channel` | 200, 73,540 B | `VisualStudio.15.Release/15.9.83`, the final servicing build of VS 2017 |
| `aka.ms/vs/16/release/channel` | 200, 134,478 B | `VisualStudio.16.Release/16.11.60` |
| `aka.ms/vs/17/release/channel` | 200, 91,781 B | `VisualStudio.17.Release/17.14.41` |

A payload named by the 2017 manifest, `vs_Setup.exe` (4,420,872 B on
`download.visualstudio.microsoft.com`), answered 200 with no `WWW-Authenticate` header. Thus all
three Visual Studios install through the hosts that `kits/unreal` already allows.

#### Mounting the vault so the desktop can see it

*(measured, after a base image shipped without the last part, and cost an evening)*

`V:` and `S:` are SMB shares over the tunnel, mapped by `guest\mount-vault.ps1` **inside the
guest**. Two Windows facts make a good mount invisible, and neither one gives a message:

| | |
|---|---|
| A mapped drive belongs to a **logon session** | A drive mapped from an ssh session never reaches the desktop. The script reported `V: -> \\127.0.0.1\vault` and `vault entries: 1516`, and `dir V:` on the desktop answered *"A drive with the name 'V' does not exist"* |
| Within one logon, it belongs to one **elevation token** | The logon of an administrator has two, and a drive mapped in one is not in the other |

Together, those two make a trap. Only SYSTEM and Administrators can read the password file of the
vault. Thus `mount-vault.ps1` can run only **elevated**, and the drive that it maps is then
invisible to Explorer and to the Epic Games Launcher, which is not elevated. An elevated shell can
reach `V:`, but nobody must need that. You expect to open a mounted drive in Explorer.

**The base image sets `EnableLinkedConnections`** (`install-guest-base.ps1`, section 9b). Windows
then copies a mapping to the linked token, so one mount serves both. It needs a reboot, which a base
image gets anyway. Know its cost. A process that is not elevated can then use a connection that an
elevated one made. In this guest, that boundary is already thin. There is a single account, a local
administrator, and the own session of the agent is elevated. The credential gives read on the vault
and write on the scratch share. `-SkipLinkedConnections` declines it.

The alternative is a looser ACL on the password file, so that the mount can run without elevation.
That trades the same boundary in the other direction, **and** leaves elevated installers without
`V:`. It moves the choice, and does not avoid it.

Thus: mount it on the desktop, at either elevation, once.
#### Download once, install many times: `--layout`

A layer that you build again must not download Visual Studio again each time. The guest must also
not need Microsoft to get it. `--layout` makes an offline cache, and the vault carries it in,
read-only:

```powershell
# on the HOST, which has internet. One directory per product version - they cannot share.
& $bootstrapper --layout D:\VaultHolder\installers\vs2022 `
                --add Microsoft.VisualStudio.Workload.NativeGame `
                --includeRecommended --lang en-US --wait
```

```powershell
# in the GUEST, after mount-vault.ps1, from an ELEVATED prompt. One per layout.
# Start-Process -Wait is not optional - see below.
$p = Start-Process -FilePath 'V:\installers\vs2022\vs_setup.exe' `
     -ArgumentList '--noWeb','--quiet','--norestart' -Wait -PassThru
$p.ExitCode   # 0 = done, 3010 = done with a reboot pending, anything else = failed
```

**Three ways in which this goes wrong, all measured.**

**1. Run bare, it returns at once and lies.** `vs_setup.exe` is a **GUI-subsystem binary** (PE
subsystem 2), so no shell waits for it. The prompt comes back at once, and `$LASTEXITCODE` is `0`,
because the *launch* succeeded. The install can still run, can be finished, or, as here, can fail
fourteen seconds later with nothing on screen. With `Start-Process -Wait -PassThru`, the exit code
means the install.

**2. No `--add` is necessary, and names there can be worse than useless.** Each layout holds a
`response.json` that records what was cached, and the bootstrapper passes it automatically. The
installer log shows it as `--in "V:\installers\vs2022\Response.json"`. Thus the minimal command
installs exactly what the layout contains. That is most important for **VS 2022**. Its layout here
records *two* components: `Workload.NativeGame` **and** `Component.VC.14.38.17.8.x86.x64`. A
hand-written `--add Workload.NativeGame` silently gives you only 14.44, without the 14.38 that
UE 5.0-5.5 needs.

**3. `--lang` is a layout switch, not an install switch.** At install time, the installer answers
`Option 'lang' is unknown`, prints its usage, and exits **87** (`ERROR_INVALID_PARAMETER`). That
happens before `--quiet` applies, so it looks like a silent no-op. The install-time spelling is
`--addProductLang`. With a layout for one language, neither is necessary, because the bootstrapper
already passes `--locale`.

A failed try still leaves ~125 MB of Visual Studio Installer client under
`C:\Program Files (x86)\Microsoft Visual Studio\Installer`. That is the installer itself. You need
it anyway, and the next run uses it again. `%TEMP%\dd_installer_*.log` names the real fault in its
first fifteen lines. Look there before anything else.

**`--norestart` does not work alone.** Without `--quiet` or `--passive`, the installer refuses it.
The refusal is a GUI usage dialog, not a non-zero exit. Thus a script that seems to run did nothing
(*measured*, VS 2017 layout). `--passive` shows a progress bar, and needs no input. `--quiet` shows
nothing. Exit code **3010 is success**, with a reboot pending, not a failure. A layout also has its
own `response.json`. Thus the `--add` line above repeats the default of the bootstrapper. It is not
a requirement.

Four things that cost real money if you skip them:

- **`--add` is necessary.** Without it, `--layout` fetches the full product, much more than 100 GB.
- **`--lang en-US` is necessary.** Without it, you get each language pack.
- **The layout must hold each component that you will ever want**, because `--noWeb` cannot fetch a
  missing one later. Apply the MSVC &le; 14.38 pin from above there, at layout time, not at install
  time. Also add the Windows SDK that the age of the engine needs.
- A new `--layout` run on the same directory is **incremental**, so an interrupted download costs
  nothing.

**Record the RESOLVED url, not the `aka.ms` one**, if the same bytes are important.
`aka.ms/vs/17/...` follows the current servicing build, and its hash changes with it. The
`download.visualstudio.microsoft.com` url that it redirects to names one immutable file, and has the
SHA-256 of that file in its own path. *Document* the `aka.ms` form, and *pin* the resolved form.
VS 2017 is the exception in both cases. 15.9.83 is its final build, so it cannot change.

#### Will this layer build the engine versions I need?

**The short answer for the layer of this repository: 4.15 through 5.8, with 5.6 and 5.7.** If that
is all that you wanted to know, stop here.

**Why Visual Studio is in the layer at all**, for readers who do not write C++. Unreal is a C++
program. Even a project that is pure Blueprint compiles C++ when a plugin is rebuilt, when the
engine is built from source, and when an asset pack has code. The engine calls the compiler of
Microsoft for that, so the compiler must be on the disk. Nobody must open Visual Studio or read C++
for this to be important. It is important the first time that an engine refuses to load a project.

**The one possible problem** is a version mismatch. The compiler of Microsoft has its own versions,
separate from Visual Studio. It is called a **toolset**, with numbers such as `14.44`. One Visual
Studio installation can hold several side by side, and the engine selects one. An engine refuses a
toolset that is newer than it knows, not older. Thus the risk is always *too new*, never *too old*.

That is all of it. The rest below is bookkeeping about which numbers are present.

**What this layer holds**, read back from the guest, not from memory:

| from | toolset | the engines that accept it |
|---|---|---|
| VS 2017 | 14.16 | 4.15 - 4.24 |
| VS 2019 | 14.29 | 4.22 - 5.0 |
| VS 2022 | **14.38** | 5.0 - 5.5, which refuse anything newer (*read*) |
| VS 2022 | **14.44** | 5.4 and up, with **5.8** (*measured*) |

**Nobody measured 5.6 and 5.7 separately here**, and we do not claim it. They are between two
known points. 14.38 covers 5.5 and earlier. 5.8 was measured: it built with the current toolset in
this project. `UnrealBuildTool` reported `Result: Succeeded`, and Build Solution succeeded in the
IDE, in a guest with no network adapter. It is unlikely that a version between them needs something
outside that pair. If you want certainty before you commit a layer to it, the engine gives its own
answer. `Engine/Source/Programs/UnrealBuildTool/Platform/Windows/` names the preferred and minimum
toolchain versions in source. A build that does not accept the toolset says so in its first few
lines, and does not fail in an unclear way later.

**What can stop this layer from serving 5.6 - 5.8**, from most to least likely:

1. **An engine that wants a toolset newer than 14.44.** 14.44 is the newest that Visual Studio 2022
   17.14 gives. Thus the fix is not a bigger `--add`. It is a newer Visual Studio servicing build:
   a refresh of the offline layout, and a new install. This is the only failure that the layer
   really cannot absorb. Watch it as engines move on.
2. **A missing Windows SDK.** This layer has `10.0.19041.0` and `10.0.26100.0`, which covers what
   5.x asks for. If a newer engine wants a newer SDK, that is an `--add` and a new install, not a
   rebuild.
3. **Nothing about .NET.** Unreal has its own .NET under `Engine/Binaries/ThirdParty/DotNet`. Thus
   the build tools do not depend on the .NET of Windows.

Note what is *not* on that list: a different Visual Studio for each engine. All three are in one
layer on purpose, for the reason above. Their SDKs, toolsets and runtimes are shared.

#### Rebuilding the layouts

*Only for a new build of the offline installers, or to add a toolset to them.*

A layout records its own selection in `response.json`. Thus this comes from the layouts, not from
memory. One identical line built all three (*measured*):

```json
"add": ["Microsoft.VisualStudio.Workload.NativeGame;includeRecommended"], "addProductLang": ["en-US"]
```

`--includeRecommended` brings the current toolset of the channel, and **only** that one. That is why
the 2022 layout first held only 14.44, and needed 14.38 added. `--noWeb` cannot fetch a missing one
at install time. Thus each toolset that you will ever want must be in the layout before it goes into
a guest:

```powershell
# on the HOST. Incremental - this fetches the extra toolset, not the 4 GB again.
& $bootstrapper --layout D:\VaultHolder\installers\vs2022 `
                --add Microsoft.VisualStudio.Workload.NativeGame `
                --add Microsoft.VisualStudio.Component.VC.14.38.17.8.x86.x64 `
                --includeRecommended --lang en-US --wait
```

That component id matches the own `Catalog.json` of the layout. It gives each toolset from 14.29 to
14.44 under the same `VC.<toolset>.<product>.x86.x64` spelling. Thus a pin for any other engine is
one `--add`, by the same pattern. A layout whose toolset set is written down is repeatable in the
important way. It makes the same layer two times, not only a run that finishes.

### Layers stack, and only the top one is AppSandbox's

The parent of a differencing disk can itself be a differencing disk. Thus the chain can be as deep
as the design needs:

```text
layer-0.vhdx               Windows, toolchain, screen, mounts, tunnel   read-only
  \__ layer-1.vhdx         the Launcher, VS 2017 / 2019 / 2022          read-only
        \__ layer-2.vhdx   one editor                                   read-only
              \__ layer-3.vhdx   empty on creation - the VM writes here
```

**Layers have numbers, not names from their contents.** The number is the depth and nothing else.
`layer-0` is the default base that this repository builds. Each layer above it holds what its owner
decided to put there. That is the purpose. What belongs at layer 1 is a judgement, different for
each person and each project. But *"layer 2 is a child of layer 1"* is structural, and cannot drift.
Each layer below the top is read-only, and the numbers make that clear at once.

Two practical notes:

- **Layers 2 and above have siblings**, one for each engine version and one for each project. Thus
  the number alone is not a name: `layer-2-ue553`, `layer-3-tabulua`. Layers 0 and 1 are single.
- **The 15-character limit is on VM names, not on disks.** The folder of a VM comes from its disk
  path, not its name ([why](FORGE-DISKS.md#the-vms-folder-is-derived-from-the-disk-path-not-from-its-name)).
  Thus disk directories can have long names: `layer-2-ue-5.5.3\disk.vhdx` is fine. Only the guest
  hostname must fit, and a frozen layer needs no VM. A VM exists only while the layer builds, and for
  the layer-3 VMs that do the work.

The top disk is the only one that **AppSandbox ever points at**, and that is the purpose.
`asb_vm_delete` removes the folder of the VM with all its contents. With a disposable top layer, a
deletion can reach nothing that took an hour to build. All below it is fully outside the reach of
AppSandbox. A ruined VM costs a `New-VHD -Differencing`, not a restore.

The cost, and the conditions:

- **Each parent is frozen once a child exists.** To build a layer, boot it *as* the top, install,
  shut down cleanly, then never write to it again. The chain is built once, from the bottom up.
- **A four-level chain builds, and a child can be bigger than its parent** *(measured)*. We ran
  `New-VHD -Differencing` three times over a 512 MB dynamic base, then `Resize-VHD` on the **top**
  disk to 1 GB. It reports `VhdType: Differencing`, `Size: 1073741824`, `ParentPath: L2.vhdx`, and
  all four files are at 4 MB on disk. Thus depth is real, thin provisioning holds at each level, and
  the normal cmdlet can grow a layer above an unchanged parent. That does not need the API that
  AppSandbox uses for template instances.
- **What that does *not* prove**: that HCS boots a guest from four levels, or the cost of reads that
  walk the full chain. Keep the volatile layers near the top until a real guest ran on one.
- **Children share one Windows identity**: the same SID, the same hostname. With no network adapter,
  that is mostly not important. But two children that run at the same time reach the SMB share of the
  mound as the same machine. Measure that before you depend on it.

`dr-forge` must manage this shape, and it is more than `base` and `rollback` can carry. It must
create a child, freeze a layer, list a chain, discard and recreate the disposable top, and merge a
layer down when it earned permanence. **None of it is proven.** The first test is a two-level chain
on a test VM, which costs almost nothing.
### One forge per project, which the layers decided

This was [open question 1](#open-questions) while a forge cost 100+ GB. **The only reason to share
one forge between projects was its size**, and it was a strong reason. A dozen projects, each with
its own Windows, Visual Studio and engine, is a terabyte of almost identical disk. Against it was
the isolation that *one mound, one repo* exists to give. With a shared forge, the agents of two
projects can read the code of each other.

The layers fully remove the cost reason. Thus the isolation reason wins with no contest:

```text
layer-0  Windows + the default base        ~35 GB    shared, read-only
layer-1  accounts, Visual Studio           ~25 GB    shared, read-only
layer-2  one engine version               ~100 GB    shared, read-only
layer-3  one project                     the delta   per project, writable
```

Three projects on one engine cost **one** copy of the 160 GB, not three. A forge for each project
now costs little more than the own size of the project. That is the right cost for anything that
exists once for each project.

**How disposable layer 3 is depends on the place of the project, and the user decides that, not
we.** Draugr puts the clone of a repo *inside* the mound, not on a host mount. The reason applies
here unchanged. If the agent can reach a source of truth directly, the agent can rewrite its history
with nobody noticing. By that reason, the clone belongs on the own disk of the VM:
`DRAUGR_FORGE_DIR=D:\work\MyGame`, where `D:` is layer 3. The repository of the host is out of
reach, and the agent pushes for review as each other contributor does.

The counterweight is specific to games. A project with many binary assets is expensive to hold two
times, and `DRAUGR_FORGE_DIR` also accepts a mount (`V:` is the vault, read-only. `S:` is scratch).
Thus the key takes either, and this page gives the trade-off, but does not decide it:

| `DRAUGR_FORGE_DIR` | what it costs | what it buys |
|---|---|---|
| `D:\…`: the own disk of the VM | the project is held two times, which hurts most with large binary assets | your repository and its history stay outside the reach of the agent |
| `S:\…`: the scratch mount | the agent works in your tree, with its history | one copy, and no push-to-review round trip |

In both cases, what you can make again is disposable. You can always rebuild the DDC, `Saved\`,
`Intermediate\` and cooked output, and with them on `S:`, layer 3 stays small for either choice. But
with a clone on `D:`, layer 3 holds important work until it is pushed. Thus **a new fork is not free,
and must not be automatic.** That is the cost of layers that comes back. **Nothing can write to a
parent after it has children.** Thus an update of Visual Studio or a patch of an engine means a new
layer beside the old one, and a new fork of each project onto it, after each project pushed.

What this decision does *not* change, and one thing that it retires:

- **RAM does not change.** A running forge is a running forge, so the budget still says one at a
  time. Forges for each project are *defined* in parallel, and *run* one at a time. That is how
  people work on a project anyway.
- **Children share one Windows identity**: the same SID and hostname as layer 0. With one forge
  running at a time and no network adapter, this is no longer worth a measurement.
- **The run-state lock is no longer on the critical path.** A shared forge needed it. One desktop,
  one cache and one editor between two agents at the same time is a risk that must be impossible,
  not only documented. Forges for each project never create that case. Thus the lock is a useful
  extra, not a condition for a release. It is still useful where a tree has more than one writer.
  The `S:` choice above creates that case, because the agent in the VM and you on the host then
  both work on the same files.

### Which directories exist, and which of them you keep

*(decided)* One forge for each project settles how many **VMs** exist. The number of *directories*
is a different count, because the gateway is not a project that you keep.

| Directory | How many | Pushed | Holds |
|---|---|---|---|
| **Draugr** | one | publicly | the mechanism: `dr-forge`, `dr-layer`, layer-0, and the gateway template |
| **your forge project** | one | privately | the allowlist, the build logic of layer 1 and up, which layer-0 components to enable |
| **a game project** | one for each game | where that game lives | the mound of the agent, `DRAUGR_FORGE`, and where the git loop arrives |
| **a gateway** | one at a time, generated | never | made from the template and that allowlist |

**Only one gateway can run, and that is a limit, not a preference.** `DRAUGR_PORTS` publishes the
fixed host ports `18888` and `18445`. `18022` is
[pinned](#the-pinned-port-has-a-price-a-far-end-is-not-identified-by-the-vm-being-up). The
supervisor holds one mutex, `Global\Draugr.forge.tunnel`. Thus with any number of gateway
directories, only one can be up, and thus only one forge VM is reachable at a time. A gateway for
each VM is a set of directories that exclude each other: all of the maintenance, none of the
concurrency.

**Thus Draugr makes the gateway, and nobody maintains it.** It is almost all mechanism: tinyproxy,
samba, the denied `sbx` defaults. Only its allowlist is personal. Draugr creates it in a local
directory under `DRAUGR_ON_MISSING_REPO=create-data-only`, which makes a repository whose
`.gitignore` is `*`. Each Draugr command works, nothing is tracked, and there is nothing to push or
keep in step. The allowlist changes **by the kind of work, not by VM**. The hosts of Epic are the
same for 4.27 as for 5.8. Thus you make it again when the work changes, not when the VM changes. A
narrower list is also safer, not only tidier. A gateway made for one job is better than one that
holds the union of all jobs.

**The gateway holds no clone, and never did.** [What crosses](#what-crosses) says it clearly. The
code and the data are in the VM, and the gateway controls what the VM can *reach*. Work comes back
in two ways that already exist. One is the git loop, with the VM as its far end, into the game
project on the host. The other is `S:`, the writable scratch share. The vault beside it is mounted
`:ro`. Thus scratch is the only path that the guest can write to, and that is the full reason why
there are two.

**This topology follows from the pin.** Without the pin on `18022`, several forge VMs can run at the
same time, but with a mound rule for each VM. Then a gateway for each VM is real. The pin gives one
stable rule, and this is the other half of that trade.

### An updates layer, for when there are many project VMs

Software updates arrive all the time, but a frozen layer cannot take them. A click on "update now"
is very small next to a new install of Windows, Visual Studio and a 100+ GB engine. Thus the
question is where those updates go.

**The option: a layer that exists to be thrown away.** It starts empty, collects patches, and is
*replaced*, not extended. Thus the chain never grows. The benefit is in the transition, because you
cannot delete an old layer until each VM above it is rebuilt:

| | held during the changeover |
|---|---|
| rebuild of the base layers | old base **and** new base: the full ~160 GB, two times |
| replacement of an updates layer | one base, and the old and new updates layer: tens of GB, two times |

**The place for it is not clear, and only one answer works.** Engine layers have *siblings*, one
for each age. An updates layer **below** them (between layer 1 and the engines) invalidates each
engine install each time that you replace it. That means a new install of 100+ GB for a Windows
patch. It must be **above** the engine layer. That means **one updates layer for each engine age**:

```text
layer-1  accounts, Visual Studio
  +-- layer-2-ue553
  |     \__ layer-U-ue553     patches; replaced, never extended
  |           +-- layer-3-projectA
  |           \__ layer-3-projectB
  \-- layer-2-ue58
        \__ layer-U-ue58
```

That duplication is acceptable, because only the updates layer of the **active** age needs to stay
current. An old age, kept for [asset migration](#the-asset-migration-workflow-and-what-it-means-for-the-disks),
boots rarely, and can keep an old updates layer, or none. The important deduplication is between
*projects that share one engine*, and exactly that stays.

**It holds less than it sounds, and that helps.** The engine is *not* in it. A new engine version is
a new layer-2 sibling, not an update. Thus an updates layer holds Windows cumulative updates, Visual
Studio, and the small things: `pacman -Syu`, `uv self update`. The base disables Windows Update
(`NoAutoUpdate=1`, `wuauserv` stopped). Thus to refresh this layer, enable it again inside that
layer, update, and turn it off again.

**A rebuild of the VMs above it is necessary. Know why.** A differencing child stores only the
blocks that it changed, and its NTFS metadata points at extents in the parent. Thus a swap to a
parent with different contents is not safe, whatever `Set-VHD -ParentPath -IgnoreIdMismatch` lets
you do. The children get a new fork. That is the cost.

> ### The annual rebuild is a copy and a merge, not a reinstall *(measured)*
>
> **Copy the engine layer, move the updates layer onto the copy, and merge it down.** The result is a
> new engine layer with the updates in it, built with no installer. Proved on test disks of 512 MB:
> `tmp/test-merge.ps1`, 16 assertions, all passing:
>
> - **`Set-VHD` took the new parent with no `-IgnoreIdMismatch`.** A byte copy keeps the VHDX
>   identity. Thus Hyper-V accepts the copy as the same parent, and no safety test needs an
>   override. That is important. The flag exists for a move onto a *different* disk, which is the
>   dangerous case that this scheme never needs.
> - **The chain read correctly through the new parent before the merge**: the files of the parent,
>   the own files of the child, the overwrite of the child winning, and the **deletion** of the child
>   holding. A differencing disk must record a deletion as an absence, not a change.
> - **The merge made a standalone disk** with both layers, the deletion included, and used up the
>   child.
> - **The original parent was not touched**: its own file intact, the update absent, its version of
>   the shared file unchanged, its deleted file back, and still a plain `Dynamic` disk. The full
>   scheme rests on that property, and it holds.
>
> **Scale the timings before you trust them.** 100 MB copied in 0.1 s and merged in 1.0 s, on one
> volume. A real engine layer is 100+ GB, and we measured a cross-volume copy of that at
> [~11 minutes](FORGE-DISKS.md#making-the-wait-cheap-rather-than-short). The merge time follows the
> size of the **child**, not of the parent. Thus an updates layer of a few tens of GB takes minutes,
> not seconds. That is still much less than a new install of Windows, Visual Studio and an engine.

**Use it only with several project VMs.** With one or two, run the updates inside the own layer 3 of
the project, and skip the extra level. You then avoid one or two copies of a few tens of GB, which
is cheaper than the extra work. The layer is worth it when enough projects share one engine, and the
same patches N times are no longer free.

This is also why it was right to [number layers by depth, not by contents](#layers-stack-and-only-the-top-one-is-appsandboxs).
When updates collect above it, the layer that *installed* Visual Studio no longer holds the Visual
Studio that runs. A name from the contents silently becomes false.

### The asset-migration workflow, and what it means for the disks

**Two engine versions are never necessary at the same time** *(the own process of the tester)*.
That settles the question that the layers depended on. The process is strictly sequential:

1. The asset is a full project, or you make an empty project and import the asset into it.
2. Open it in the engine version that the asset supports. Look around, and run validation, because
   some assets arrive broken. Delete what you do not want. **Close the engine.**
3. Back up the project.
4. Open the **target** engine (usually 4.27), show incompatible projects, select this one, and
   accept *convert in place*. The backup is the safety net. Look around and validate again.
5. Make a *second* empty project, and copy the assets into it. An asset can seem to work, but depend
   on files that it wrote **outside its own directory**. It breaks only when you move its directory
   alone. Validate that project too.
6. Only then does the asset join a library.

Two results for this design:

**A change of engine version must be cheap, because the process changes it all the time.** That is
where the [layer chain](#layers-stack-and-only-the-top-one-is-appsandboxs) is worth it. With one
child for each engine version, a version change is a `VhdxPath` edit and a restart. No copy, and
seconds, not the tens of minutes of a disk copy. Without layers, each change moves 100+ GB, and the
full workflow is not usable in a VM.

**Much of the process is text, not GUI.** Steps 3 and 5 are file operations. In step 4, "show all,
then answer the version prompt" depends on the `EngineAssociation` field in the `.uproject`, which
is JSON. If you set it to the target engine, the project possibly opens directly, with no dialog to
click (*not tested, and cheap to test*). Modern versions have a commandlet for validation. Thus the
part that needs the GUI is narrower than the manual process suggests. Try [rung 1](#the-ladder-of-doors)
first, before you automate anything at rung 4.
### Why a shared screen is not optional

Three facts push in the same direction, and the last one stays true after fixes to the other two:

1. `open_display` **crashes the daemon** for a GPU-PV VM, on 0.1.8 as on 0.1.4.
2. The GUI of AppSandbox **cannot run beside the headless daemon**. Thus each look at the screen
   costs the agent its API, and a VM stop and start at each end.
3. **This guest has no RDP**, because it is Windows Home.

With all three repaired, RDP is still the wrong tool, because **RDP does not share a screen. It
opens a second one.** It takes away the console session while a human is connected, and gives it
back changed. The desktop that the agent controlled is not the desktop that the human sees. The
requirement is the opposite of remote access. When the agent stops halfway through an installer,
the human must finish *that dialog*, on *that desktop*, and give it back during the task. That is
screen *sharing*, and VNC does it. It attaches to the console session, and does not create one.

Thus the screen server belongs in the base image beside the engine, not in a list of extras. The
result came within the hour. The flat base was older than the VNC install. Thus **the first boot
after the move of the VM onto it had no screen server**. The failure did not look like a missing
program. `ssh -L` opens the local port whether or not something answers. Thus the tunnel reported
success, and the viewer only disconnected. A new run of `windows\install-screen-access.ps1` fixed
it in one scripted minute.

Both scripts now prevent that mistake. `forge-screen.ps1` reads the greeting of the guest through
the forward before it opens the viewer (*measured: a live server greets in 0.50 s, and a refused
forward closes at 2.01 s*). `forge-repoint.ps1` tests the screen server after the VM boots. **All
that you install in a guest after the flatten of its base is not there after a restore.** The screen
server is only the first thing that showed it.

### When the clipboard stops crossing, look at the host, not the VM

*(measured)*

A VM with no paste is half a machine. You must type each password, each path, each piece of
configuration by hand from a screenshot. The agent is useful because a human can step in during a
task, and that is hard when nothing can be carried in. Thus this section is worth its space, though
the fault was not in the forge at all.

**The symptom.** Copy and paste worked well *inside* the guest. Between host and guest, it did
nothing, in both directions, with no error. It stayed after a full VM restart, and a restart of the
VNC viewer.

**What was really true**, from the host:

| | while broken | once fixed |
|---|---|---|
| `GetClipboardOwner()` | **NONE** | a live window |
| `SetClipboardData` / `GetClipboardData` (raw Win32) | worked | worked |
| `Clipboard.SetText` (WinForms/OLE) | failed | worked |
| the own clipboard, service and policies of the guest | healthy all the time | healthy |
| `tvnviewer` as clipboard-chain head | alive, not hung, replied to `WM_NULL` in under 2 s | same |

**The mechanism.** The clipboard of the host had **no owner**. That is the sign of a process that
put data on the clipboard, and then exited or stopped answering. Usually that is *delayed-rendered*
data. The content is not stored, but made on demand, by a `WM_RENDERFORMAT` message to the owning
window. A reader asks a window that does not exist now, and gets nothing. The raw API still worked,
because it never waits for the owner. That is exactly the split in the table.

**Neither clear fix can work. Know why, and save the time:**

- **A restart of the VM** cannot help, because the stuck state is in the window station of the
  *host*. The guest was healthy all the time. Do not follow your instinct here. The symptom shows
  in the VM, so the VM looks guilty.
- **A restart of the VNC viewer** cannot help either. The viewer is only a *listener* in the
  clipboard chain, not the owner, and a restart of a listener does nothing about a dead owner.
  (TightVNC Viewer registers through the legacy `SetClipboardViewer` chain. Thus it shows as the
  chain head, and looks guilty, but it is only a bystander.)

**The fix is one line on the HOST**, and it needs no code:

```cmd
cmd /c "type nul | clip"
```

`clip.exe` opens the clipboard, empties it, and sets its own empty content *with a live owner*.
That is exactly the sequence that cleared it. After that, copy something normally, and it works
again.

**A test in ten seconds** for this fault:

```powershell
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class Clip {
  [DllImport("user32.dll")] public static extern IntPtr GetClipboardOwner();
  [DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
}
'@
"owner : $([Clip]::GetClipboardOwner())"     # 0 after you have copied something = this fault
"open  : $([Clip]::GetOpenClipboardWindow())" # non-zero = something is holding it, different fault
```

An owner of `0` right after a copy is the sign. A non-zero *open* window is the other clipboard
fault: a process holds it open. That fault names the guilty process, so it is the easier case.

**One measurement trap, which almost sent this in the wrong direction.** The `Set-Clipboard` of
PowerShell, and all else built on WinForms, goes through the **OLE** clipboard. That needs
`OleInitialize` on an STA thread. A shell from a script or a tool often has neither. Thus it throws
*"Requested Clipboard operation did not succeed"* **on a fully healthy machine**. That false
negative read exactly like the real fault, and gave a confident, wrong diagnosis that the clipboard
of the host was broken. Test the clipboard with raw `OpenClipboard`/`SetClipboardData`/
`GetClipboardData`, or from a real interactive session. Never use `Set-Clipboard` from a script.

---

### The loopback adapter

With no adapter, Windows has no network, and CryptoAPI does not even try to fetch OCSP, CRL or AIA
data. `certutil -urlfetch -verify` fails each URL with `ERROR_NOT_CONNECTED (0x800708ca)`, and the
chain ends `CRYPT_E_REVOCATION_OFFLINE`. Nothing shows in the log of the gateway, because no request
happens. Clients that ignore revocation results work. That is why an earlier test of the full path
passed. Clients that insist fail, and the engine integration of Visual Studio is one of them.

A Microsoft KM-TEST Loopback Adapter fixes it. It gets a link-local address and **no default
route**, so it adds no way out. But Windows now reports a network, and CryptoAPI starts to fetch,
through the proxy as all else does. Measured before and after, in the same guest:

| | No adapter | With the loopback adapter |
|---|---|---|
| `INetworkListManager.IsConnected` | False | **True** (`IsConnectedToInternet` stays False) |
| `certutil -urlfetch -verify` on the certificate of GitHub | `CRYPT_E_REVOCATION_OFFLINE` | **passed**, `dwErrorStatus=0` |
| `curl` to `api.github.com` through the proxy | TLS failure | **HTTP 200** |
| Direct `curl` to `1.1.1.1`, DNS for `example.com`, ping | all fail | **all still fail** |

By hand, in the guest: run `hdwwiz.exe` → *Install the hardware that I manually select* → *Network
adapters* → *Microsoft* → *Microsoft KM-TEST Loopback Adapter*. `netcfg` cannot do it now. On
Windows 11, it installs only protocols, services and clients. In a script, it is what `devcon` does:

```powershell
# create a root-enumerated *MSLOOP device and bind netloop.inf to it (elevated)
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class DevInst {
  [StructLayout(LayoutKind.Sequential)] public struct SP_DEVINFO_DATA {
    public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="SetupDiCreateDeviceInfoW")]
  public static extern bool SetupDiCreateDeviceInfo(IntPtr set, string name, ref Guid cls, string desc,
    IntPtr hwnd, int flags, ref SP_DEVINFO_DATA data);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="SetupDiSetDeviceRegistryPropertyW")]
  public static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA data,
    int prop, byte[] buf, int len);
  [DllImport("setupapi.dll", SetLastError=true)]
  public static extern bool SetupDiCallClassInstaller(int fn, IntPtr set, ref SP_DEVINFO_DATA data);
  [DllImport("newdev.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="UpdateDriverForPlugAndPlayDevicesW")]
  public static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwnd, string hwid, string inf,
    int flags, out bool reboot);
}
'@
$cls = [Guid]'4d36e972-e325-11ce-bfc1-08002be10318'   # GUID_DEVCLASS_NET
$set = [DevInst]::SetupDiCreateDeviceInfoList([ref]$cls, [IntPtr]::Zero)
$dev = New-Object DevInst+SP_DEVINFO_DATA
$dev.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][DevInst+SP_DEVINFO_DATA])
[void][DevInst]::SetupDiCreateDeviceInfo($set, 'NET', [ref]$cls, $null, [IntPtr]::Zero, 0x1, [ref]$dev)
$hwid = [Text.Encoding]::Unicode.GetBytes("*MSLOOP" + [char]0 + [char]0)  # REG_MULTI_SZ
[void][DevInst]::SetupDiSetDeviceRegistryProperty($set, [ref]$dev, 0x1, $hwid, $hwid.Length)
[void][DevInst]::SetupDiCallClassInstaller(0x19, $set, [ref]$dev)         # DIF_REGISTERDEVICE
$reboot = $false
[void][DevInst]::UpdateDriverForPlugAndPlayDevices([IntPtr]::Zero, '*MSLOOP',
  "$env:windir\inf\netloop.inf", 0x1, [ref]$reboot)
Get-NetAdapter
```

It applies at once, with no reboot, and stays after reboots. To undo it, uninstall the adapter in
Device Manager. After that, make sure that `Get-NetRoute -DestinationPrefix '0.0.0.0/0'` returns
**nothing**. If a default route ever shows, the guest has a way out that the gateway does not
control.

## The backend: AppSandbox

[AppSandbox](https://github.com/jamesstringer90/appsandbox) is a headless daemon with an HTTP/JSON
API and a Python SDK, built directly on HCS/HCN (the layer that WSL2 uses). For this feature, **the
API is more important than all other properties**, because a GUI cannot be part of a loop that an
agent controls:

- **The GPU is one parameter.** `gpuMode=1` does the work of registry preparation, MMIO sizing and
  the injection of the host driver into the guest, and does it again after each driver update.
  (`0` is none, `2` tries each adapter.)
- **Snapshots are an API** (refer to [Backup and rollback](#backup-and-rollback), and its bug).
- **Network isolation is one parameter.** `networkMode=0` means no network adapter (`1` is NAT, `2`
  external, `3` internal). You can change it and `gpuMode` on a stopped VM.
- **No Hyper-V role.** It runs on each Windows 11 edition, also Home (*read*).
- **MIT licence**, as Draugr.

ExHyperV was the alternative, and we dropped it. It is a GUI with no CLI, GPL-3.0, and built on the
Hyper-V role, which forbids checkpoints on a VM with a GPU partition. It is still the better tool
for a human at a desk. It is not an option for a loop.

> ### The cost of this choice, stated plainly
> AppSandbox is **six months old, and the project of one person**, now at 0.1.8. Its author treats
> pull requests as "suggestions and examples of possible solutions", which the author is "unlikely to
> formally review or merge", and uses them as a reference for their own fix (*read*: the PR template
> of the repository). Thus the author fixes a bug that we find on their schedule, not ours. Draugr
> must work on **released** versions, never on a patched build that nobody else has.
>
> Two facts make that acceptable. The surface of `dr-forge` is *verbs* (`up`, `down`, `exec`,
> `snapshot`, `rollback`), so you can replace the backend. And the full feature is not visible
> unless `DRAUGR_FORGE` is set. This belonged in the **Standing risks** of `docs/DESIGN.md`, in
> words at least this strong, and **it is there now** *(written)*. It is a decision of its own, with
> the age of the backend and the snapshot bug as the two standing risks under it
> ([DESIGN.md](DESIGN.md#standing-risks)).
>
> One fact points the other way. AppSandbox ships **EV-Authenticode-signed binaries, with drivers
> signed by Microsoft attestation**. That does not make it mature. But it means that the maturity
> risk is about API changes and bugs, not about whether somebody is active.

### Getting it: the release zip

Use the release zip, not a build from source. It has three drivers: `AppSandboxVDD`, the display
driver, `AppSandboxVAD`, the audio driver, and `AppSandboxSHM`, a transport used only for Windows
guests on a Mac host. Those need Microsoft attestation, which needs an EV certificate on a hardware
token and a Partner Center Hardware account. A build without them makes test-signed drivers, which
retail Windows refuses to load. The release zip also has the SDK (`headless-api\asb.py`) at its
root.

If you ever need to patch AppSandbox itself, **rebuild only the user-mode parts, and use the signed
drivers of the release.** That is the own advice of the author: *"For regular app changes, reuse
the released drivers; don't rebuild them or install the WDK"*. It works because `AppSandbox.exe`
and `appsandbox_core.dll` have only a publisher signature, which Windows does not enforce for
user-mode code (*read*: `tools/sign/SIGNING.md` and the vcxproj files). The snapshot fix below is
that kind of change.

Keep a clone of the source anyway. Read `src/` when the API surprises you, as when we found the
snapshot bug. Also use it to pin the version that a test passed on. `dr-forge` never calls it.

---
## Network: no adapter, and egress through a gateway

**This is the main point, and it reverses the first draft of this plan.** That draft described the
forge as "not a mound, no default-deny egress". It planned a *maintenance mode* that changed the VM
to NAT for each install.

In its place, the VM has **no network adapter** (`networkMode=0`). It reaches the internet only
through an SSH reverse tunnel into a **gateway mound**, whose `sbx` policy is the allowlist. Thus the
same rules and the same tools filter the forge as a mound. `dr-policy --denied` shows what the VM
tried to reach, and a kit says what it can reach. Measured end to end: the Epic Games Launcher, Fab,
a 131 MB project download, the self-update of Visual Studio and Windows Update all went through it,
at full line speed. An administrator in the guest found no other way out.

The allowlist of this test ships as `kits/unreal` in the gateway template. Two results for the
forge as a whole:

- **Maintenance mode mostly disappears.** Updates, downloads and installs go through the gateway.
  Nobody measured whether a first engine install of ~100 GB must also go through it. Thus to set up
  a new base over NAT stays the known-good path.
- **The gateway is optional inside an optional feature.** A forge without one has **no egress**.
  That is the most locked-down configuration possible, and sufficient for a pure build loop after
  the engine install. Start with it.

### Two mounds, two policies

**The gateway is not the mound of the agent.** The agent works in the mound of the game project.
The gateway is a second mound that runs no agent, and only carries the traffic of the VM. One merged
mound looks simpler, but it costs three things:

- **Least privilege, in both directions.** The policy of each mound covers only its own traffic, and
  the rules of a kit stay with the sandbox that uses it *(measured: `kits/unreal` allows
  `docs.unrealengine.com` on the gateway, but a project mound gets a refusal)*. In one merged mound,
  the agent can reach all that the VM needs: the account and store services of Epic, Fab purchases,
  CDNs. The VM can reach all that the agent needs, starting with the AI endpoints.
- **Lifetimes.** The gateway must be up while the VM is up. The mound of the agent is stopped,
  recreated when its kit changes, and removed. As the gateway, each of those cuts the network of the
  VM, possibly during a build.
- **One forge, several projects.** A shared forge ([open question 1](#open-questions)) needs one
  gateway, for the agent of each project.

The cost is one more mound, 2 GiB of RAM, and one more thing to keep running. That is why
[`dr-up` in the project starts it](#commands).

**The project mound controls what the agent can read, not the gateway.** A project mound gets only
the defaults of `sbx` and its own kits. Those do not include the documentation of Epic, its forums,
Microsoft Learn or Stack Overflow *(measured: all four denied)*. Thus Unreal work needs two kits in
the project, and neither belongs to the gateway:

- **Unreal reference**, on by default for a forge project: `dev.epicgames.com`,
  `docs.unrealengine.com`, `forums.unrealengine.com`, and `learn.microsoft.com` with
  `docs.microsoft.com`, which redirects to it. That covers Visual Studio, the compiler and linker
  errors of MSVC, and the Windows APIs.
- **Coding guides**, generic, and in the kit library for any project: Stack Overflow and similar.

The agent reads them from its mound, not through a browser in the VM. That is faster, and it keeps
the look-ups inside the boundary that has the credential scan.

> **The allowlist works by name in the rule, but by address in practice.** A name that shares an IP
> with an allowed name resolves and connects, while `sbx policy check` reports it denied
> (*measured*). This is true of each mound, not only the gateway. Thus the corrections are fixes for
> all of Draugr, not only the forge.

---

## The channel: how the mound reaches the forge

AppSandbox gives no VM IP. With `sshEnabled` and `sshDeployKey` set at create, the daemon makes an
ed25519 key pair, and the guest agent installs the public key (*read*). The `sshd` of the guest is
then reached through a **loopback port on the Windows host** (`ssh_info(name)` reports it), carried
over Hyper-V sockets. That is why `networkMode=0` and working SSH can exist together.

**The measured path, with no `netsh`, no WSL address and no administrator rights on the host:**

- On the mound of the agent: `sbx policy allow network --sandbox <agent-mound> localhost:<SshPort>`.
- From inside it:
  `ssh -o ProxyCommand='socat - PROXY:gateway.docker.internal:%h:%p,proxyport=3128' -p <SshPort> <user>@host.docker.internal`

The full SSH handshake got through, and the test stopped at authentication on purpose. With a
`localhost:<port>` rule, `host.docker.internal` reaches a service bound to **Windows** `127.0.0.1`
through the proxy of the mound. Raw direct TCP does not.

The first draft planned `netsh interface portproxy` into WSL, then `DRAUGR_HOST_PORTS`, "with no
changes at all". Both halves were wrong. The path above needs neither, and `dr-hostport` opens the
address of WSL, not Windows loopback. That result also does not agree with what `dr-hostport`,
`CONFIG.md` and `SECURITY.md` tell each user now: that a service must listen on `0.0.0.0`. That is
why it is a correction for all of Draugr, and on the critical path of this feature.

Rules that go with it:

- **Only the SSH port, never the AppSandbox API.**
- **Password logins off first.** The `sshd` of the guest accepts passwords by default. Without that
  step, a mound with this rule can try to guess the password of the administrator.
- **Never write the relay port into a rule.** This page said that the port "has stayed constant
  across VM restarts, VM replacement and a host reboot (*measured*)". **That is no longer true, as
  measured two times in one day.** `vms.cfg` said 57351 while the guest was on 54501. The API itself
  answered 57351, then 57589 a few minutes later, with `sshState: 2` all the time. A rule with that
  port is old within the hour, and the clean-up of old `localhost:` rules is work that must not
  exist.

  Thus the port is **pinned on the host**: one `-L 127.0.0.1:18022:127.0.0.1:22` on the ssh of the
  supervisor, which already reads the relay port again on each reconnect. 18022 then never moves,
  the mound gets one rule (`localhost:18022`), and nothing must stay in sync. The number fits the
  existing scheme: 18888 proxy, 18445 SMB, 18022 ssh.

**Measured, hop by hop:**

| Hop | |
|---|---|
| WSL → mound | works. `*.sbx` is an ssh_config `ProxyCommand "sbx.exe ssh proxy %n"`, so the mound has **no IP**, and nobody can connect to a listener in it |
| mound carries a connection | works: `ssh -W localhost:12345` through the mound returned the answer of the far end. `socat` is also present |
| mound → Windows loopback | **closed.** 18888, 18445 and 19999 all refused from inside the mound, and no kit holds a `localhost:` rule. Raw TCP never works here. It goes through the own proxy of the mound, as in the `socat ... PROXY:gateway.docker.internal` line above |
| loopback 18022 → `sshd` of the guest | works: a test `-L` returned `SSH-2.0-OpenSSH_for_Windows_10.0` from 127.0.0.1:18022, which only the sshd of the guest can send |
| the end of the guest | `git 2.56.0`, `rsync` and `bash` are on the ssh PATH from `C:\msys64\usr\bin`. `git -C /c/Users` answered *"not a git repository"*, not *"cannot change to"*. Thus `/c/...` resolves to `C:\...`, and the mound-path convention applies to the VM unchanged |

**The password rule came first, then the rule.** Measured: the `sshd` of the guest reported
`passwordauthentication yes`. Thus it was turned off before the mound got anything, and it now
offers only `publickey`. Three traps on the way:

- **An addition at the end of `sshd_config` does nothing.** The default file of Windows ends with
  `Match Group administrators`, and all after a `Match` line depends on it. The added directives
  applied only to administrators. `sshd -T`, which reports the *global* configuration, still
  answered `passwordauthentication yes`, and the server still offered it. The directives go
  **above the first `Match` block**.
- **The listener holds the configuration.** A new connection does not read it again, so sshd needs a
  restart. A restart from a session that sshd serves can kill the restart halfway, and leave the
  guest with no sshd. Thus a one-shot SYSTEM scheduled task does the restart.
- **The restart is asynchronous, and the old listener answers while it waits.** Measured on the
  first provision of a new VM. The file was rewritten, `sshd -T` agreed, and the task started. But
  the next test still read `publickey,password,keyboard-interactive`, because the scheduler did not
  start the task yet. The listener restarted seconds later, and the guest accepted only keys.
  Nothing was wrong except the measurement. The same race was also able to *delete* the task, because the
  host removed it right after that single test returned. Thus the test polls for the **effect**, and
  accepts **only positive evidence**. During the restart, the connection is refused, and nothing is
  offered. "Nothing offered" must never mean "passwords are off".

**The recipe, working and measured end to end:**

```sshconfig
Host <vm name>
    HostName host.docker.internal
    Port 18022
    User forge
    IdentityFile ~/.ssh/draugr_forge_ed25519
    IdentitiesOnly yes
    ProxyCommand ssh -o BatchMode=yes <mound>.sbx socat - PROXY:gateway.docker.internal:%h:%p,proxyport=3128
```

The alias has the name of the VM, because `dr_sandbox_url` puts that in the URL. `socat` does the
CONNECT through the own proxy of the mound. Raw TCP to `host.docker.internal` does not work, and
`ProxyJump` tries exactly that. A **separate key**, made in WSL. ssh refuses a key read from
`/mnt/c`, where Windows files look world-readable. A second credential can also be revoked without
a change to the admin key on the Windows side.

With that in place, `git push ssh://<vm>/c/Temp/x.git` put commit `a088b64` into the guest, and the
own git of the guest read it back, SHA for SHA. Thus the mound-path convention applies, and the
normal git loop needs nothing special for the forge.

**Neither key stays after a VM start.** The daemon rewrites `administrators_authorized_keys` when
it starts a VM, and keeps only its own deploy key. The technique notes
[above](#technique-notes-that-cost-hours-to-find) give the details and the measurement. Thus the two
keys below are not installed once for each guest, but **installed again on each start**, by
`vm.ps1 -Mode keys` through the deploy key. That is the one credential that a just-started guest
always accepts. `-Mode start` runs it before anything waits for the admin key. `-Mode tunnel` runs
it before it starts or prods a supervisor. A long-lived supervisor retries on its own schedule, and
can arrive between a VM start and the key install. The log shows that as `Permission denied`, and
`up` reports it three steps later as a forward that never carried. `dr-layer provision` uses the
same mode for its own bootstrap. You can repair a guest by hand in the same way, with no full
provision run:

```powershell
powershell -ExecutionPolicy Bypass -File lib\forge\vm.ps1 -Mode keys -Vm forge-0
```

The useful result for layers: **a frozen base does not need working keys in it**, because the start
replaces the contents of that file.

**A live supervisor does not see a wider `permitopen`.** The tunnel key is restricted:
`restrict,port-forwarding`, and one `permitopen` for each destination. `sshd` reads those options
at **authentication time**, and keeps them for the life of the session. Thus a wider list does
nothing for a tunnel that is already connected. Measured on a VM built from a layer that was frozen
before `127.0.0.1:22` joined the list. The supervisor connected, the provision added the port, and
the session still refused it for forty minutes:

```text
ssh: channel 7: open failed: administratively prohibited: open failed
```

During that time, the listener stayed bound, and each test based on the port passed.
`dr-forge doctor --deep` reported **9 of 10 links green**, and blamed the mound. The answer was only
in the own log of the supervisor, `%LOCALAPPDATA%\Draugr\forge-tunnel.log`. Two results to keep:

- **A restart of the `sshd` of the guest does not clear it.** Windows OpenSSH serves each
  connection from its own `sshd.exe`, and `Restart-Service sshd` leaves those children running. This
  session stayed through three restarts, with its old options intact.
- **An end of the `ssh` child of the supervisor clears it**, and that is the own recovery path of
  the supervisor. The loop logs `ssh exited`, reconnects within ten seconds, and authenticates again
  against the current file. `forge-vm-setup.ps1` does this itself, but only when the options really
  changed, and only for a supervisor that serves the VM under provision.

### Control plane and data plane, split

The API of the daemon is on host loopback, behind a **random bearer token in a discovery file**.
That token must never enter the mound:

| | Who holds it | What it can do |
|---|---|---|
| **Control plane** | Draugr, on the host, in WSL | create, start, stop, snapshot, branch, delete VMs |
| **Data plane** | the agent, in the mound | one ssh channel to one port |

The agent can build, test and read results. It cannot create a VM, delete one, roll one back, or
ask the daemon anything. That is the same division that Draugr already makes around `sbx`, which the
agent never had a way to run either.

### What crosses

| | |
|---|---|
| `dr-forge exec '<cmd>'` | run it in the guest, with the output streamed back |
| `dr-sync`, `dr-send`, `dr-merge`, `dr-status` | the git loop, unchanged, with the VM as the far end |
| `dr-data push` / `pull` | the file loop, same far end: logs, cooked artifacts, screenshots |

Draugr already runs a git loop and an rsync loop over ssh to a different machine. The forge is
another far end, not another mechanism. **The code and the data are in the VM.** Thus these are the
normal commands, not special forge commands. `dr-forge` owns only what is specific to the VM: its
state, its liveness chain, its layers, and a command run inside it.

`dr-forge push` and `pull` exist, but as the **file-level tool** under that, not as the data loop.
They move one path in or out, over the same ssh relay. `dr-data` will use them when it can address
the VM. They are useful meanwhile, because nothing else can move a file. If you want them to move a
repository, use the git loop.

---
## How the agent works the UI

### Most of the loop needs no UI at all

| Task | Where it happens | Needs the desktop? |
|---|---|---|
| Install or update the engine, sign in | only the Epic Games Launcher | **yes** |
| Some Fab items, such as engine plugins | the Launcher | **yes** |
| Create a project | the **Project Browser** of the editor, not the Launcher | **yes**, in the editor |
| Add Fab assets to a project | the **Fab window** of the editor, on by default in 5.8 | **yes**, in the editor |
| Change the configuration of a project | `.uproject` (JSON) and `Config/*.ini` | no: text files |
| Delete a project | it is a folder | no |
| C++: edit, build, run | source files and `UnrealBuildTool` (*measured*, above) | **no** |
| C++: debug | the debugger of Visual Studio, or `cdb` headless (*unmeasured*) | usually |

Thus the core C++ loop (edit in the mound, push, build, run, read the logs) needs no desktop and no
Visual Studio UI. **But the work does not start there.** It starts in the Launcher, which has no
official automation, and continues in the Project Browser and Fab window of the editor. **Desktop
automation is the main target**, and the editor needs it as much as the Launcher.

### Putting a screen in front of a human

Not through the API. `open_display` crashes the daemon for this VM (above), and the GUI of
AppSandbox takes the API away while it is open. The way that works is a **VNC server inside the
guest, bound to loopback, reached over the same ssh channel**. One action on the host starts the
daemon, starts the VM, forwards the port, opens the viewer, and removes the forward afterwards. The
VM stays up, and the agent keeps the API. Thus a human who looks at the screen interrupts nothing.

**That is now `dr-forge up --screen`, and `dr-forge screen` on a forge that is up** *(built)*.
Draugr owns the full sequence, so it does not need the gateway script. The start already belonged to
`up`, and the screen is the last step, after the guest has a way out.

**It does not block.** The screen is the last thing that `up` does, so nothing is left to wait for.
But the forward must still come down when the viewer closes. Thus something must stay after the
command, and watch. That is `lib/forge/screen.ps1`, started detached and hidden. `up` waits only for
the forward to answer, then returns, and leaves the viewer to the human. It is detached, so it has
no console. Thus it logs to `%LOCALAPPDATA%\Draugr\forge-screen.log`. `up` reports a screen that
failed to open, and does not claim one that did not open.

A failed screen is **not** a failed `up`. At that time, all that `up` had to do already runs, and a
failure of the command describes the forge wrongly.

**Why a forward is necessary**, though the viewer and AppSandbox are both on this one host. The guest
has **no network adapter** (`networkMode=0`), so it has no address to connect to. That is the same
reason why its egress must be a reverse tunnel. The ssh relay of AppSandbox over Hyper-V sockets is
the only channel in or out. Thus to reach a port inside the guest, you must forward through it.
There is no shorter path. The one direct route that the daemon gives, `open_display`, crashes it for
a GPU-PV VM. That is why a VNC server inside the guest exists at all.

The forward is **temporary, and on the admin key**. It is not in the permanent set of the
supervisor. The restricted tunnel key needs another `permitopen` for it. That makes a narrow key
wider, on purpose, and a VNC port on host loopback then stays open, whether or not anyone looks.
This way, it lasts exactly as long as the viewer.

`forge-screen.ps1` still does one thing that Draugr does not: it starts the daemon **elevated**. A
scheduled `AppSandbox.exe --headless` at logon covers that. After that, the script has no job.

It shares the **console session**. Autologin creates that session, and UI Automation controls it.
That is a feature, not a compromise: the human sees exactly what the agent sees. RDP is the clear
choice, but it is not available, because this guest is Windows Home.

*Measured: `RFB 003.008` through the forward, and a screenshot from inside the guest that shows a
drawn 1920×1080 desktop in session 1.*

### Session 0: why ssh alone cannot do it

The `sshd` of Windows runs each session in Session 0, the non-interactive services session. The
APIs that see and control windows (UI Automation, `EnumWindows`, `BitBlt`) work for one desktop.
Session 0 has none, so they see nothing (*read*: [the documentation of
Cua](https://cua.ai/docs/how-to-guides/driver/windows-ssh) and
[Win32-OpenSSH #998](https://github.com/PowerShell/Win32-OpenSSH/issues/998)). Two results:

- **All that touches the UI runs as a helper in the session of the user**, usually a Scheduled Task
  with an interactive logon. The ssh side only relays to it.
- **The agent must not start GUI programs over ssh.** They start in Session 0, where nobody can see
  them, also not the agent.

Both need a signed-in, unlocked desktop. Thus the guest needs automatic login. AppSandbox 0.1.8
keeps it working ("Keep Windows VM automatic login and passwords from expiring", *read*).

**The relay exists, and the full loop works** *(measured)*. From WSL, with no desktop and no MCP
client in the path:

```text
dr-forge exec draugr-shot   ->  schtasks runs the task in session 1  ->  C:\Draugr\shot.png
dr-forge pull C:\Draugr\shot.png  ->  1920x1080 PNG on the host, legible
```

The file was new, not an old one. The previous `shot.png` of the guest was from 4 October. The
pulled file had the current timestamp, and the taskbar clock in the image agreed. An agent really
needs that loop. It cannot look at a screen, so a file on the host is the only way to test anything
visual.

**The capture half belongs to Draugr** *(gap found and closed)*. Before, it did not.
`draugr-shot.cmd` and its `capture.ps1` came into this layer from an installer **outside Draugr**.
Thus a forge built from a layer without it had no `draugr-shot`. That was a gap, not a boundary. The
desktop camera is already listed [above](#which-directories-exist-and-which-of-them-you-keep) with
the components that layer-0 always holds. The test is *does a Windows VM built for a different
purpose want this?*, and the answer is clearly yes. An agent that cannot see the screen is the
general case, not the Unreal case. Nothing about it is specific to an engine.

Thus it is here now, by the same route as the other four guest scripts *(built)*:

- **Draugr ships its own copy**, `lib/forge/guest/install-shot.ps1`, beside `harden-sshd.ps1`,
  `install-tunnel-key.ps1`, `authorize-key.ps1` and `set-computer-name.ps1`. All of those came from
  the gateway in the same way. The forge got nothing from a reach into the directory of another
  project for them.
- **The provision of layer-0 runs it.** An unconditional component belongs there. It is paid for
  once in the frozen base, not in the writable disk of each child.
- **`init` installs it when the layer is older than it.** That is the full reason for `init`. It
  applies what must be true for *this* VM, on VMs built from layers that you cannot rebuild.

**It is not an exact copy of the file of the gateway, and the difference is `DRAUGR_CHANGED`.** The
guest scripts of Draugr end with a statement of whether they changed anything. That lets `init`
report *installed* apart from *already installed*. The copy of the gateway had no such marker,
because nothing there needed one. To say it honestly, the idempotence must be real. Thus both
generated files are **compared before they are written**, and the task is registered **only when
absent**. A `Set-Content` or a `Register-ScheduledTask -Force` that wrote identical content again
makes each new run report a change. That is how a summary starts to lie. The phase is **not**
optional, unlike the churn phase. An agent that cannot photograph the screen cannot test its own
work.

**It needs a line in `SECURITY.md`**, in the conditional forge section (track C item 11). The camera
is a scheduled task with an **interactive** principal. It photographs all that is on the desktop of
the guest, and `pull` carries the image to the host. That is the intent of the forge, not a leak.
But a task that can see all that a signed-in user sees must be written down with the other trust
decisions, and not found later in a guest.

### Desktop automation, through MCP

The mechanism: a **Windows MCP server** in the user session of the guest, reached over an ssh port
forward on the existing channel of the agent. Several exist, and they see the screen in different
ways: [Windows-MCP](https://github.com/CursorTouch/Windows-MCP),
[windows-mcp-server](https://github.com/deploymenttheory/windows-mcp-server) (UI Automation tree),
and the driver of Cua (which solves Session 0 explicitly with a Scheduled Task and a named pipe).

**The protocol makes it work for each agent.** Claude Code, Codex, Cursor, Gemini CLI and OpenCode
all speak MCP. Thus the mechanism (an ssh forward to an MCP endpoint in the guest) is the same for
each agent. Only the way that each agent registers a server is different, and Draugr already has a
place for differences between agents: `lib/agents/<agent>.sh`.

### What the tree actually sees *(measured)*

The open question was Slate, and it is now answered. The probe ran in **session 1** of the guest, on
the virtual display of AppSandbox, with **no host viewer attached**. That also answers a second
question: UI Automation does not need anyone to look.

| application | framework | window | elements to depth 6 |
|---|---|---|---|
| Character Map | Win32 | — | named elements in all places |
| Notepad | XAML | — | named, after a walk with a `TreeWalker` |
| **Visual Studio 2022** | WPF | `class='Window' name='Microsoft Visual Studio'` | **50**, with `Button 'Create a new project'`, `Button 'Clone a repository'`, `Button 'Continue without code'`, `Button 'Open a project or solution'` |
| **Epic Games Launcher** | Slate + CEF | `class='UnrealWindow'` | **0** |
| **Unreal Editor 5.8** | Slate | `class='UnrealWindow' name='Unreal Engine 5.8'` | **0** |

Two windows of five are opaque, and they are the two of Epic. The split is **not** native against
web. It is *who owns the drawing*. All that a Microsoft framework draws can be automated by name.
All that Epic draws itself is a rectangle of pixels, with no tree inside it.

The Launcher also refuses the other semantic door. Started with `--remote-debugging-port=9222`, it
opened no endpoint, on that port or on 9223, and no Epic process listened in any place. Thus its
embedded Chromium is not reachable by [CDP](#the-ladder-of-doors) either.

### The ladder of doors

Try each task at the cheapest rung that works. Only the top rung needs a model to look at pixels:

| rung | the door | cost | measured here |
|---|---|---|---|
| **1** | silent switches, CLI, configuration files | none | the full C++ loop. `.uproject` and `Config/*.ini` |
| **2** | in-app scripting: Unreal Python, Remote Control, the [5.8 MCP plugin](#an-optimisation-not-the-target-unreals-own-mcp-plugin) | a configuration value | only the editor, and the work is there |
| **3** | Chrome DevTools, on an embedded browser | none when it answers | **Launcher: refused** |
| **4** | the UI Automation tree: elements by name | cheap, deterministic, no model | **Win32, XAML, WPF: yes. Slate: nothing** |
| **5** | pixels and a vision model | a model call for each step | not attempted: rung 4 covers the important cases |

Thus the plan needs no vision model. It needs rung 4 for **installers, dialogs and Visual Studio**,
rung 2 for the editor, and a human for the Launcher. That costs nothing extra, because the sign-in
and the engine install are already the one step that [the credential decision](#security) keeps in
your hands.

### Discovery is expensive; repetition should not be

To find the path through a GUI is the part that is worth a tree walk, a screenshot or a person. To
*replay* it is not. After you know the path, freeze it in a script: an AutoHotkey file, or the same
UIA calls without the search. It runs in milliseconds with no model in the loop, and is tied to the
application and version that it was recorded on.

The honest limit: a frozen path for a **Slate** window can only be coordinates. Coordinates break on
a version change, a DPI change or a resized window. Thus a replay script pins the window size, makes
a cheap test afterwards, and treats a break as normal. The fallback is to find the path again, not
to fail the task.
### Technique notes that cost hours to find

- **`StrictHostKeyChecking=accept-new` accepts an UNKNOWN host, and correctly refuses a CHANGED
  one. A pinned port always gives a changed one** *(measured)*. `127.0.0.1:18022` is pinned on
  purpose, so that the mound has one rule, not one for each VM
  ([above](#the-pinned-port-has-a-price-a-far-end-is-not-identified-by-the-vm-being-up)). Thus each
  guest that was ever served shows a different host key at the same address, one after the other.
  `known_hosts` keeps one entry for each address, so the second guest fails:

  | connected to | result |
  |---|---|
  | `127.0.0.1:18022`, as `Test-Forward` does it | **rc=255**, `REMOTE HOST IDENTIFICATION HAS CHANGED!` |
  | `127.0.0.1:<relay>`, same guest, same key | rc=0 |
  | `127.0.0.1:18022` with `-o HostKeyAlias=draugr-forge-0` | rc=0 |

  **The forward carried all the time.** `dr-forge up` waited its full 300 s, and reported *"the
  forward never carried"*. But the own log of the supervisor showed that it connected at
  `10:03:53`, and held the forwards until the next stop of the VM. The tested part was healthy. The
  **test** was broken, and it reported its own failure as a failure of the far end. We spent two
  days on the keys before this. They were a real and separate fault. A pinned port makes an
  unrelated defect and this one give the same sentence.

  The fix is `HostKeyAlias`. It keys the host-key memory by a name that Draugr selects,
  `draugr-<vm>`, not by a socket address. That also settles the RELAY port, whose number the daemon
  changes, and which `probe.ps1` already ignored: *"the relay port moves, so a pinned key for
  127.0.0.1:<port> is wrong more often than it is right"*. With an alias, neither port needs that
  excuse. **The purpose is not to silence the warning, but to give it a meaning.** Today a real key
  change at `18022` looks the same as "the forward serves a different VM". Thus the only way past it
  is to stop the test, and `no` hides this case and each real one with it.
- **AppSandbox rewrites the `administrators_authorized_keys` of the guest at each VM start, and
  keeps only its own deploy key** *(measured)*. Three keys were in that file: `appsandbox`,
  `draugr_admin_ed25519`, `draugr-tunnel`. One stop and start through the daemon left one:

  | | bytes | lines | file mtime |
  |---|---|---|---|
  | after the boot in the morning | 93 | `appsandbox` | boot **+8 s** |
  | our two keys put back by hand | 292 | `appsandbox, draugr_admin_ed25519, draugr-tunnel` | admin key accepted |
  | after one stop and start | 93 | `appsandbox` | boot **+7 s** |

  Thus a VM that just started trusts the key of the daemon, and nothing else. Three results follow,
  and the third is the important one for layers:

  * **`dr-forge up` did not work on a stopped VM**, and after a host reboot, each VM is stopped.
    Nothing in that path put our keys back. It stayed hidden for a month, because
    `dr-layer provision` runs its keys phase on *each* call, and repaired this each time. `up` was
    only the first path that started a VM with no provision behind it.
  * **The tunnel was collateral damage, not a second fault.** `18765` and `18000` were down,
    because the supervisor authenticates with the key that the same rewrite removes. One cause,
    three symptoms. If you chase them separately, you lose an afternoon.
  * **Keys in a frozen layer give nothing**, because the start rewrites the file. A base image does
    not need working keys in it, and each boot of each layer above it needs the same bootstrap. That
    is at least uniform, and much better to know before a freeze.

  The fix: the start path installs them. `vm.ps1 -Mode keys` waits for **the credential that the
  guest accepts**, and runs `guest/authorize-key.ps1` and `guest/install-tunnel-key.ps1` through
  that one. Both already existed for this. In each round, it tries the admin key before the deploy
  key. If the admin key answers, nothing was removed, and there is nothing to restore.

  **A wait for only the deploy key was wrong, and the first version did exactly that.** A VM made by
  `dr-layer new` from a frozen layer has no deploy key. `New-VmBlock` writes neither `SshDeployKey`
  nor `SshPubKey`. Thus that wait always timed out: **the full 300 s on each `dr-forge up`**, before
  it fell through to an admin key that worked all the time. Each VM built on the engine layers paid
  it. `-Mode start` calls it before it waits for the admin key. `provision.ps1` uses it, and does not
  keep the second copy of append-plus-`icacls` that it had inline before.
- **A wait that discards its own diagnosis misleads its reader** *(measured, same incident)*.
  `Wait-GuestCommand` ran `cmd /c echo DRAUGR_OK`, matched the output for that token, and dropped
  all else. Thus sixty refusals over five minutes were reported as **"the VM did not answer a
  command within 300 s (state: online)"**. That sentence describes a guest that does not answer. The
  guest answered each time, and said `Permission denied (publickey,password,keyboard-interactive)`.
  The reader then examined the VM state, the disk and whether `chkdsk` ran. None of those was
  involved, and `fsutil dirty query C:` said that the volume was clean. The necessary sentence was
  in a variable that it threw away. It now keeps the last reply, and says which case happened:
  *refused the key*, *did not accept a connection* or *said nothing at all*. **A timeout is a shape
  of failure, not a cause. A report of a timeout in place of the cause sends people to the wrong half
  of the system.**
- **In a `Stop` script, a redirect of the stderr of a native command makes each stderr line a
  terminating error** *(measured)*. `install-shot.ps1` asked
  `schtasks /query /tn draugr-shot /fo list 2>$null` whether the task already existed, to register
  it **only when absent**. On a guest without it (each first install), `schtasks` wrote *"ERROR:
  The system cannot find the file specified."* to stderr. PowerShell 5.1 wrapped that line as a
  `NativeCommandError`, and `Stop` made it terminating. **The guard that exists to find "not there
  yet" did not run when the thing was not there.** Measured in the guest, task absent, `Stop` in
  force:

  | form | result |
  |---|---|
  | `schtasks /query /tn draugr-shot /fo list 2>$null` | **THREW**: `NativeCommandError` |
  | `Get-ScheduledTask -TaskName draugr-shot -ErrorAction SilentlyContinue` | `$null`, no error |

  The *redirect* causes it. Native stderr with no redirect passes through with no harm. Eight
  places in `lib/forge` redirect native stderr with `Stop` in force. The three of `provision.ps1`
  are already safe, because they are inside its own `Invoke-Native` helper. That helper saves the
  preference, sets `Continue`, runs the block, and restores it. The other five were not safe. Three
  more files each met this separately, and fixed it in place: `mount-vault.ps1`,
  `install-netfx3.ps1` and `install-vscode.ps1` all have their own save and restore, and one has a
  comment that explains the full mechanism. **A lesson learned three times in three files is a rule
  that does not exist.** Thus it is a rule now: `tests/lint-native-stderr.sh`. Two of the five
  needed no guard. A cmdlet answered the question that a native command had to answer.
- **`uv python install` with no version takes the newest CPython, which has the fewest wheels**
  *(measured)*. `install-automation.ps1` asked for an interpreter with no pin, and got **3.15.2**.
  `uv tool install windows-mcp` then resolved `pyyaml==6.0.3`, found no `cp315` wheel, tried to
  build it from source, and stopped on *"Microsoft Visual C++ 14.0 or greater is required"*. The
  guest has no compiler, on purpose. On PyPI that day, PyYAML 6.0.3 had `cp313` and `cp314` Windows
  wheels, and **no `cp315`**. The own comments of the script record `CPython 3.14` and
  `Python 3.14.8` as measured. Thus it worked until the release of 3.15, then broke with no change
  on this side. An interpreter with no pin in a base image is **a build that breaks on a date that
  somebody else selects**. Thus the request is pinned to **3.14**: the newest with wheels. A frozen
  base also wants a repeatable interpreter. The pin is one variable at the top of the script,
  because the next CPython makes it wrong in the other direction. Look at a pin again later, and do
  not forget it.
- **A test after the reboot that it documents reads a guest that shuts down** *(measured)*.
  `vault-access.ps1` restarts the guest, for its own reason: `srv2` and `srvnet` hold port 445
  until a restart. Seven lines later, it asked that guest over ssh whether `EnableLinkedConnections`
  was set. The answer was empty, and the script printed **"EnableLinkedConnections is not set in
  this guest ('')"**, about a guest where it was `1`. `install-guest-base.ps1` set it earlier in the
  same run. The same command on the same guest while it is up returns `1`, and so does an
  `-EncodedCommand` form. Thus the shape of the command was correct, but the order was wrong.
  **Read a fact before the restart that makes it true, and treat an unreadable answer as
  unreadable.** `''` is not `0`. A test that cannot pass costs exactly as much as a test that
  cannot fail, in the opposite direction. This one sent a reader to fix a value that was already
  correct.
- **Plain double quotes around a remote path lose their BACKSLASHES, but only when the script
  starts from WSL** *(measured)*. `provision.ps1` sent `-File "C:\Windows\Temp\x.ps1"` over ssh,
  and the guest got `C:WindowsTempx.ps1`. The same three forms, same guest, two launch contexts:

  | form | from Windows PowerShell | from WSL bash → `powershell.exe` |
  |---|---|---|
  | `-File "$remote"` | intact | `C:WindowsTempx.ps1`: **eaten** |
  | `-File \"$remote\"` | intact | intact |
  | `-File $remote` | intact | intact |

  **The launch context is why it survived the adoption.** The copy of the gateway was typed in a
  Windows PowerShell, where the bug does not exist, and `bin/dr-layer` runs it from bash. A comment
  in `provision.ps1` said that the plain quotes were safe *because the path has no space in it*.
  That is true about spaces, but the wrong conclusion. **Quote because a measurement shows that the
  quoting survives, never because the value looks harmless.**
- **`powershell -File <missing>` exits 0** *(measured)*. It writes *"The argument '…' to the -File
  parameter does not exist"* to stderr, and returns zero. Thus a path that never resolved looks the
  same as a phase that worked. That made the quoting bug above into **fourteen green rows** in a
  summary. Real codes do pass through: a guest script that exits 4 arrives as 4 through the same
  pipeline. Thus the gap was only this one case. `Invoke-GuestScript` now lets the own `cmd` of the
  guest decide with `if exist`. It gives absence the code **127**, and throws on it, and does not
  return it.
- **A Cygwin `curl` eats the braces out of `-w '%{http_code}'`** *(measured)*. That killed the one
  test that proves that the guest can reach the internet:

  | `curl.exe` | `-w '%{http_code}'` returns |
  |---|---|
  | `C:\Windows\System32\curl.exe` (Windows 8.18.0) | `500`: a real code |
  | `C:\msys64\usr\bin\curl.exe` (Cygwin 8.22.0) | `%http_code` |

  Bare `curl.exe` resolves to the Cygwin build, because `install-base-tools.ps1` puts
  `C:\msys64\usr\bin` on the machine PATH just before `System32`. The own comment of that decision
  reasons carefully about `find`, `sort`, `link` and `ssh`, and **does not mention `curl`**. Thus
  `preflight.ps1` compared the literal string `%http_code` with `000`, which never matches. It
  reported **egress OK against a proxy on port 9**. The `exit 5` of phase 6 of `provision`, the
  guard that stops an hour of downloads, was dead from the time that MSYS2 reached the PATH. The
  rule for all else in the guest: **if the output format is important, name the binary by absolute
  path.** The `curl.exe` of `post-up` has no problem. It runs on the host in WSL, where MSYS2 is not
  on PATH, and it returned a real `403` in the same run.
- **A test that cannot fail is worse than no test**, and two of the three above have that shape.
  `preflight.ps1` now makes sure that the answer *looks like* a status code before it believes it.
  It reports a broken probe (**exit 3**) separately from no egress (exit 1), because the first is
  the fault of this project, and the second is not.
- **`cmd /c echo %VAR%` over ssh comes back with a trailing `"`** *(measured)*. Windows OpenSSH
  quotes the command line again when it sends it, so the remote `cmd` gets a stray quote. `echo`
  prints its argument literally, junk included. The name of the guest read back as `TEST"`, and
  `init` reported a rename that clearly worked as one that did not. Each command that **parses** its
  arguments has no problem. Thus `cmd /c hostname` answers cleanly, and so does
  `powershell -Command`. The `cmd /c echo DRAUGR_*` probes in other places in `lib/forge` are safe
  only because they **match a marker as a substring**, and do not capture a value. To read a value
  back, you need the other form.
- **`return @($x)` does not survive the return** *(measured)*. PowerShell unrolls an array with one
  element on the way out of a function. Thus the caller gets the bare element, and its `.Count` is
  **empty, not 1**. Two or more elements stay an `Object[]` and count correctly, and that hides the
  bug. It breaks only with one element, which is the normal case for one baseline with one branch.
  Callers must wrap it again: `@(Real ...)`.
- **Do not call `FindAll(TreeScope::Descendants)`** on an unknown window. On XAML Notepad, it threw
  `E_UNEXPECTED`, and returned nothing. Walk with `TreeWalker::ControlViewWalker` and a depth limit.
  The depth limit also stops the tree of Visual Studio from taking a minute.
- **Each P/Invoke string needs `CharSet = CharSet.Unicode`.** Without it, `GetWindowTextW` and
  `GetClassNameW` marshal as ANSI, and each title comes back as a single character. That is a wrong
  answer that looks like a working probe.
- **A transient scheduled task reaches session 1 of the guest** (`schtasks /create /it` → `/run` →
  wait → `/delete`), started from the ssh session in session 0. The MCP server needs this mechanism
  anyway. `windows-mcp install` registers exactly such a task itself, and that is most of the reason
  why we selected it.
- **`powershell -Command -` runs stdin line by line**, as if typed at a prompt. Thus a multi-line
  `foreach (...) {` block reads as incomplete, and the rest of the script disappears: exit code 0,
  no output, nothing to read. Three scripts "succeeded" that way before we saw it. Control the guest
  with `-EncodedCommand` (one UTF-16LE base64 blob) or `-File`, never with piped stdin.
- **A port that WSL can bind is not always a port that Windows can reach** *(measured)*. Hyper-V
  reserves blocks of the dynamic range of Windows. `netsh int ipv4 show excludedportrange
  protocol=tcp` listed about 1260 ports on this machine, in blocks of a hundred from 49684 up.
  Nothing on Windows can bind one, so the localhost relay of WSL2 never publishes it. Inside WSL, the
  port is perfect: the listener binds, and `curl` on the same side answers. From Windows, `connect`
  fails. It takes ~2.1 s to say so, because Windows retries the SYN. A published port answers within
  40 ms of its answer on the WSL side. `netstat -ano` shows **no socket**, because the relay never
  bound it, so there is nothing to find. WSL cannot see the exclusions, so **no picker there can
  avoid them**. Probe the port from the side that connects to it, and discard a port that does not
  answer. Do not wait for it. This cost a day as a flake in `tests/forge-api.bats`. Three of ten
  tests failed in about one of two full-suite runs, and none failed when the file ran alone. The
  mock bound a port, answered the readiness probe on the WSL side, and then `powershell.exe` did
  not reach it. `snap.ps1` reports that as exit 10, "nothing answers". The wrong diagnoses that it
  invites all sound reasonable: the daemon died, the client timeout is too short, the relay is late
  after the bind.
- **Windows lets a second process bind a port that is already bound.** `ssh` sets `SO_REUSEADDR`.
  Thus a second tunnel supervisor takes the same `-L` port with no error, and the two take turns to
  answer. Measured with two identical supervisors that held one forward. A named mutex in the
  supervisor is the only part that notices, **and it does not notice across sessions.** Measured:
  the logon task runs its supervisor in session 0, and creates `Global\Draugr.forge.tunnel` there.
  The default DACL of a token allows its own *logon SID*, and logon SIDs are different in each
  session. Thus the same user gets a refusal when that user opens that mutex from an interactive
  session. `vm-tunnel.ps1` reads the refusal as "guard unavailable", and continues. That leaves two
  supervisors running, which is the one state that the mutex exists to prevent. The refusal is worth
  more than it looks. A mutex exists only while a process holds a handle. Thus a refusal is
  *positive* evidence of a second supervisor, and it is now the single case that the guard ignores.
  `dr-forge` reports it as `tunnel_mutex=other-session`. The fix in the supervisor is an explicit
  DACL for the current user, and a separate catch of `UnauthorizedAccessException`, apart from
  "cannot create it at all".
- **A "stopped" server that still holds its log files stops the next one from starting.**
  `windows-mcp uninstall` printed *"Stopped the running server"*, and left it running. The
  `start-server.cmd` of the replacement did not open its `>>` redirects. cmd exited 1, and nothing
  wrote a message about it in any place. Meanwhile, the old server still answered on the old port.
  Stop servers by process path, and make sure that the port is free before you start another.
### Which server, then

A tree-based server is sufficient for what the tree can see. Screenshots of a Slate window give
nothing that a coordinate script cannot do more cheaply. Thus the list of requirements becomes
short: run in session 1, expose the UIA tree, send clicks and keys to a named window, and take a
screenshot on request. The own MCP plugin of the editor serves the editor beside it, not through the
desktop.

### An optimisation, not the target: Unreal's own MCP plugin

UE 5.8 ships an official **Unreal MCP** plugin (*Experimental*). It is an MCP server inside the
editor process, at `http://127.0.0.1:8000/mcp`, with tools for actors, lighting, materials, Slate
widget inspection and automation tests (*read*: [the documentation of
Epic](https://dev.epicgames.com/documentation/unreal-engine/unreal-mcp-in-unreal-editor)). Where it
covers a task, it is better than clicks. It needs no pixels, and it runs inside the editor, so it is
in the session of the user by design. It does not reach the Launcher, and it is off by default.

It has **no authentication**, and Epic says that it is "not safe to expose beyond the local
machine". An ssh forward that only the authenticated channel of the agent can reach is the right
shape for it. A published port is not. The `lib/forge/tunnel.ps1` of Draugr already carries host
`18000` → guest `8000` for it, and the desktop MCP server moved to 8765, so that the two never
collide. A local forward costs nothing while no editor runs, because `-L` connects to the target
only when a client connects.

### Considered: Claude Desktop's computer use

Claude Desktop can now control a Windows desktop. It does not fit here (*read*: [the help article
of Anthropic](https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork)):

- **It controls only the machine where it runs**, from the Desktop app, with no API or MCP interface
  for another process. It must run *inside* the VM. That is a second agent, signed in to your Claude
  account in the guest, that the agent in the mound cannot control. An agent inside the forge is
  already [rejected](#considered-and-rejected).
- **It asks for permission for each new application**, with no documented pre-approval. That needs
  a human at the screen.
- **It is beta, only on Pro and Max plans**, and only for Claude. That is against the design of
  Draugr, which works for each agent.

What it gives (work from screenshots) is a capability of the *model*, not the app. A Windows MCP
server that returns screenshots gives the same thing to the agent in the mound.

---

## Backup and rollback

The snapshot API of AppSandbox, as documented:

| | |
|---|---|
| `snap_take(name, snapname)` | take a snapshot. **The VM must be stopped** |
| `start(name, snap_index=N, branch_name="x")` | boot a *branch*: a writable disk forked from that snapshot |
| `start(name, snap_index=-2, branch_name="x")` | branch directly from the base disk |
| `snap_delete` / `snap_delete_branch` | discard a snapshot, or one branch of it |

You cannot delete the base disk itself (*read*). That is the right default for the thing that you
most want to keep.

### It has a bug that decides the design

**Only the first snapshot captures the current state of the VM.** `snapshot_take` builds each
snapshot as a differencing child of the disk recorded at the *first* snapshot. It never uses the
disk that the VM runs on. Then it switches the VM onto a new branch of it (*read*:
`src/backend_win/snapshot.c`, still present in 0.1.8):

```c
hr = vhdx_create_differencing(vhdx_path, tree->base_vhdx);
```

Thus a second snapshot silently saves the old baseline, and the work of the VM since then stays
behind on a branch that nobody knows about. The work is not deleted. If you select that branch
again, it comes back. But the snapshot does not contain it.

The fix is not one line. If a snapshot becomes a child of the *current* disk, that disk becomes a
parent, and nothing must write to it again. But AppSandbox still lists it as a branch that you can
boot, and a boot of it corrupts each later snapshot. How to prevent that is a data-model decision
for the author. It is reported upstream as
[#152](https://github.com/jamesstringer90/appsandbox/issues/152), with a tested fix offered as a
suggestion, [#199](https://github.com/jamesstringer90/appsandbox/pull/199), in the form that the
author asks for. The fix freezes the branch of the VM as the new snapshot, and continues on a new
branch of it.

**Until a release fixes it, `dr-forge` uses a single baseline.** The first snapshot is correct.
Thus:

- `dr-forge base` takes the baseline **once**, and refuses to take a second one.
- `dr-forge rollback` discards the working branch, and starts a new one from that baseline.
- A move of the baseline forward waits for upstream.

If the first snapshot also fails with the GPU attached, the fallback is to stop the VM and copy its
disk file. That takes minutes, not seconds. It happens behind the back of AppSandbox, and is
*unmeasured*.

> **Until the fix ships, never take a snapshot of a VM that holds work that you did not save in a
> different place.** This bug already left real work behind on this machine.

### Two properties of rollback, whatever the implementation

- **A rollback is for the full machine, so it also discards the derived data cache.** You get back
  what is in the baseline. An earlier version of this section said that you must therefore take the
  baseline **after a warm build**. That was advice with no measurement. It is now an open question,
  because the saving depends fully on how much of the cache a rollback invalidates anyway. A warm DDC
  inside the baseline helps only if the discarded work did not already make it old. Nobody measured
  that. The first baseline on this machine was taken cold, with no clear harm. Take it when it is
  convenient. If somebody later measures the difference, put that number here.
- **Snapshots need the VM stopped.** Thus `base` and `rollback` both cause a stop, and both say so
  before it.

### The call sequence was read, not guessed *(built)*

The gate on this item was whether to wait for the upstream fix (then #153, now
[#199](https://github.com/jamesstringer90/appsandbox/pull/199)). The answer is **no**. It was still
open with no answer, and the single-baseline design above needs nothing from it. A wait left the
forge with no undo for more than a month.

The four calls came from the client, and from the worked example that AppSandbox ships at
`C:\AppSandbox\headless-api\`: `asb.py` and `examples\full_lifecycle.py`. They did not come from
the shape of the calls near them. That habit cost a failed `dr-forge rm` and a 405 the day before:

| | |
|---|---|
| `GET /vms/<n>/snapshots` | `{snapshots:[{index,name,branchCount,branches}], baseBranches, current:{snapIndex,branchIndex}}` |
| `POST /vms/<n>/snapshots` `{"name":…}` | take one. The VM must be **stopped**, else `409` |
| `POST /vms/<n>/start` `{"snapIndex":i,"branchName":n}` | the **only** way to make a branch |
| `DELETE /vms/<n>/snapshots/<i>/branches/<b>` | drop one branch. The VM must be stopped |

**Two of those decide the design, and we did not choose either.** A *boot* from a snapshot creates a
branch. Thus `rollback` cannot leave the VM stopped. It ends with the VM running. And you can delete
a branch only while the VM is stopped. Thus the old branch must go **before** the start of the new
one. `full_lifecycle.py` does exactly that. It shuts the VM down, then drops the branch that it just
ran on. That also proves that a delete of the *current* branch is legal. If the delete succeeds and
the start then fails, the baseline does not change, and a new run makes the new branch. Thus the
discard first is safe, and also necessary.

**`base` must not cut the power, but `rollback` can.** Both stop the VM, because a snapshot needs it
stopped. But a baseline from a guest whose power was cut is a crash-consistent image of the one disk
that you least want to guess about. Thus `base` stops and says so, and does not force one. What
`rollback` force-stops is the working branch that it will delete. Nothing is lost there that was not
already to be discarded.

**Draugr never deletes the baseline itself.** Upstream refuses `snap_delete(name, -2)`, because a
deletion of the base disk *is* a deletion of the VM. A deletion of a VM is the job of `dr-forge rm`,
with its guard. Thus only branches are dropped here, and a test asserts that each `DELETE` in
`lib/forge/snap.ps1` goes to a `/branches/` path.

**Tested on the live daemon** *(on `test`, while it was still empty)*. A marker file was written
**after** the baseline, so it existed only on the working branch. The test told *gone* apart from
*unreachable*. `Test-Path` that answers `False` is positive evidence that the guest ran a command and
the file was absent. A failed `exec` proves nothing. The result:

| | |
|---|---|
| graceful shutdown | accepted, stopped inside the grace period |
| `base` two times | second run refused, exit 1, before it stopped anything |
| `Default Branch` | a normal branch: it deleted cleanly |
| the new branch | `work-20261021-2139`, booted from snapshot 0 |
| the marker | `Test-Path` → `False`: discarded with the branch |

Two side results. **Branch indices are used again.** The new branch took index 0, the index of the
branch just deleted. Thus an index is not a stable handle, and only `current` can say where the VM
is. And **the snapshot does switch the VM onto a new branch of itself**, as the bug description
says. Thus after `base`, the VM is already on a working branch, not on the baseline. `rollback` was
written for that state, and it is now confirmed, not assumed.

The two bugs from the live run were both in the *report*, not in the action. The rename worked, but
the report was wrong. The baseline was taken, but the count was wrong. Both are in the
[technique notes](#technique-notes-that-cost-hours-to-find).

---
## Security

The safety model of the README says that exactly four host paths cross the boundary, and one of
them is writable. The forge adds something that is not a path: **a general-purpose Windows machine
with a GPU and a shell on it.**

**What got better, because of the gateway:**

- **The forge has default-deny egress.** No adapter, no route, no DNS. All traffic leaves through
  the `sbx` policy of the gateway, and an administrator in the guest cannot get out in another way
  (*measured*). The worst case of the first draft, a VM bridged to your LAN, is not something that
  you must remember to avoid. It is a `0` that you must not change.
- **The control/data split.** The agent holds one ssh key to one port. It does not hold the bearer
  token of the daemon.

**What stays true, and must still be said:**

- **The forge is still not a mound.** No read-only source mount, no credential scan. All that the
  agent does there, it does as a Windows user who is probably an administrator in the guest.
- **The agent can use the Epic account.** The agent controls a signed-in Launcher. Thus its session
  token is in the guest, where the agent can read it, and Fab sells paid assets. The gateway allows
  `**.fab.com` and `**.epicgames.com`, so the allowlist does not stop a purchase. **Sign the forge
  in to an Epic account with no saved payment method**, ideally one that you use for nothing else.
  The cost: the Fab library of that account is separate. `dr-scan` cannot see inside a VM.
- **Password logins must be off** before the mound gets its `localhost:<SshPort>` rule.
- **GPU-PV makes the attack surface of the *host* wider.** A paravirtualised GPU is a path from guest
  code into the GPU driver of the host. That is a real kernel driver on your machine, and your
  display driver.
- **Rollback is the protection that really works**, and today it is one baseline, not a history.

**That section now exists** *(written)*: [SECURITY.md](SECURITY.md#the-forge-if-you-turn-it-on),
"The forge, if you turn it on", only when `DRAUGR_FORGE` is set. It has the sentence that this plan
drafted for it: *if you enable it, the mound still cannot reach your machine. It can now reach a
machine that you own, over one port, with no network of its own except through the same policy that
controls the mound*. It also has the four warnings that a reader needs **before** the decision:
the spending power of the Epic account, the wider attack surface of the host from GPU-PV, the
desktop camera, and `DRAUGR_FORGE_NOSCAN=*`, which fully disables Defender on a path that nobody
tested. The own refusals of the forge went into the refusals table of that page, with the others.

---

### The two passwords, and why they are not one

There are exactly two. A provision run asks for both once at the start, with a generated default,
and keeps both in files beside the ssh keys. They are never in the repository, and never in the
head of a person.

| | Where it comes from | Where it lives |
|---|---|---|
| Windows account | `adminUser`/`adminPass` of `create()`. The unattend makes the account | `~/.ssh/draugr_forge.pass` on the host |
| VNC | 8 generated characters, pushed in with the MSI, then the guest copy is deleted | `~/.ssh/draugr_vnc.pass` on the host |

**The agent needs neither.** It authenticates with an ssh key, and that session is elevated, with a
full token (*measured: writes System32, reads HKLM, controls services, never prompted*). The guest
user name for the connection comes from `ssh_info()`. The code base uses the Windows password in
exactly one place, `adminPass` at create time, and never again. It exists for a **human**, for the
case where autologon breaks or the desktop locks, because ssh is not a login prompt. It is also not
a boundary against the agent, because it is cleartext in the guest registry, and the agent is
elevated there.

One shared secret for both looks tidy, but it is a bad trade:

- **The auth key of VNC is eight bytes.** TightVNC silently cuts a longer one. Thus a shared password
  is really *the first eight characters of* the Windows password. It is not shared, only related in
  a confusing way. If you match them by hand, the Windows account gets a limit of eight characters.
- **The stored password of TightVNC is reversible.** It is in `HKLM\SOFTWARE\TightVNC\Server` as 8
  bytes of DES under the fixed, published VNC key (*measured in the guest: an 8-byte `Byte[]`,
  readable by Administrators and SYSTEM*). That is plaintext with extra steps.
- **The agent is elevated.** ssh into the guest gives a full token, so the agent can read that value
  at any time. A shared secret also gives it the Windows account.

The agent can also recover the Windows password inside the guest. The autologon of AppSandbox
writes it to `Winlogon\DefaultPassword` as a **cleartext string** (*measured: type `String`*). That
is why the forge assumes that the guest keeps no secrets, and why a shared password gives nothing.
Nobody types either password from memory, so one password is not more convenient than two.

## Config surface

New keys, by the standing rule that Draugr sets up the boundary, and never the inside:

```bash
DRAUGR_FORGE=                        # BUILT. VM name. EMPTY = no forge, invisible
DRAUGR_FORGE_NOSCAN=                 # BUILT. guest paths init excludes from Defender,
                                     # separated by SEMICOLONS. Empty leaves Defender alone
DRAUGR_FORGE_DIR=                    # planned. where the clone lives in the guest. D:\work\MyGame
                                     # keeps it on the VM's own disk, out of the agent's reach
                                     # on the host; S:\... puts it in your tree. See above.
DRAUGR_FORGE_START=auto              # planned. auto|manual|off — dr-up starts gateway+VM?
DRAUGR_FORGE_STOP=auto               # planned. auto|manual|off — stop when the last user leaves
DRAUGR_FORGE_LINGER=10m              # planned. grace after the last user, before stopping
DRAUGR_FORGE_SNAPSHOT=               # planned. the baseline rollback returns to. Empty = base disk
```

**The code reads two keys today**, `DRAUGR_FORGE` and `DRAUGR_FORGE_NOSCAN`. The others are the
planned surface. Each gets its `docs/CONFIG.md` section and its `share/config.example` line when it
is built. If not, `tests/docs.bats` fails. That is why none of them is there yet.

**There is no `DRAUGR_FORGE_GATEWAY`, on purpose.** An earlier draft of this section had one.
`DRAUGR_REQUIRES` replaced it *(decided)*. The gateway is the required repository whose mound
publishes `127.0.0.1:18888`. That is a declared fact, readable while all is down. Thus a second key
that names the same repository can only disagree with the first. Refer to **Commands**, below.

Also no `DRAUGR_FORGE_USER` or `DRAUGR_FORGE_PORT`, because `ssh_info()` reports both.

**On purpose, these are not keys: `gpuMode`, `networkMode`, `ramMb`, `hddGb`.** They describe the
inside of the VM. That belongs to AppSandbox, as the inside of a mound belongs to a kit. Draugr
reports them in `dr-forge status`, and sets none of them. If a script ever sets up a base over NAT,
it becomes a verb (`dr-forge maintenance`), not a key. Thus a forge open to a network is always
something that you did, never something that a file did.

House rule 7, *"nothing is written outside the repo, `~/.config/draugr`, and `$DRAUGR_MEM_STORE`"*,
stays unchanged. Draugr calls a daemon that owns its own storage, exactly as it calls `sbx`.

---

## Commands

`dr-forge` is a dispatcher over a family, the shape that `dr-data` and `dr-mem` already use:

| | |
|---|---|
| `dr-forge` | status: VM state, ssh reachability, `gpuMode`, `networkMode`, current branch, the gateway |
| `dr-forge init` | make a registered VM usable: its name, keys-only `sshd`, the tunnel key, the vault and the screen server. Idempotent |
| `dr-forge up` | in order: the `dr-up` of the gateway, the VM, the tunnel, then a test from inside the guest |
| `dr-forge up --screen` | the same, and the desktop of the guest on screen at the end. Does not block |
| `dr-forge screen` | only the desktop, on a forge that is up |
| `dr-forge down` | `shutdown`, then `stop` after a timeout: exactly those two daemon calls |
| `dr-forge rm` | delete the VM. Refuses when its disk is in a folder that you keep |
| `dr-forge exec <cmd>` | run in the guest, streamed |
| the normal git and data commands | the git loop and the file loop, host ↔ forge. `dr-forge` adds no verbs of its own for these: the clone is in the VM |
| `dr-forge base` | stop, take the baseline **once**, while the snapshot bug exists |
| `dr-forge rollback` | discard the working branch, branch again from the baseline. Stops the VM, and leaves it **running**, because a boot creates a branch. Refuses without confirmation |
| `dr-forge doctor` | each link, each with its own fix |
| `dr-forge gateway <dir>` | write the gateway mound into `<dir>` from the template of Draugr, and start nothing |

**One `dr-up` in the project starts all, if necessary.** That is the requirement. Go to the game
project and run `dr-up`. The gateway, the VM and the tunnel come up first, if they do not run yet,
in that order, before the mound of the agent. That makes the mounds depend on each other at run
time. Draugr never had that before, because each mound stood alone. Thus it has its own plan:
[run-state dependencies](#run-state-dependencies-planned-separately).

**All after the daemon belongs to Draugr, and so does each file that it needs** *(built,
corrected)*. The AppSandbox daemon is the one step that `up` cannot take, because its start needs
elevation. Thus `up` reports that, and gives you `AppSandbox.exe --headless`. Schedule that at
logon. The mound, the VM and the tunnel are then the work of Draugr, and the code for them ships
here.

The first version got that wrong in two places, and both were the same mistake. It told the reader
to run `forge-screen.ps1` when the daemon was down. It also started the tunnel with a supervisor
script **from outside this repository**, a file that Draugr does not ship. Thus `dr-forge` depended
on the layout of another directory. A checkout in a different place, or with a different name,
broke `up`, with a message about the files of somebody else. The supervisor is now at
**`lib/forge/tunnel.ps1`**, beside the `vm.ps1` that starts it, and nothing is passed in.

Its mutex, claim file and log keep the paths of the copy of the gateway:
`Global\Draugr.forge.tunnel` and `%LOCALAPPDATA%\Draugr\forge-tunnel.{log,claim}`. That is on
purpose. `probe.ps1` and `vm.ps1` read that claim to find who holds the forward. A supervisor that
still runs from the old copy must be visible to the new one. With new names, the two generations do
not see each other. That is exactly the two-supervisor state that the guard exists to prevent.
Measured: the supervisor of Draugr started while a logon-task supervisor for a different VM held the
mutex. It read the claim of that supervisor, and continued, and did not stand down. The guest kept a
way out, as intended.

**A supervisor is not the same thing as a bound port, and a read of only the port hid one**
*(found)*. `Get-ForwardOwner` started with `Get-NetTCPConnection -LocalPort 18022 -State Listen`,
and returned `$null` when nothing held it. Thus it read the claim file *only when a port holder
already existed*. A supervisor that claimed a VM, but is **between reconnects**, holds no port, and
was thus invisible. Its `ssh` exited, and the next try is up to ten seconds away. `vm.ps1 -Mode
tunnel` then started a second supervisor. That one read the claim, saw the first one, and exited,
as designed. The stalled first supervisor recovered on its own schedule, and `up` reported *"the
forward never carried"*.

The claim file answers this without a port, and `tunnel.ps1` already writes it in the right order.
`Write-Claim` runs **after** the stand-down decision, so a supervisor that exits never overwrites
it. `Read-Claim` rejects a pid that the system used again, because it makes sure that the process
is a PowerShell. Thus the three states are distinct, and Draugr now tells them apart:

| forward | live claim | what it means | what `-Mode tunnel` does |
|---|---|---|---|
| carries | — | healthy | nothing: early exit |
| bound, dead | this VM | old `permitopen`, or a far end that went away | end the `ssh` child. Its loop reconnects |
| **none** | **this VM** | **between reconnects** | **wait for the first supervisor. Do not start a second** |
| none | another VM | that supervisor can never serve this one | refuse, and name its pid |
| none | none | nothing serves this VM | start a supervisor |

**It waits, and does not kill.** You cannot prod a stuck first supervisor as you can a bound but
dead one, because there is no `ssh` child to end. Thus the choice is to wait, or to kill the
supervisor itself. Draugr refuses to kill it, for the same reason as the refusal beside it. This
script cannot know what started it, a logon task or a run by hand. A session-0 supervisor possibly
needs elevation for a kill. Thus it waits. If the first supervisor still does not carry, it says so
**and names the pid**. You can act on that, which was not true of "the forward never carried".

`probe.ps1` had the same gate, and thus `dr-forge doctor` did not report this state either. It now
gives `sup_pid` and `sup_vm` from the claim, whoever holds the port. The branch of `doctor` that says
"nothing holds the tunnel forwards" now says when a supervisor for this VM is alive, and only
between tries. That is a wait, not a break.

It also stopped its parse of `vms.cfg` for the relay port, and asks the `sshInfo` of the daemon. That
file has no documentation, and it was measured wrong: it said `57351` while the guest was on
`54501`. A request to the API also makes the absence of the daemon visible. Thus a supervisor that
starts before AppSandbox waits for it, and does not connect to a port that nobody serves.

**The mound comes up through `DRAUGR_REQUIRES`, and the forge adds no key of its own.** That key
already means "this repo needs the mound of that one to run", and the own header of `bin/dr-dep`
calls the forge gateway *the case it was written for*. `up` does not need to find **which** required
repository is the gateway, because `dr-dep up` starts all of them. Thus the only question left is
whether the gateway is *this* repository. Its own `DRAUGR_PORTS` answers that. The gateway is the
mound that publishes `127.0.0.1:18888`. That is a declared fact, readable while all is down, which
is when it must be read. Through `dr-dep`, it also gets the full protocol, not a copy: trust before
anything is sourced, the claim written before anything starts, a clean environment so that the own
configuration of each dependency decides what it is, the cycle guard, and the warden that stops the
automatic stop of an idle mound by `sbx` after 30 s.
`up` then **claims** `vm:<name>`. `down` refuses to stop the VM under another project that holds a
valid claim, unless you ask two times.

### The pinned port has a price: a far end is not identified by the VM being up

*(measured)* The pin on `18022` lets the mound have one rule, not one for each VM. The price: the
alias of **each** VM resolves to the same place. `ssh -G` on two of them:

```text
test          hostname host.docker.internal  port 18022
ue-427-test   hostname host.docker.internal  port 18022
```

They are identical, byte for byte. The name of the VM is only in the `Host` line for the look-up,
and is dropped at the first hop. Thus the VM that answers is the VM that the **supervisor** serves.

That gave a false pass in `dr-forge doctor`. A run for a *stopped* `ue-427-test` reported
`ok 10 WSL reaches the VM — a command ran over the alias`, because the command ran in `test`. Link
10 is the only effect test in that direction. Thus a pass there certified the wrong guest. It now
refuses to measure when the VM does not run, or when the forward serves a different VM.

The same confusion on the **data** path is worse than a misleading report. `dr-sync`, `dr-send`,
`dr-merge` and `dr-data` all reach the VM through that alias. Thus a push for one VM arrives in the
other. `dr_forge_far_end_running`, the forge branch of `dr_sandbox_exists`, thus requires that the
pin of the supervisor names **this** VM, not only that the VM runs.

**A pin that cannot be read refuses**, and that is different from link 7 on purpose. Link 7 treats
unknown as a pass. Thus a session-0 supervisor that it cannot examine does not cause warnings about
a forge that is fine. The gate controls *writes of files into a VM*. A wrong guess there cannot be
undone, so it needs the pin stated, not assumed.

### Naming the phases you want: `provision --only` *(designed)*

The same two phases that finish a base also finish a layer above layer-0. `cleanup` empties the temp
trees that a build leaves behind. `manifest` records what is in the disk. All else that `provision`
does (Windows, the toolchain, the components) is already in the parent, and must not run again.

**Twelve `--skip-` flags are not an interface. They are a copy.** That is the cost of those two
phases today, and the cost is not the typing. The list is a *copy of the phase table*, in the
repository of somebody else. On the day that a fifteenth phase is added, each copy of it silently
starts to run that phase on a finished layer. A flag list that you must update in a different place
on each change of this repository is drift that the type system cannot see.

**Thus `--only <phase>[,<phase>...]` says it the other way round**, and that is the full purpose.
`--skip` names what you do not want, which has no end. `--only` names what you want, which is short
and stable. `dr-layer provision layer-2-ue412 --only cleanup,manifest`.

**It is a shortcut for `--skip`, computed from the phase list, not from a second table.** Each phase
that you do not name becomes a skip. Thus `provision.ps1` gets nothing new, learns nothing, and
cannot disagree with the front end. A phase added to `_DR_LAYER_PHASES` tomorrow is skipped by each
existing `--only`, with no edit. The inversion is the feature. A hand-written map from `--only` to
`-Skip*` arguments is the same drift, with a different owner.

**Draugr refuses `--only` and `--skip-` together**, for the same reason that it refuses
`--skip-netfx`. Two switches for one decision can disagree, and a run that obeys both obeys
neither. The same refusal catches a phase name that is not a phase, and names the alternatives. It
does not ignore the word. That is why Draugr matches the spellings against the list, and does not
list them as flags.

**`netfx` is not an `--only` name**, because it is not on by default. `--netfx <path>` turns that
phase on. Thus a request for it here is a second switch for a decision that one flag already makes.
Draugr refuses it with that sentence, and does not silently accept and ignore it.

**Who needs it.** Draugr builds layer-0 and stops. What is above belongs to the project ([where the
line falls](#where-the-line-falls-draugr-owns-the-mechanism-you-own-the-contents)). But each project
that builds a layer above it needs the same two phases at the end, and must not write them again.
Thus this is the seam where a project gives a finished guest back for a clean-up. That is why it
belongs here, and not in the repository that asked for it first.

### Taking the daemon down is a command, not a recipe *(built)*

`dr-layer adopt`, `freeze`, `thaw`, `drop` and `new` all rewrite `vms.cfg`. Thus they refuse while
AppSandbox is up. The daemon has no window, so *"close it"* is not an instruction that anyone can
follow. Thus `layer.ps1` printed six lines to paste into an elevated PowerShell. They read
`host.json`, built an auth header, shut down each running VM, waited, and shut down the daemon. A
seventh line started it again. The request was to make that one thing to run.

**Only one of those steps needs elevation, and it is not the step that the instructions said.** The
own README of the headless API says explicitly that the gate is on a *run* of the daemon. HCS and
the `http.sys` bind both need it. A call to it does not. An authenticated request carries the
bearer token and nothing else. Measured the same day: `POST /vms/<n>/stop` succeeds from a normal
shell. Thus the VM shutdowns and the daemon shutdown need no elevation, and **only the `--headless`
start does**. `Start-Process -Verb RunAs` shows one prompt for it. The instruction to open an
elevated PowerShell for the full recipe taught people to elevate for work that never needed it.

`lib/forge/daemon.ps1` is that one thing, as `dr-forge daemon <verb>`:

| verb | what it does | elevation |
|---|---|---|
| `status` | daemon up or down, its version, and which VMs run | none |
| `stop` | each running VM gracefully, with a wait, then the daemon | none |
| `start` | `AppSandbox.exe --headless` | one UAC prompt |
| `restart` | `stop` then `start` | one UAC prompt |

**The VMs go down gracefully, with a wait**, in that order. While a VM runs, `POST /shutdown` is
refused with **409**, unless `{"force":true}`, which *terminates* the guests. A terminated guest has
a dirty disk, and these commands exist to freeze disks. Thus force is not offered. **Draugr asks the
running process for the path of the exe**, and does not guess it from a list of likely directories.
The default install is the only fallback. `status` records it while the daemon is up. Thus `start`
can still find it when there is no process to ask.

**AND THE SAME PIN CONFUSES `known_hosts`** *(measured)*. One address shown by many guests over time
is exactly what the host-key memory of ssh complains about. Thus the second guest served through
`18022` gets the refusal `REMOTE HOST IDENTIFICATION HAS CHANGED`. Each Draugr test through the
forward then reports the *far end* as dead. Thus each ssh and scp of Draugr to a guest passes
`-o HostKeyAlias=draugr-<vm>`. The key is then remembered for the VM, not for a port that moves and
is shared. The technique note [above](#technique-notes-that-cost-hours-to-find) has the measurement,
and why `no` is the wrong answer.

**None of this applies to a mound**, and the reason is structural, not care. The route of a mound is
`sbx ssh proxy %n`, so the name travels to the resolver, and `dr_sandbox_state` also matches on the
name. Both sides name the same thing. Thus "it exists" and "I will reach that" cannot disagree. Only
the forge drops the name, and only the forge needs the extra test.

**`up` and `doctor` exist mostly because of the gateway.** Its liveness chain is long: AppSandbox →
VM → tunnel supervisor → keeper → tinyproxy → gateway. A restart after a reboot is four ordered steps
across two operating systems. That is exactly the kind of recipe that `dr-plugin` replaced, and a
`doctor` test of each link is the best defense of the chain.

**Test each link by its effect, not by its existence** *(learned)*. The tunnel makes this concrete.
A running supervisor process is not the same as a working forward. An open forward on the host is
not the same as an answer inside the guest. The same mistake happened one layer up on the same day.
`forge-screen.ps1` reported a healthy tunnel, because `ssh -L` opened the local port, but the guest
end led nowhere. Thus `doctor` tests link 4 by a question to the **guest**: does `127.0.0.1:3128`
answer? It does not look for an `ssh.exe` on the host. That is also why link 5, the guest
preflight, stays a separate test, and does not merge into link 4.

This prevents the expensive failure. Each link was healthy except the tunnel supervisor, which a
host reboot silently removed. The symptom showed three links away, as *Unreal Engine reporting no
internet connection*. Nothing in the VM looked wrong, because nothing in the VM was wrong.

House rule 5 applies more widely: **AppSandbox stays visible.** Each error names the API call that
failed. Thus you can repeat the problem without Draugr.

### `down` asks the daemon, not the guest *(corrected)*

`down` ran `shutdown /s /t 0` inside the guest over ssh, and let `vm.ps1` wait for it. The stated
reason was that *a stop of a VM through the daemon pulls its plug*. That was half right.
`POST /vms/<name>/stop` is the plug, and the API README calls it "force power-off (pull the plug)".
But `POST /vms/<name>/shutdown` beside it is a **graceful ACPI power-off**, with a documented
`stopping` state for the interval. The premise was right about `/stop`, but wrong that `/stop` was
the only call.

Thus the ssh step is gone, and `vm.ps1` makes the graceful call itself. Two things improve. The mode
no longer depends on a caller that started something first, a coupling that its own comment had to
explain. And ACPI is a *hardware* event. Thus it reaches a guest whose `sshd` stopped answering.
That is exactly the guest that you most want to shut down cleanly.

The wider lesson is the same as from [the 405 of `dr-forge rm`](#making-a-forge-usable-and-unmaking-it-init-and-rm)
on the same day. This API ships its own README and reference client at
`C:\AppSandbox\headless-api\`. To read them costs less than to reason about what it probably offers.
### Making a forge usable, and unmaking it: `init` and `rm`

*(planned, not built)* `forge-layer.ps1 new` registers a VM on a frozen parent, and stops there. The
VM boots, but three things that it needs are in its **own** writable disk, not in the layer below:
its computer name, the password value of its `sshd`, and its authorized keys. Today a gateway script
gives them. Thus a working data path depends on the directory layout of another project. That is
the same mistake that we [corrected
above](#the-pinned-port-has-a-price-a-far-end-is-not-identified-by-the-vm-being-up) for the tunnel.

**`dr-forge init` is one verb, because nobody ever wants one of its steps alone.** A VM with keys but
no name is the trap where each VM called itself `layer-0`. Nobody can address a VM with a name but no
alias. A VM with both but no screen server breaks `dr-forge screen`. It is idempotent and you can run
it again. It reports one line for each phase, and needs the daemon **up** and normal rights.

**Built, as far as *reachable and correctly identified*.** `lib/forge/init.ps1` has the phases that
make a new VM answer to Draugr. Those are a keys-only `sshd`, confirmed by effect, the `permitopen`
of the tunnel key, with a nudge to the supervisor when it moves, the authorized WSL key, and last the
computer name, because only that change needs a reboot. It uses the own copies of Draugr of four
guest scripts in `lib/forge/guest/`. The `-WslPubKey` argument is a **path**, never the text of the
key. A public key contains spaces, and an unquoted argument with one already caused a silent failure
in `vm.ps1`. `dr_path_win_kit` spells a file native to WSL as `\\wsl.localhost\<distro>\...`. Thus
the Windows side reads it in place.

**It also stops writes of the guest into the child that give nothing back** *(built)*. A measurement
decided the list, not reasoning. The first draft of this phase targeted the wrong two things.

*Measured inside `ue-427-test`:* a differencing block of **2 MB** means that a 4 KB change to a file
in the parent costs 2 MB. Thus scattered small writes grow very much. Its child was 31.0 GiB over a
21.6 GiB parent. But all that was written since the creation of the VM was only **6.63 GiB across
3,907 files**. The gap came from that growth, not from one file. In the same run, `hiberfil.sys` was
**absent** (an AppSandbox guest never creates one), and `pagefile.sys` was **512 MB, with a peak use
of 71 MB**. The two files that the phase was first written for were not problems.

Thus it targets what writes **often, and in scattered places**:

| | |
|---|---|
| **Scheduled defrag** | disabled. The worst thing that can run on a differencing disk. It rewrites large parts of the volume for a contiguity that the guest cannot control, because the real layout is the VHDX chain of the host |
| **SysMain** | stopped and disabled. Continuous small scattered writes to predict launches that a build VM does not make |
| **System Restore** | off, and existing shadow copies deleted. Block-level changes, and a rollback mechanism inside a VM that already has [one](#backup-and-rollback) |
| **Hibernation** | off. Kept as insurance, though `hiberfil.sys` was absent: one registry read, against 40–75% of RAM if a guest ever made one |
| **Pagefile** | pinned to 512–8192 MB. Windows itself chose the floor, so it adds nothing. The ceiling is the useful part. WMI needs both numbers, and that is the only reason to name a floor |

`--no-tune` declines all of it. None of these needs a reboot except the pagefile, so `init` advises
a restart only for that. They are on by default, and that is an exception on purpose to *Draugr sets
up the boundary and never the inside*. Draugr needs neither of them to work. But both are a direct
cost of the **own** layer mechanism of Draugr. Thus the part that pays for them must fix them. Only
the pagefile change needs a reboot, and hibernation applies at once. Thus the guest script reports
the two separately, and `init` advises a restart only for the change that needs one.

**Defender is not disabled, and the paths are yours.** Real-time protection reads each file that a
build writes and reads back. A 2 MB block suffers most from that pattern. But `init` is generic, and
cannot know which trees are output that you can make again, and which hold something to scan. Thus
`DRAUGR_FORGE_NOSCAN` holds the paths, and Draugr holds the mechanism. Empty leaves Defender alone.
It only **adds** an exclusion. A setup script must not remove an exclusion that somebody made by
hand, only because a configuration file does not list it now.

A lone **`*`** in that list fully disables Defender. The list is also the switch, because one key
with a special value is easier to keep correct than two keys that can disagree, and `*` cannot be a
path. Draugr tests it **by effect**. Tamper Protection is on by default on Windows 11, and refuses
the change while the cmdlet returns with no error. Thus a report of success because the call
returned is exactly the false green that this family of scripts often suffers from. Refer to
[`DRAUGR_FORGE_NOSCAN`](CONFIG.md#draugr_forge_noscan) for when that is defensible. *(decided)*

**Considered and not done: reserved storage.** Windows 11 enables it, and the published VDI lists
suggest that you disable it. *Measured* with `fsutil storagereserve query C:` inside the guest: the
reserves **guarantee** about 6.9 GB, but have **291 MB actually used**. It is an amount subtracted
from the free space that Windows *reports*, not blocks written to the disk. The cost that this phase
controls is blocks written into a differencing child. Thus to disable it frees almost nothing on the
host, and the guest also had 467 GB free. Thus: we can, but we do not.

**Considered and refused: the shell, Themes and the UWP stack.** The VDI lists remove them freely,
because they assume a human on RDP who wants a fast response. Two reasons against it. The narrow
reason: session 1 with a working desktop is the main door of the agent. UI Automation controls it.
The measurement that selected the automation server found that *Microsoft frameworks expose all,
while Slate exposes nothing*. Thus the Microsoft UI stack is necessary here. The broader reason is
more important: **this is a public tool, and we do not know what other people want their forge to
do.** An optimization that breaks a use case that we never imagined is a worse trade than a few
megabytes. *(decided)*

**Considered and dropped: a move of the derived data cache out of the VM.** It keeps gigabytes out of
the child. But a DDC is project data, not something to share between projects. The normal recovery
for a forge is [rollback](#backup-and-rollback), not delete-and-recreate. Thus you want the cache
inside the VM, where it stays in the baseline. *(decided)*

**Still a specification: *equipped*.** The vault credential and mount, and the screen server, are
still in the gateway. Thus `dr-forge screen` still works only on a guest that was prepared there.
They join `init` under the rule below, as does the desktop camera. Know this when you read
`init.ps1`. `tests/forge.bats` covers its bash side against a mock, and `tests/forge-api.bats`
*runs* the PowerShell that talks to the daemon against a mock daemon. The guest half is not tested,
and cannot be. `reduce-churn.ps1`, `install-shot.ps1` and `harden-sshd.ps1` touch scheduled tasks,
the registry, Defender and `sshd`, which no mock can make exist. Thus they still rest on an exact
port of measured code, and a live run.

**A thing joins `init` when the contract of a Draugr verb depends on it.** That paces the migration,
and does not demand it all at once. The desktop camera joins when screenshots through `pull` exist.
The automation server joins if the UI verb exists.

**`dr-forge rm` needed a guard that nothing had** *(built)*. `asb_vm_delete` calls
`remove_dir_recursive` on the folder *derived from the disk path*, with a guard only against a drive
root ([the delete hazard](FORGE-DISKS.md#the-vms-folder-is-derived-from-the-disk-path-not-from-its-name)).
Thus the question is never "is this VM disposable", but "what else is in its folder".

**And the answer is closer to the edge than it looks.** *Measured:* each VM on this machine reports
`diskDirectory: C:\ForgeLayers`, the store that holds `layer-0`, `layer-1` and `layer-2-ue427`. It is
safe only because each VM gets a **subfolder** of its own. Thus the frozen layers are siblings, not
children. A VM pointed one level higher puts the full store at risk.

Thus `lib/forge/rm.ps1` finds the folder that will go. It confirms it by a disk in it, and does not
trust the name. It **refuses fully** on three shapes: the VM pointed at the store itself, a read-only
`.vhdx` in any place under it (that is what frozen means, and each child depends on a frozen parent),
or another disk nested under it. Draugr never offers a refusal as a confirmation, because a request
to confirm something unsafe invites a yes. In other cases, it reports the folder, its size in GiB
and its contents, and `dr-forge rm` shows all three before it asks. The verdict decides, and the
reasons explain. A verdict that arrives without reasons still refuses.

It also clears the **shared** forge host key. Each forge VM shows on the same pinned `host:port`, so
they have one `known_hosts` entry between them. If it stays, the next VM on that port looks like a
man-in-the-middle, not a new machine. Its removal cannot touch the key of a real server, because
`dr-setup --forge` gives forge hosts a file of their own. `rm` does **not** rewrite `DRAUGR_FORGE`.
The VM that a project uses is a declared choice, and the replacement does not exist yet. Thus it
says so, and does not guess.

**The ssh alias is one wildcard block, not a file for each VM** *(built)*. `dr-setup` already solved
this problem for mounds. Its own header says that without a matching block in the `~/.ssh/config`
of WSL, neither `ssh <name>.sbx` nor the `ssh://` transport of git works. It used **one** block for
`*.sbx`. The pinned port makes the forge case even easier. The resolved configuration of each forge
VM is [identical except for the `Host`
line](#the-pinned-port-has-a-price-a-far-end-is-not-identified-by-the-vm-being-up). Thus one
`*.forge` block covers each VM, there is no write step for each VM, and **an old alias is no longer
possible**. That is the class of bug that made `ue-427-test` reach `test`.

`dr-setup --forge` writes it. It is **opt-in, and it stays**. A machine that never asked for it never
has a block that mentions a forge, and a later plain `dr-setup` puts back what it found, and does not
delete it. The key that the block names is made at the same time. It is separate from the admin key
on the Windows side, because ssh refuses a key read from `/mnt/c`. Forge host keys get their own
`UserKnownHostsFile`, because each VM shows on the same pinned `host:port`, and the keys otherwise
collide on one line. Thus the removal of the key of a rebuilt guest cannot touch the key of a real
server.

**The two results, as settled.** The `ProxyCommand` names the gateway mound. That name is put in
when the block is written, not resolved at connect time. git calls `ssh` directly, so the command
must work from any directory, with no Draugr process in the path. The default is `draugr-gateway`,
the name that Draugr itself uses when it
[makes the gateway](#which-directories-exist-and-which-of-them-you-keep). You can override it with
`dr-setup --forge-gateway <mound>`. A rewrite remembers it from the existing block, so that a new run
cannot silently move the route. And the far end is now **`<vm>.forge`**, which
`dr_sandbox_ssh_host` builds for `dr-sync`, `dr-data` and `dr-code` alike. That suffix is spelled in
both `lib/common.sh` and `lib/forge/common.sh`, because no core script can source the forge library.
A test asserts that the two agree.
### The gateway, generated: `dr-forge gateway` *(designed and built)*

The [topology](#which-directories-exist-and-which-of-them-you-keep) decided that Draugr makes the
gateway, and nobody keeps it. This verb makes it. The design is here before the code, because the
important parts are all refusals.

```text
dr-forge gateway <dir> [--vault <host path>] [--scratch <host path>] [-y]
```

**What it writes.** The template is `share/gateway.example/`, beside `config.example` and
`kit.example`. It makes this tree:

| generated | from the template | substituted |
|---|---|---|
| `.draugr.conf` | `draugr.conf.in` | the name of the VM, the name of the mound, the two host paths |
| `.draugr/kit/spec.yaml` | `kit/spec.yaml` | nothing: the deny list stays exactly the same |
| `.draugr/hooks/post-up` | `hooks/post-up` | the two host paths, **and the mode** |
| `kits/base/spec.yaml` | `kits/base/spec.yaml` | nothing |
| `kits/unreal/spec.yaml` | `kits/unreal/spec.yaml` | nothing |
| `README.md` | `README.md.in` | the paths, so that you can paste its commands |

**Only three things in a gateway are not mechanism**, and the arguments are for them: the name of
the forge VM, taken from `DRAUGR_FORGE`, and the vault holder and scratch directories, which are
host paths of this machine. All else is identical on each machine: tinyproxy with no destination
filter, the keeper, the SMB share, and the deny list. The deny list narrows the ~190 defaults of
`sbx` to the hosts that the tools were *seen* to use. That is why this is a template, not a
tutorial.

**No `.gitignore` in the template, on purpose.** The gateway is a data-only repository, and
`create-data-only` writes that file itself, always, with `*` and nothing else. Thus the first
command that creates the repo overwrites a template copy. Thus the generator writes
`DRAUGR_ON_MISSING_REPO=create-data-only` into the configuration, and leaves the repository to
`dr-up` or `dr-init`. *Measured*: only those two call `dr_context_create`. Thus only those commands
can make one. Either creates it on first use, with the `*` `.gitignore` and two commits. After that,
`git status` is always empty. The protocol stays in one place, and the generator only writes files.

**The executable bit is necessary, and `share/` must not have it.** `dr_hook` is
`[ -x "$hook" ] || return 0`. A hook that is not executable is **silently skipped**. A gateway made
with a mode-644 `post-up` comes up with no keeper, no tinyproxy and no vault share, and `dr-up` says
nothing. The mound then stops answering 30 s later. Meanwhile `tests/executable-paths.sh` keeps
`share/` not executable on purpose (*"share/ is mostly examples that must not be"*). Thus the bit
cannot come from the template. The generator sets it, and a test asserts it on the generated copy,
not on the template.

**Draugr gives trust, because Draugr wrote the file.** `.draugr.conf` is sourced, and `post-up`
runs on the host as you. Thus both get a trust test, and Draugr refuses a hook that is not trusted
during a command. There is a precedent. `create-data-only` calls `dr_trust_add` on the
`.draugr.conf` that it writes itself. The generator does the same for the two files that it writes,
for the same reason: you ran the command that wrote them. It does this **only** for files that it
really wrote. A file kept because it is different does not get trust again, because nobody here
read it.

**A new run is the normal case, so it must not overwrite.** The allowlist changes by the kind of
work, not by VM (the hosts of Epic are the same for 4.27 as for 5.8). Thus you make a gateway again
when the work changes, and after a Draugr upgrade that improves the deny list. Each file arrives in
one of three states, reported for each file: **created**, **already current** when the content is
identical, or **differs, kept**. The last one is a refusal that names the file and the command that
overwrites it. `-y` overwrites. The generator does not touch files that the template does not name.
That covers `.git/`, `.draugr/tmp/`, the `.applied` stamps, `.draugr.local.conf` and the password
files beside a gateway.

**A generated gateway is not a second gateway that you can run.** `DRAUGR_PORTS` publishes the fixed
`18888` and `18445`. `18022` is pinned, and the tunnel supervisor holds one mutex. Thus
[only one gateway can run](#which-directories-exist-and-which-of-them-you-keep), generated or made
by hand. To make another costs nothing, and we recommend it, while the first one stays in use. A
start of it beside the first is the one thing that does not work. On Windows, it fails *silently*,
because a second process can bind a port that is already bound, and the two then take turns to
answer. Thus `gateway` makes it and stops. It starts nothing, and `dr-forge up` reaches the gateway
through `DRAUGR_REQUIRES`, exactly as before.

**What the build changed.** Two things, both refusals, and a run of the verb found both, not a
read of it. The guard against a mistyped directory was "an existing `.draugr.conf` that does not
publish 18888". The checkout of a *tool* has no `.draugr.conf`. Thus `dr-forge gateway` into the
own directory of Draugr wrote a configuration, a hook and two kit specs into it, and did not refuse.
It kept the README, and only that made the mistake clear within a second. The guard is now
**emptiness**. Draugr refuses a directory that is not empty, unless it already publishes 18888. That
also identifies the gateway that you make again. And the report for each file printed
`overwrittenyes`, because `${had:+overwritten}${had:-written}` fires *both* arms when `had` is set.
`:-` returns the value of a variable that has one.

**The name is the weak part of this.** `gateway` is a noun among verbs (`up`, `down`, `init`,
`base`, `rollback`), and `dr-forge gateway <dir>` reads as a question, not an instruction. The other
names were worse. `mkgateway` is unlike all else in Draugr. `init-gateway` collides with `init`,
which means the VM. A top-level `dr-gateway` puts a command in a public `bin/` for a feature that
almost nobody turns on. It stays `gateway` until somebody has a better name. `dr-layer` has the same
open question.

### The layer mechanism as a command: `dr-layer`

*(planned, built)* The layer verbs are **not** `dr-forge` verbs, and the reason is structural, not
tidiness. Two things separate them:

- **The conditions are opposite.** All that `dr-forge` does needs the daemon **up**. Each disk verb
  needs it **down**, with AppSandbox closed. The daemon rewrites `vms.cfg` on each change, and an
  edit under it is lost. In one command whose verbs disagree about such a basic condition, a symptom
  shows three steps from its cause.
- **The gate is also opposite.** `dr-forge` is inert unless `DRAUGR_FORGE` names a VM. That is the
  full claim of optionality. But these verbs *create* the thing that the key names. Thus they cannot
  have that gate, or you can never build a first forge.

**Verbs:** `list`, `adopt`, `new`, `freeze`, `thaw`, `drop`, and `provision` to build a layer-0 from
an ISO. Not `base`. That word belongs to `dr-forge`, and the two mean different things.

**It must never run elevated. That is the most important trap, so it comes first.** Integrity works
in one direction. An elevated client can use a `sandboxd` that a normal shell started, but not the
reverse. A `dr-*` command, run elevated with no `sandboxd` up, starts an **elevated** one. The keeper
of `post-up` pins it for the full life of the mound. Each later command from a normal terminal then
fails in the worst way. `dr-up` reports `Status: stopped` about a daemon that serves perfectly,
because its command line reads as DENIED from medium integrity. *Measured, and it cost an evening.*
Thus `dr-layer` stays normal, and elevates only the short steps that really need it, the VHD
cmdlets. It returns their output through a transcript. `forge-engine-layer.ps1` did the same, for
the same reason.

**The edits of `vms.cfg` are in one file, alone.** They work around two upstream gaps at the same
time. There is no route to promote a VM to a template, so a template can only be clean Windows
(*read from source*). The [snapshot bug](#it-has-a-bug-that-decides-the-design) rules out the other
route. The format has no documentation, and a measurement showed it out of date. In one clearly
marked file, if [#199](https://github.com/jamesstringer90/appsandbox/pull/199) lands, the fix is to
delete a file, not to untangle it from the orchestration.

**Nobody types PowerShell now.** It cannot go. The VHD cmdlets exist only in PowerShell. The API of
the daemon binds the Windows loopback, and *(measured)* WSL cannot reach it. The guest is a Windows
machine. But the pattern is already here. `bin/dr-forge` is bash, and each `lib/forge/*.ps1` says
**not meant to be typed**. The front ends become bash. What stays PowerShell becomes library files
behind a verb.

#### What it is, verb by verb

The mechanism first existed as a hand-written script, 955 lines that work and are measured.
`dr-layer` is that script **adopted**, not rewritten. The order of its verbs is the full difficulty,
and nobody guessed any of it right the first time.

| verb | what it does | needs elevation |
|---|---|---|
| `list` | the registered VMs, the chain of each disk, and each layer under the root | no: it gives less, and says so |
| `adopt` | the disk of a finished VM becomes a frozen layer: capture the configuration, move, prove, freeze, deregister, remove the empty folder | yes |
| `new` | a differencing child on a frozen parent, with a VM block and an ssh port | yes |
| `freeze` | read-only on, and with `--unregister`, the VM block off | yes |
| `thaw` | the undo: read-only off, `vm_state.json` back, the VM block rebuilt from `layer.json` | yes |
| `drop` | the layer directory and its VM block go | yes |

**Three files, split along what goes if a fix of the upstream bug arrives.**

- `lib/forge/vmscfg.ps1`: all that knows the shape of `vms.cfg`. That is the block reader, the
  writer that keeps UTF-8-with-BOM and CRLF because AppSandbox wrote that, and the VM-block layout
  that `new` and `thaw` both write. This is the workaround, alone, as the paragraph above requires.
  If [#199](https://github.com/jamesstringer90/appsandbox/pull/199) ever lands, and a VM can become a
  template, this file goes.
- `lib/forge/layer.ps1`: the six verbs, the disk work, the elevation relaunch, and `layer.json`. The
  sidecar is *not* in the file above, because it is not a workaround for the configuration format.
  It exists because the deregistration of a layer deletes the only record of the RAM, cores, GPU
  mode and network mode that its children must get.
- `bin/dr-layer`: the bash front end, with the verbs, the flags and the refusals.

**`layer.json` makes a chain describe itself.** `new` copies `RamMB`, `CpuCores`, `GpuMode`,
`GpuName` and `NetworkMode` from a VM block. But the full purpose of a frozen layer is that no VM
block points at it now. Without the sidecar, the fallback was *the first VM block in `vms.cfg`*:
some unrelated VM, whose GPU and network values were then copied into the layer **silently**. A
layer with a different `GpuMode` or `NetworkMode` from its parent acts differently from the thing
that it was built on, and that shows three steps away.

**The most important guard looks wider than the root.** `thaw` and `drop` both refuse when a disk
differences from this one. A write to a parent that a child differences from silently corrupts the
child, and nothing in the stack reports it. *Measured*: `C:\ForgeLayers\layer-1` is the parent of
`D:\ForgeLayers\layer-2-ue411`. A test that scanned only the root found no children for `layer-1`.
One `drop` then removes the parent of each engine layer on the other drive. Thus the search covers
the root, `<drive>\ForgeLayers` on each **fixed** drive, and each `VhdxPath` in `vms.cfg`. Draugr
reports a disk that it cannot examine as **unreadable**, not absent, and the caller decides.

**Exit codes**, because a front end must tell a refusal from a failure: `0` done, `2` wrong
arguments, `3` AppSandbox is up and nothing changed, `20` a guard stopped it (a writable parent, a
layer with children, a name or ssh port already in use, a size below that of the parent), `21` a
named thing does not exist, `24` elevation was declined.

**Where layers live** is [`DRAUGR_FORGE_LAYERS`](CONFIG.md#draugr_forge_layers), empty by default,
which means `C:\ForgeLayers`. `--root` overrides it for one call. It must be your **fastest** disk,
not your biggest. Reads walk the chain, so the frozen parents that hold Windows, Visual Studio and
the engine are the busy read path. A store on each drive is the normal shape here. The engine layers
are the big ones.
#### What the build changed

**Draugr tests the daemon before it asks for elevation.** The script that this came from did it the
other way round. `Get-Process` needs no elevation, and the relaunch shows a UAC prompt. Thus with
the original order, you accepted a prompt, and *then* it told you that AppSandbox ran and nothing
was done. A refusal that costs a prompt first teaches people to click through prompts. Tested on
this machine with the daemon up: `dr-layer freeze test` printed the shutdown recipe, and exited 3,
with no prompt.

**A flag for the wrong verb is a refusal.** `layer.ps1` takes all flags, and uses each one where it
means something. Thus it silently accepted a flag for the wrong verb, and `dr-layer drop x --force`
looked like "I forced it", but forced nothing. Only the front end knows what you *typed*. Thus it
catches that there, and also a missing `--parent` on `new`. The answer then arrives without a trip
to Windows, and the daemon test does not answer something else first.

**Tested live, with the elevation round trip.** `dr-layer new my-test-layer3 --parent
layer-2-ue427 --dry-run`, run from WSL with the daemon still up:

```text
  the VHD cmdlets need elevation - asking for it once (accept the UAC prompt).

=== new layer 'my-test-layer3' on layer-2-ue427 ===
  parent  C:\ForgeLayers\layer-2-ue427\disk.vhdx (512 GB)
  child   C:\ForgeLayers\my-test-layer3\disk.vhdx
  size    512 GB (inherited)
  nothing was created (-WhatIfOnly)
```

That showed four things at once, and none of them was certain before. `Start-Process -Verb RunAs`
works when the chain *starts in WSL*: bash, `powershell.exe`, UAC, an elevated child. The
**transcript** carries the output of that child back. Its console is a separate window that closes
when the script ends. Thus each line above came from a file. `Get-VHD` answered under elevation, and
that is the full reason for the relaunch. And `--dry-run` skipped the daemon test while AppSandbox
ran. That is on purpose, because a rehearsal of a layer while the forge is up is most of its value.
The parent was already frozen, so the writable-parent refusal correctly stayed silent.

#### What is deliberately not in it

- **Engine layers.** `forge-engine-layer.ps1` makes one engine version into one frozen layer. It
  controls the Launcher, names the layer `layer-2-ue412`, and calls the verbs above. That is the
  build logic of the forge *project*, which the
  [topology](#which-directories-exist-and-which-of-them-you-keep) puts in your private repository,
  not in Draugr. It still works, because it calls `dr-layer new` and `dr-layer freeze`, not a
  sibling script.
- **`provision`**, which builds a layer-0 from a Windows ISO. By the verb list above, it belongs
  here, and it is **stage two**. It is designed below, in three parts, because it is ~3,980 lines
  of adopted script, and one change for review cannot be that large.

#### Stage two: `dr-layer provision` *(designed and built, in three stages)*

A layer-0 is a generic Windows guest that an agent can control. It has no network adapter of its
own, ssh reaches it, it can get out only through the gateway, and it has the components [judged
unconditional above](#where-the-line-falls-draugr-owns-the-mechanism-you-own-the-contents). The
`forge-provision.ps1` of the gateway builds one in a single idempotent run, with the creation of
the VM and an unattended install of Windows. This verb adopts that script.

**The size, measured, because it decides the shape of the work:**

| | lines |
|---|---|
| `forge-provision.ps1` | 1,243 |
| guest scripts that Draugr does not have yet | 2,738 |
| guest scripts that it already has, used again, not adopted again | — |

The six that are already here (`authorize-key`, `harden-sshd`, `install-shot`,
`install-tunnel-key`, `reduce-churn`, `set-computer-name`) are called where the original called its
own copies.

**Three parts, each one ends at a point that you can test:**

- ~~**2a, the base.**~~ **Built**: `lib/forge/provision.ps1` (1,050 lines, adopted by patches to a
  copy), the five guest scripts (`install-guest-base`, `install-windows-online`, `write-manifest`,
  `cleanup`, `preflight`), and `dr-layer provision` in front of them. Phase 0 creates the VM and
  installs Windows unattended, with the network already `None` and a key already in place. The
  phases after it are the host keys, the OS settings of the guest, *make Windows believe it is
  online*, the restricted tunnel key, the egress proof, cleanup and the manifest. **One password,
  not two.** The second is that of VNC, for a screen server that stage 2b installs. A request for a
  password for something that nothing installs makes a person believe that a secret was set.

  *Tested* as far as possible without an hour and an ISO: the argument surface and each refusal from
  bash, and the conditions against the live daemon. It reported AppSandbox 0.1.8, and refused an
  unknown VM, and named the one that exists. **Not run yet:** phase 0 itself, and the phases that
  need ssh. Those need the guest up, and the gateway with it.
- ~~**2b, the unconditional components.**~~ **Built**: six more guest scripts and the two scripts on
  the host, ~1,430 lines, again adopted by patches to copies. Seven phases between the egress proof
  and cleanup, in this order:

  | phase | what it puts in the guest | where it comes from |
  |---|---|---|
  | `msys2` | MSYS2, pinned to one mirror *before* its first sync | `repo.msys2.org`, which `kits/base` already allows |
  | `tools` | the Unix set: git, rsync, jq, ripgrep, make, openssl, 19 in all | the same pinned mirror |
  | `automation` | `uv`, a real `python`, the UIA MCP server as a **session 1** task, AutoHotkey | hosts that `kits/base` already allows |
  | `shot` | the desktop camera: how an agent with only a shell can *see* | already adopted: `install-shot.ps1` |
  | `screen` | the server of TightVNC, loopback-only, pinned by SHA-256 | the vendor, fetched **on the host** |
  | `vault` | the share password and `mount-vault.ps1`, then a reboot | the SMB share of the mound |
  | `vscode` | VS Code, 233 MB | the vault if it holds a copy, else the vendor |

  **`vault` before `vscode` is the reason for an order at all.** The installer is 233 MB. The only
  way out of the guest is the proxy over the ssh tunnel, and the vault phase puts the share
  credential in the guest. In the other order, each rebuild pays for the download again.

  Nothing in that table is specific to Unreal, and that makes it a base, not a layer. It is what
  each Windows VM that an agent controls wants. Two of the seven are **not** guest scripts. The
  screen server and the vault reach *into* the guest from the host. That is the first of the own
  decisions of 2b below.

  *Tested* in the same way as 2a, and no further: the argument surface and each refusal from bash,
  each file parsed by the own parser of PowerShell, and `--skip-netfx` refused while its seven new
  siblings are accepted. **Not run:** anything that needs the guest up. Each phase in that table
  installs something over ssh, so nobody ran the full table. Its comments have the measurements of
  the gateway, cited as those of the gateway, and not measured again here.
- ~~**2c, the optional component.**~~ **Built**: `.NET Framework 3.5`, one guest script,
  `install-netfx3.ps1`, 126 lines. Unreal wants it. The install of UE 4.27 showed the own prompt of
  Windows for it (measured). It belongs in the base, not in an engine layer, because each engine
  version needs it separately.

  **It cannot install itself, and that shapes the stage.** `NetFx3` is a *Feature on Demand*. The
  payload is not on the installed system, and Windows fetches it from Windows Update. This guest has
  Windows Update off *and* no network adapter. Thus the button of the prompt fails for two reasons,
  and reports neither. The payload exists in exactly one place, the `\sources\sxs` folder of a
  Windows ISO, and **it must match the build of the guest**. If not, `DISM` fails with `0x800f081f`,
  which reads as a missing file, not as a version mismatch.

  **Thus a human must make the payload, and that is why the phase is off.** A phase whose condition
  no script can satisfy fails on each new machine. A provision run that always ends with one red row
  teaches you to ignore red rows.

  **One flag that is both the switch and the condition**: `--netfx <path>`, which names the cab or
  the folder that holds it, **on the host**. Its presence turns the phase on, and its value makes the
  phase possible. Thus "off by default" and "refuses early" become one mechanism, not two. The
  refusal is a `Test-Path` in the conditions block, *before* phase 0. Thus a missing payload costs a
  second, not an hour.

  **The host holds it and pushes it in**, as `screen-access.ps1` does with the pinned MSI. The guest
  does not fetch it from the vault. Three reasons, the most important first. The test must happen
  before phase 0, and the guest cannot reach the vault until phase 11 installs a credential and
  reboots it. Also, `--netfx` then works on a gateway that serves no vault. Last, the 68 MB goes
  over `scp` on loopback, which takes seconds. The guest script keeps its vault route for people who
  run it by hand (`-Share` and `-SubDir` do not change). It is only not the route of `provision`.

  **`--iso` is where the matching cab comes from**, and the error message says so. If the run
  created the VM, the ISO that it installed from is the matching build. Draugr does not mount it
  itself, because `Mount-DiskImage` needs elevation, and nothing in `provision` asks for any. The
  third change above removed the last of it. In its place, it tells you the path inside the ISO.

  **Draugr still refuses `--skip-netfx`**, now for a different reason. The phase is off unless
  `--netfx` names a payload. Thus without that flag, it *is* off, and a second switch for the same
  decision can disagree with the first.

  *Tested*, as for 2a and 2b: the argument surface and both refusals from bash, and the files
  parsed. One test is worth a name. It reads the **line numbers**, to assert that the payload test
  is above the heading of phase 0. "Before the hour" is a claim about position, and nothing else
  catches a move of it. Mutation-tested by a move of the block below phase 0. **Not run:** the
  phase itself, which needs a guest, a cab and `DISM`.
**Two phases must change, and not only be copied.** Settle this part before any code moves.

- **The gateway (phase 4).** The original runs `dr-kit validate` and `dr-up` on a hard-coded gateway
  directory. Draugr already has the answer to "start the gateway": `DRAUGR_REQUIRES` and
  `dr-dep up`. `dr-forge up` does it that way, and gets the full protocol: trust before anything is
  sourced, the claim written before anything starts, the cycle guard, and the warden that stops the
  automatic stop of an idle mound by `sbx`. Thus you run `provision` **from the project that names
  the gateway**, and the bash front end starts it that way. If nothing requires a gateway, it says
  so, and refuses the phases that need egress. It does not build a base that cannot download
  anything.
- **The tunnel (phase 5).** The original calls the `install-tunnel-autostart.ps1` of the gateway.
  That is a different file, and also a *logon task*, and [minimal host
  changes](#considered-and-rejected) ruled that out. The supervisor is now at
  `lib/forge/tunnel.ps1`, started by `vm.ps1 -Mode tunnel`, and `provision` calls that. `dr-forge`
  already has the same correction, for the same reason. A dependency on the directory layout of
  another project is how `up` broke when a gateway got a new name.

**A third change happened that the design did not predict.** The original *runs elevated*, and
started the mound itself. That made the integrity hazard real. Its `-AllowElevatedGateway` existed
to overrule the refusal that followed. Here the front end starts the gateway through `dr-dep`, in
the normal shell where you typed. The script only talks to the daemon over HTTP, which needs no
elevation. The token is in `host.json`, and each other `dr-*` command does the same. Thus the claim,
the flag and the three helpers that existed only to run `dr-up` from inside PowerShell are all
gone. The measurement that explains *why* nothing here starts a daemon stays. A port that kept the
flag keeps a switch with nothing left to allow.

##### 2b's own five decisions

- **`install-` means "runs in the guest".** Forge scripts on the host are `lib/forge/<thing>.ps1`.
  All that is copied into the guest and runs there is in `lib/forge/guest/`. Two installers of the
  gateway run on the host, despite their names. They hold a pinned MSI and a share password that the
  guest must never select for itself, and push them in over ssh. Thus they are adopted as
  `lib/forge/screen-access.ps1` and `lib/forge/vault-access.ps1`, and the prefix no longer lies.
- **A provision run does not install the VNC viewer of the host.** The screen installer of the
  gateway also puts the *viewer* half of TightVNC on the host, behind `Start-Process -Verb RunAs`.
  That is a UAC prompt in the middle of an unattended run of an hour, which is exactly what "ask each
  question at the start" exists to prevent. [Minimal host changes](#considered-and-rejected) point
  the same way. Thus it is skipped by default and named in the summary, and `--install-viewer` asks
  for it. Nothing is lost by the wait. `lib/forge/screen.ps1` already handles a host with no viewer.
  It leaves the forward up, and says that any viewer pointed at `127.0.0.1:15900` works.
- **The vault phase asks whether there is a vault, and the question first had to become
  answerable.** The phase writes a share password into the guest, then **reboots** it, because the
  own `LanmanServer` of the guest holds port 445 until a restart. For a share that nobody serves,
  that spends a reboot on nothing. The clear test is the `18445` of the mound, which phase 4 already
  probes. *As first written, this was wrong.* The generated configuration published `18445`
  **always**, and the publisher binds a published port on the host, not the service behind it. The
  host answered for a service that nobody ran.

  Thus the generator also changed. `dr-forge gateway` publishes `18445` only when you give a
  `--vault`, with the same path test that `post-up` uses for the share itself. The port is now a
  fact about this gateway, not a line in a template. That makes it readable from the other side.
  `post-up` also skips the share in a **second** case, when there is no `draugr_vault_smb.pass` on
  the host. The phase reads that one directly, because the file is on its own side. Both report and
  skip, and neither reboots.
- **The second password arrives now, not in 2a.** 2a asks for one, because nothing that it installs
  has a second. `screen` makes the eight-byte key of VNC real. The truncation branch of
  `Get-Secret` (warn, cut to 8, write the cut value back, so that the file and the server cannot
  disagree) was adopted in 2a, unused, for this.
- **`Add-ToMachinePath` stays duplicated in two guest scripts.** Each guest script is copied in
  alone and runs alone. A shared helper makes "copy one file, run it" false. The forty lines are
  identical in both, and both say which other file has the twin.

**One parameter gets no flag, on purpose.** The port of the MCP server is `8765` inside the guest,
because `lib/forge/tunnel.ps1` forwards `18765` to it. A `--mcp-port` lets somebody move the server
away from the tunnel that reaches it. It stays a `provision.ps1` parameter with a default, passed to
the automation phase and to the manifest so that the two cannot drift, and the front end does not
offer it.

**What provision must never do**, all three kept on purpose: install AppSandbox, enable
`VirtualMachinePlatform` (it needs a reboot), or make a Windows ISO. Those stay with a human, and it
says so. It also does not change the network of an **existing** VM to `None`. It reports the value
and refuses. A provision of a guest that still has its own way out puts a hole into the base image.
The API can make that change, but a forge open to a network stays something that you did.

**`-DiskGb` is the number that you cannot take back**, and it binds each layer above. You can never
resize this disk. A child gets the capacity and can only grow, and the own snapshots of AppSandbox
take no size argument. The VHDX expands dynamically, so a large number costs nothing until it is
used. 512 GB leaves room for an engine, a project and a warm cache.

#### The one tension, stated rather than hidden

All else about the forge is invisible unless `DRAUGR_FORGE` names a VM. `dr-layer` cannot be. It
*creates* the thing that the key names, and with that gate, you can never build a first forge. The
cost is a command in a public `bin/` that almost nobody wants. The only protection is that it says
so. On a machine with no AppSandbox, it refuses with one line and a pointer here, and does not
explain layers to somebody who looked for something else.

### Run-state dependencies, planned separately

**The requirement:** in the game project, one `dr-up` starts each mound that the mound of the agent
depends on and that does not run yet, then the mound itself. Nothing starts two times, and nothing
that runs restarts.

That is a general Draugr feature with no forge in it, so it has its own plan:
**[DEPENDENCIES.md](DEPENDENCIES.md)**. It has the six-link chain, the claim model, the optional
lock, the counted stop with its linger, the security results of a requirement on another
repository, and the acceptance criteria. The decisions (elevation stays manual, the mechanism is in
core, the lock is optional and the dependency declares it, the stop is counted) are recorded there.
They are not repeated here, so that the two cannot drift apart.

**What stays on the side of the forge**, planned here and not there: the test of the AppSandbox
daemon (link 1), the VM (3), the tunnel (4) and the guest preflight (5). None of them is a mound.
The gateway (2) is a mound. Thus core starts it, and `dr-forge` only asks whether it answers. That
keeps [optional by construction](#optional-by-construction) intact. Core gets a general mechanism,
and each forge step stays behind `DRAUGR_FORGE`.

One result to keep in view here: the plan makes **core** responsible for the keeper session. That
session stops `sbx` from stopping an idle dependency 30 s after its last session *(measured)*. The
`post-up` hook of the gateway does that today. It keeps doing it for the times that you start the
gateway by hand, not as a dependency. The two keepers do not fight.

---

## What runs where

The daemon is a Windows process, and Draugr runs in WSL. Thus `dr-forge` reaches it as Draugr
already reaches `sbx.exe`: through `powershell.exe`, with path translation. `asb.py` has no
dependencies, so the shim is a call of Windows Python, not a packaging project.

**The daemon must run elevated** (*read*, and how each test here ran). The first draft said that it
did not need elevation, but it does. `dr-forge` cannot elevate for you. Thus it tests, and says so.

The tunnel supervisor and the keeper of the gateway are long-running Windows processes. They start
as the `post-up` hook of the gateway already starts the keeper: `Start-Process -WindowStyle Hidden`
through `powershell.exe`.

---

## Considered and rejected

- **ExHyperV as the backend.** No CLI, so it cannot be part of a loop. GPL-3.0. It also needs the
  Hyper-V role, whose ban on checkpoints for VMs with a GPU partition made rollback hard.
- **Our own scripts for the GPU-PV setup.** Driver injection is tied to the version of the host
  driver, and breaks on each GPU driver update. `gpuMode=1` removes the question.
- **The agent inside the forge**, also the computer use of Claude Desktop there. Then there is no
  mound and no boundary, and this is no longer Draugr. The forge is a machine that the agent *talks
  to*, never one that it lives in.
- **The bearer token of the daemon in the mound.** That gives the agent the power to create and
  delete VMs on your machine. The control/data split is the full reason why this is safe to build.
- **`netsh portproxy` into WSL, then `DRAUGR_HOST_PORTS`.** Needs administrator rights on the host
  and a second hop. The `localhost:` rule reaches Windows loopback directly.
- **A guest firewall in place of no adapter.** The agent is a guest administrator, so it can turn
  off any guest firewall (*measured* in NAT mode).
- **A separate project, not a Draugr feature.** The channel is the own proxy of the mound. The code
  loop is that of `dr-send`, the file loop that of `dr-data`, the egress that of `dr-policy`, and the
  consent model that of `dr-trust`. A sibling project copies five things that Draugr already does,
  and an optional part inside Draugr costs nothing.

---

## Open questions

*Resolved: whether to share one forge between projects. The disk layers answered it
([above](#one-forge-per-project-which-the-layers-decided)). What happens to a gateway directory, and
whether Draugr ships a gateway template. The
[topology](#which-directories-exist-and-which-of-them-you-keep) answered both. It ships one, and the
gateway is no longer a repository that somebody keeps.*

1. **Which Epic account.** A dedicated one is safest, and has its own empty Fab library. Your own is
   convenient, but puts your library and your account in reach of the agent. Refer to
   [Security](#security).
2. **What is the cost of the young age of AppSandbox?** The snapshot bug is the first real answer.
   The position of the author on pull requests is the second: fixes arrive on the schedule of the
   author. Watch it before you build much on top of it.
3. **Is `dr-layer` the right name?** It is beside `dr-up` and `dr-mem` in a public `bin/`, where
   "layer" means nothing until you read the forge docs. No better name yet.
