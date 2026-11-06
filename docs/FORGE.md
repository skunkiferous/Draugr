# The forge: a Windows VM your agent can build and test in

> ### Optional. Most people using Draugr will never want this.
> The forge is a **"by the way, you can also do this"** feature: a GPU-accelerated Windows VM on your
> own machine, so an agent in a mound can build and test Windows software. If you do not set
> `DRAUGR_FORGE`, none of this exists — no command runs it, no check mentions it, and nothing needs
> installing. See [Optional by construction](#optional-by-construction) for how that is enforced.

> ### Status: partly built, and the built part is measured.
> `dr-forge status`, `doctor`, `up`, `down`, `screen`, `exec` and `push`/`pull` exist and have been
> run against a live forge; `dr-setup --forge` writes the route WSL needs to reach one,
> `dr-forge init` applies what a new VM needs, and `dr-forge rm` takes one away. `base` and
> `rollback` are built and were verified live; `dr-forge gateway` generates the gateway mound; and
> `dr-layer` carries the six disk verbs, and `provision` builds a base from an ISO with every
> component in it - MSYS2, the tool set, the automation and screen servers, the vault mount,
> VS Code, and `.NET 3.5` when `--netfx` names the cab only a human can produce.
> **None of `provision` has yet been run end to end**, and nothing below the egress proof has
> been run at all: what is verified is listed with each stage.
> Claims carry one of three labels, the same bar the rest of these docs use: *measured* (run on this
> machine, result quoted), *read* (from source code or documentation, not run), and *unmeasured*.
> The network half is measured end to end. Protecting the VM's disk by hand, while the snapshot bug
> stands, is [FORGE-DISKS.md](FORGE-DISKS.md).

An agent in a mound can write Windows C++ and reason about software it can never run. The mound is
Linux; the target is Windows. That gap is what the forge closes — whether the work is building a
game, or running something you would rather not host yourself, such as an unknown mod off GitHub,
where a VM you can throw away is the whole point.

---

## Optional by construction

"Optional" is enforced by the structure of the code, not by remembering to be careful:

- **One switch.** Everything is inert unless `DRAUGR_FORGE` names a VM — the same gate `dr-plugin`
  uses with `DRAUGR_PLUGIN_STORE`. `dr-doctor` says nothing about the forge while it is empty.
- **Isolated code.** All of it lives in `bin/dr-forge` and `lib/forge/`. No core script sources it,
  and `dr-up` and `dr-go` never call into it unless the switch is set.
- **No new dependency for anyone else.** No Python, no AppSandbox, no PowerShell module on the
  default path.
- **Tests against a mock AppSandbox**, the way `tests/mocks/sbx` stands in for `sbx`: the bash
  half runs on any machine with zero skips, and `tests/forge-api.bats` additionally executes the
  daemon-facing PowerShell against `tests/appsandbox_mock.py` where a Windows host makes that
  possible, skipping where it does not (*built*). Neither needs AppSandbox installed.
- **Its security claim is separate.** The forge makes a weaker promise than a mound does, and
  `SECURITY.md` keeps it in its own clearly conditional section, so the core safety model stays
  exactly as it is for everyone who never turns this on.
- **Nothing game-specific in core.** The Unreal network rules live with the gateway, not in
  `share/`.

The Draugr fixes this work turned up are the exception, and rightly: they correct things that are
wrong for every Draugr user today, and none of them is forge-shaped.

---

## Where the line falls: Draugr owns the mechanism, you own the contents

*(decided)* Draugr's half is everything that would be the same whatever the VM is for.

| Draugr | the project that uses it |
|---|---|
| the VM as an object: create it on a parent disk, make it usable, throw it away | **which** parent, and what is inside it |
| the channel, the liveness chain, the screen, the git and file loops | nothing — these are the ordinary commands |
| the layer **mechanism**: differencing chains, `adopt`, `new`, `freeze`, `thaw`, `drop`, `list` | the **contents** of layer 1 and up |
| **layer-0**: a generic Windows base an agent can drive, and the list of components it *can* have | which of those components to turn on, and every layer above it |
| no network policy of its own | the allowlist the work actually needs |

**Why the contents cannot be Draugr's.** They are bound to an account and a vintage, which
[What is a layer, not the base](#what-is-a-layer-not-the-base) argues from asset libraries: a
library bought over a decade needs one editor per engine version, and *which* versions you need is a
fact about your purchases. A Draugr that shipped engine-layer logic would be shipping one person's
library layout as though it were a mechanism.

**So Unreal appears in these documents and in no Draugr code.** It is the use-case that drove the
design and the reason every measurement here exists, which is worth saying plainly to a reader. But
`kits/unreal`, the Visual Studio layer and the per-engine layer build belong to whichever project
wants them, consuming `dr-layer` and `dr-forge` exactly as any other user would. That is also why
[Optional by construction](#optional-by-construction)'s *nothing game-specific in core* needs no
exception: on this line there is no game-specific code to place.

**Layer-0's contents are judged per item**, and the test is *would a Windows VM built for something
else want this?* MSYS2, the Unix tools, VS Code, the automation server, the screen server and the
desktop camera all pass it, so they are unconditional.

**What does not pass becomes an optional component, off by default** *(decided)* — which
is better than deciding it in prose, because the flag records the choice where it is made instead of
leaving a reader to infer why something is in a generic base. `.NET Framework 3.5` is the first:
it entered because installing UE 4.27 raised Windows' own *"an app on your PC needs the following
Windows feature"*, so a base built for something else should not carry it, while a base built for
engine work must. Draugr ships the component; your project asks for it.

Its one precondition is worth refusing on rather than discovering mid-provision: it is a **Feature
on Demand**, and a guest with no adapter has no Windows Update, so its only source is the Windows
ISO payload — which `install-netfx3.ps1` reads from the vault. Enabling the component without that
reachable is a failure half an hour in, so it is checked first.

Where each of these lives, and which directories you actually keep, is
[below](#which-directories-exist-and-which-of-them-you-keep).

---

## Why not the obvious things

| | |
|---|---|
| UE5 in Linux/Docker | Produces a Linux build. Cross-compiling a *Windows* UE5 game from a Linux host is not a supported configuration. |
| Windows containers | Process isolation requires the guest build to match the host's; Hyper-V-isolated containers do not do GPU-PV. Neither runs the editor. |
| A second physical PC | Works, and is the honest baseline this has to beat. It costs a machine, and a network the agent can reach. |
| **A GPU-accelerated Windows VM on this machine, driven by the mound over ssh** | This. |

---

## The shape

The README's mental model is three repositories, and the forge keeps all three. What it changes is
*where the build happens*: inside the VM, instead of inside a mound. The gateway mound stays,
but only to give that machine its way out — it holds no clone and no files:

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

**The VM never reaches the network by itself.** It has no adapter of its own and one ssh channel
out — through the gateway, under the same `sbx` policy a mound would be under. The agent stays
in the project's mound and drives the VM across that channel, so the gateway mound is a network
appliance rather than a place to work: ["Two mounds, two
policies"](#two-mounds-two-policies). Three planes, kept apart:

| Plane | Between | Who holds it |
|---|---|---|
| **Control** | Draugr ↔ AppSandbox's API: create, start, stop, snapshot, delete | Draugr, host-side, in WSL. Never the mound, and never the guest |
| **Data** | the host repo ↔ the VM's clone, over ssh | Draugr, host-side: the ordinary git loop and file loop, with the VM as the far end |
| **Egress** | the VM → the internet, through the gateway | the `sbx` policy, exactly as for a mound |

---

## What the base image must contain

The forge VM is not disposable: it holds installs that cannot be copied in, only installed, and
[flattening it](FORGE-DISKS.md) is the only thing protecting them. So it is worth saying plainly what
a base image *is* — and, just as importantly, what it is **not**.

**The base is what every forge needs, whoever owns it.** Nothing in it is specific to one person's
account, one project, or one engine version:

| Capability | Why it has to be in the image | How, today |
|---|---|---|
| **A shared screen** | a human must be able to take over the desktop the agent is driving — see below | TightVNC, loopback-only, over the ssh channel |
| **Host directories, read-only and read-write** | the vault cannot live in the VM, and the agent must fetch assets itself | SMB over the tunnel: `V:` read-only, `S:` writable |
| **git** | projects are versioned, and git *is* the replication path to the host | MSYS2 |
| **rsync** | moving artifacts and logs without a share | MSYS2 |
| **A package manager** | the agent installs what it needs without asking permission each time | MSYS2/pacman, pinned to one allowlisted host |
| **GUI automation** | installers and dialogs have no CLI; the tree covers everything but Slate | a UIA-based MCP server in session 1 *(to build)* |
| **Autologin, unlocked** | session 0 is blind to every UI API | AppSandbox keeps the password from expiring |
| **The tunnel key and proxy settings** | the VM has no adapter; the gateway is its only way out | `guest/install-tunnel-key.ps1`, proxy at `127.0.0.1:3128` |
| **A dummy loopback adapter** | certificate revocation fails with no interface at all | see [below](#the-loopback-adapter) |
| **Windows Update off** | the guest otherwise patches itself and reboots mid-build | set in the base image |

### The default base, item by item

What follows is the decided contents of the shared base. Nothing here is account-bound, engine-bound
or project-bound; everything that is belongs in a [layer](#what-is-a-layer-not-the-base).

**All of it is one command.** `dr-layer provision` builds this base from a
fresh Windows 11 guest, on the **host** — which is not a preference: the guest has no adapter, so
until the host has raised the mound and the tunnel it can reach nothing and cannot set itself up. It
is idempotent end to end, every phase has a `--skip-<phase>` flag - and `--only` names the ones
you want instead - every phase verifies by effect, and the
four things it *cannot* do it names instead: installing AppSandbox, creating the VM and installing
Windows, placing the **first** ssh key (the API has no exec or key-deploy route), and signing in to
anything.

**GUI automation: Windows-MCP** ([CursorTouch](https://github.com/CursorTouch/Windows-MCP), MIT,
*read*). The deciding feature is not its tool list but its **transport**: it serves
SSE/Streamable HTTP on a configurable host and port, which is what an `ssh -L` forward needs. A
stdio-only server cannot work here, because stdio reached over ssh lands in **session 0**, where UI
Automation is blind — and that is not theoretical: the main alternative,
[deploymenttheory/windows-mcp-server](https://github.com/deploymenttheory/windows-mcp-server),
detects it is running without a desktop and *drops its desktop toolsets* rather than pretend. It
reads the accessibility tree rather than pixels, quotes 0.2–0.5 s per action, and carries token
auth, an IP allowlist and TLS, of which we need the token and loopback binding only.

Its cost is a **Python runtime** in the base (3.14+, installed through `uv`), and with it allowlist
entries for `**.astral.sh`, `pypi.org` and `files.pythonhosted.org` — plus `github.com` and
`objects.githubusercontent.com`, which is where `uv` fetches the interpreter itself from, rather
than python.org. The runner-up is worth remembering
precisely because it has no runtime at all — one Go binary — and documents this architecture
correctly, recommending an already-signed-in unlocked session with the server started at logon. If
Python ever has to leave the base, the route back is a small stdio-to-TCP shim in session 1.

**Elevation decides whether installers are automatable at all.** A third server,
[sbroenne/mcp-windows](https://github.com/sbroenne/mcp-windows), states the rule plainly: *Windows
security prevents any non-elevated process from interacting with UAC prompts or elevated
(Administrator) windows*. Installers are the main reason this VM wants GUI automation, and they
elevate.

**Measured, and it turns the problem into a much smaller one.** The two ways into this
guest do not have the same rights:

| Reached by | Session | Elevated? |
|---|---|---|
| `ssh` | 0 | **yes** — `IsInRole(Administrator)` is true, so sshd hands out a full token |
| the MCP server's `PowerShell` tool | 1 | **no** — a filtered token, the ordinary desktop case |

The guest's UAC settings are stock: `EnableLUA=1`, `ConsentPromptBehaviorAdmin=5`,
`PromptOnSecureDesktop=1`.

So **installing software is not the hard case**: done over ssh it is already elevated and no prompt
is ever drawn, which is why everything in this base installs from a script and nothing needed a
policy change. The hard case is narrow — a program *already running on the desktop* that elevates
mid-flight, whose consent dialog appears on the secure desktop where UI Automation, AutoHotkey and
VNC are all blind by design.

When that finally bites, the narrow fix is `PromptOnSecureDesktop=0`: the prompt stays, but on the
ordinary desktop, where it can be read and clicked. It can be set at that moment, on one VM, by
whoever accepts it. It does **not** need to be in the base image, and neither does
`ConsentPromptBehaviorAdmin=0`. Nothing is set today, and nothing so far has needed it.

**AutoHotkey v2: yes, for exactly one job.** Where the tree is visible, driving elements by name is
more robust than coordinates, so the MCP server wins. Its niche is the opposite case: replaying a
known path through a **Slate** window, where [the tree is empty](#what-the-tree-actually-sees-measured)
and every step would otherwise cost a model call. A frozen script runs that path with no model in
the loop. It is small enough that carrying it unused costs nothing, and like everything else it must
run in session 1.

#### Both installed and driven end to end *(measured)*

`lib/forge/guest/install-automation.ps1` - the gateway's, when this was measured - does the
lot over ssh, and none of it needed elevation
or a prompt: **uv 0.12.19** into `%USERPROFILE%\.local\bin` in 4 s, then one `uv tool install
windows-mcp` in 40 s, which pulled **CPython 3.14.7** and **windows-mcp 0.8.6** (on fastmcp 4.0.10)
with it, and **AutoHotkey 2.0.28** unzipped into `C:\Tools\AutoHotkey` — no installer, no file
association, nothing in `Program Files`.

| | Size |
|---|---|
| `uv` itself | 41.2 MB |
| CPython 3.14 | 60 MB |
| the server's environment | 153 MB |
| AutoHotkey | 4.3 MB |
| **total in the base** | **≈258 MB** |

The wheel cache is another 151 MB, and **`uv cache prune` reclaims none of it** — measured 150.7 MB
before and after, because every entry is still referenced by the tool's own environment. `uv cache
clean` takes it to 0, which is what a base image wants.

`windows-mcp install` registers its own scheduled task, and that is the part worth having: the
server came up **in session 1** while everything driving it sat in session 0. From the host, through
`ssh -L 18765:127.0.0.1:8765`, `initialize` answered 200 and a `Snapshot` call returned the live
desktop — the real `1920x1080` display, the taskbar, every open window, each element with
coordinates and an `[action: click]`. Without a bearer token the same request is **401**.

**It runs on 8765, not its own default of 8000**, because [UE's in-editor MCP
plugin](#an-optimisation-not-the-target-unreals-own-mcp-plugin) serves `http://127.0.0.1:8000/mcp`
inside the editor process. Two servers on one port is a fight decided by whoever started first, and
the loser is silent. 8000 stays reserved for the editor, and the tunnel already forwards it.

The clearest measurement is the same AutoHotkey script run from both sides:

| Launched from | What `WinGetTitle("A")` and `WinGetList()` returned |
|---|---|
| `ssh` (session 0) | `<error: Target window not found.>`, and **no windows at all** |
| the MCP server's `PowerShell` tool (session 1) | `C:\Windows\SYSTEM32\cmd.exe`, and the window list including `Program Manager` |

Same binary, same script, same user, same machine, one difference. It is the session-0 wall measured
a second way, and the reason the task matters more than the server.

#### Pixels, and what they actually need

[Rung 5](#the-ladder-of-doors) is the last thing that could have claimed a place in the base, and it
does not get one. "Take a snapshot and process the pixels" is really three jobs, and they do not cost
remotely the same:

| the job | what it needs | cost |
|---|---|---|
| find known **text** on a window | OCR — and **Windows ships one offline**, `Windows.Media.Ocr` | milliseconds, CPU, no download |
| find a known **icon** | template matching, OpenCV-class | milliseconds, CPU |
| understand an **unfamiliar** screen | a vision-language model | the only one that needs a model |

For *"click the thing that says Launch"* in a Slate window, the first row is the whole job, and
Windows already has it. Only the third needs a model, and it is rare **by design**: discovery happens
once, then [AutoHotkey replays the path](#discovery-is-expensive-repetition-should-not-be) with no
model in the loop.

**Nothing new has to be bought for the third row either, because the agent already is a vision
model.** A screenshot handed to it in its own mound is an image in its own conversation — no extra
service, no extra allowlisted host, nothing in the base image. `windows-mcp` already carries a
`Screenshot` tool, installed and verified.

**Borrowing the VM's GPU is the wrong trade.** GPU-PV gives the GPU to the *VM*, not to the mound, so
"let the agent borrow it" means running a model server **inside the forge** — several GB in the base,
and against the gateway's own deliberate rule that nothing in the VM talks to a
model. It would also compete for the one resource the VM exists for: shader
compilation, lighting builds and the editor. A resident VLM holding VRAM against a lighting build is
a loss, not a saving. Whether CUDA is even dependable through GPU-PV is unverified, and not worth
discovering on the critical path.

**A local model on the host is the right shape if one is ever wanted, and most of it already
exists.** Draugr ships [`share/ollama-proxy`](../share/ollama-proxy/): nginx in front of Ollama with
a default-deny allowlist, because Ollama has no authentication and no read-only mode — the same port
that serves inference serves `DELETE /api/delete`. `DRAUGR_MODEL_URL` already defaults to `11435`,
that proxy, rather than Ollama's own `11434`, and implicit loading is simply how Ollama behaves: the
first request loads the model and it unloads after the keep-alive window. This host has an RTX 4090
(24 GB — `Win32_VideoController` reports 4 GB, which is that field's 32-bit overflow), so a 7B vision
model is nothing on it. Ollama is **not installed here today**, and the loopback
rule is the prerequisite: if a `localhost:<port>` rule reaches Windows
loopback for the model port too, the proxy can bind loopback only, which is strictly safer.

None of that is a base-image question — the host and the mound are both outside the guest. So **the
base gets nothing**, and the condition that would change the decision is specific and measurable:
**many cheap looks rather than a few expensive ones** — watching a progress bar, waiting on a build
dialog — where per-call latency and cost start to dominate. Rung 5 is still *not attempted*, so there
is no evidence for it yet.

**The package set**, all from the pinned MSYS2 repository already on the
allowlist, so adding them needs no policy change:

| Package | Why it is in the default base |
|---|---|
| `git` | projects are versioned; git *is* the replication path to the host |
| `rsync` | artifacts and logs without a share |
| `openssh` | keys, `ssh-keygen`, `scp` |
| `curl`, `wget` | fetching through the gateway proxy |
| `unzip`, `zip`, `p7zip` | assets arrive as archives |
| `jq` | `.uproject` is JSON — this is how `EngineAssociation` gets set without a GUI |
| `diffutils`, `patch` | comparing and patching config between engine versions |
| `make` | build glue |
| `openssl` | hashes and certificates |
| `less`, `file`, `tree`, `nano` | the minimum for a human who has to look around over ssh |
| `ripgrep`, `fd` | searching a 100+ GB tree at a usable speed (**UCRT64** builds, into `/ucrt64/bin`) |

*Measured*: the whole set installed and verified running, and MSYS2 grew from **439 MB to
487 MB** — **48 MB** for the lot. Two traps, both of which produced confident wrong answers first:

- **MSYS2's native packages are UCRT64 now.** The prefix is `mingw-w64-ucrt-x86_64-`, not
  `mingw-w64-x86_64-`, and the binaries land in `/ucrt64/bin`. The old names do not error usefully;
  they report *"target not found"* as if the package did not exist at all.
- **pacman needs stdin closed over ssh.** An ssh session has no terminal, so any prompt `--noconfirm`
  does not cover blocks **forever** — no output, no CPU, no process, and nothing in `pacman.log` but
  the command line. `< /dev/null` turns that silent hang into a readable error. The same trap has a
  second edge: appending the redirect to a *pipeline* redirects only its last stage, so
  `foo | head -1 < /dev/null` reads nothing and reports every tool missing. Wrap the pipeline in a
  subshell instead.

**Not `python` from pacman.** MSYS2's Python is a POSIX build; the MCP server needs the *Windows*
interpreter for COM and UI Automation. The two coexist badly and only one of them can drive the
desktop, so the base carries the Windows one via `uv` and leaves pacman's alone.

#### Licences, since this base installs itself

Not legal advice — this is what the declared licence metadata says, read from the 26
MSYS2 packages and 90 Python distributions actually installed in a built guest.

Every component is OSI-approved open source. No proprietary component, no clickthrough EULA, no
registration, no per-seat term.

| | |
|---|---|
| GPL-2.0 | git, tree, AutoHotkey v2, TightVNC, `fuzzywuzzy` |
| GPL-3.0-or-later | rsync, wget, diffutils, patch, make, less, nano, bash, coreutils, grep, sed, gawk, `msys2-runtime` |
| MIT / BSD / Apache-2.0 / ISC / Unlicense | curl, jq, openssl, zip, openssh, ripgrep, fd, `uv`, and about 85 of the 90 Python packages |
| Other permissive | unzip (Info-ZIP), file, pillow (MIT-CMU), pywin32 and `typing_extensions` (PSF) |
| Weak copyleft | `certifi` (MPL-2.0) |

**Automated, unattended installation is not something these licences restrict.** They govern copying,
modifying and *distributing*, not the manner of obtaining or starting a program — and the GPL says so
outright: GPLv2 §5 and GPLv3 §9 both state that accepting the licence is not required in order to
*run* the software. There is no agreement for a script to click past. The licences that do require
interactive acceptance belong to proprietary software, and the base contains none.

Nor does provisioning **redistribute** anything: each component is fetched from its own upstream to
the machine being built, exactly as a package manager does, so the person running it obtains their
own copy and nothing passes through this project.

**Distribution starts when a built image is handed to someone else.** A VHDX, a snapshot or a disk
carries GPL binaries, and GPLv2 §3 / GPLv3 §6 then require the corresponding source or a written
offer alongside it. Most of this base is GPL-3.0, so that is real work rather than a formality —
which is worth stating as a design consequence: **a provisioning script is the licence-cheap form of
a base image, and shipping the disk is the expensive one.** That is an argument for
`forge-provision.ps1` over publishing a prepared disk, independent of size.

Two items to look at first if an image is ever shared:

- **`p7zip`** is LGPL *plus* `custom:unRAR`, the only component in the set that is not plainly OSI.
  The unRAR clause forbids using that code to build a RAR-compatible archiver, which nothing here
  does; dropping p7zip (`bsdtar` covers most of its use) would leave a fully OSI base.
- **`fuzzywuzzy`** (GPLv2) and **`python-levenshtein`** (GPL-2.0-or-later) arrive as dependencies of
  `windows-mcp`, which is itself MIT. That is a consistency question for that project rather than an
  obligation on anyone running it, but it does mean the Python environment contains GPL code.

**What is not settled here:** a licence and a website's terms of use are different documents, and a
site may restrict automated fetching even where the software is permissive. For four of the five
sources the question barely arises — PyPI and `repo.msys2.org` exist to be read by package managers,
`astral.sh/uv/install.ps1` exists to be piped into a shell, and `autohotkey.com/download/2.0/version.txt`
is the documented way to check for a new version. `tightvnc.com` has not been checked against its own
terms; the fetch is one file, once, at a human's command, and `install-screen-access.ps1 -Msi`
accepts a file obtained any other way.

### What is a layer, not the base

**The engine does not belong in the base image**, and neither does the Epic Games Launcher. Both are
personal: the Launcher is bound to an account, and the engine is bound to a *vintage*.

The reason is an ordinary fact of asset libraries rather than anything exotic. Marketplace assets are
supported for the engine versions current when they were sold, and authors stop updating them once
sales dry up — so a library bought over a decade spans engine versions back to **4.x**. Using such
an asset means opening it in the last editor that supports it, materialising it into a project, and
migrating that project forward. A user with a deep library therefore needs *many* editors, one per
vintage, and no single base image can hold them: at 100+ GB installed, a dozen versions is more than
a terabyte of near-identical Windows.

So the minimum shape is **one engine-free base, plus one layer per engine version** — which is the simple case of a chain that stacks further ([below](#layers-stack-and-only-the-top-one-is-appsandboxs)):

```text
layer-1.vhdx                 the accounts and toolchains layer   <- read-only parent
  +-- layer-2-ue427.vhdx     differencing child: one editor
  +-- layer-2-ue53.vhdx      differencing child: one editor
  +-- layer-2-ue58.vhdx      differencing child: one editor
```

**The mechanism is a differencing VHDX, not AppSandbox's snapshots.** `New-VHD -ParentPath
<base> -Differencing` creates the child directly, and AppSandbox takes `VhdxPath`
[verbatim](FORGE-DISKS.md#how-appsandbox-stores-a-vm) — so a hand-made child is an ordinary VM disk
and the [snapshot bug](#it-has-a-bug-that-decides-the-design) never enters into it. Each child costs
one engine, not one Windows.

Three rules come with it, and the first is absolute:

- **The parent is never written to once a child exists.** Any change to it invalidates every child.
  It must therefore live outside every VM folder, which the
  [delete hazard](FORGE-DISKS.md#the-vms-folder-is-derived-from-the-disk-path-not-from-its-name)
  already requires for archives.
- **Children accumulate general drift**, not only the engine: Windows updates, caches and settings
  all land in the child. They grow — and the rule is harsher than it first looks, because a
  differencing child grows by every block ever **written** and never gives one back. Delete a 10 GB
  file in the guest and the child stays exactly as large. The cost of a file is not what it holds,
  it is every block it has ever touched.

  *Measured on `ue-427-test`:* **31.0 GiB of delta over a 21.6 GiB parent** after five
  days of ordinary use, with the engine itself in the frozen parent and nothing of the sort in the
  child. The chain was intact and correct — `layer-0` flat → `layer-1` → `layer-2-ue427` → the VM —
  so none of it had leaked out of the layers. Two of Windows' own files explain most of it, and
  both are enormous *and* constantly rewritten, which is the worst combination under that rule:
  `pagefile.sys`, whose growth follows commit charge and is unbounded in principle, and
  `hiberfil.sys`, 40–75% of RAM for a file a VM will never read once. Neither was managed by the
  base image.

  *Worth stating because the obvious claim is wrong, and was in these docs until it was corrected:*
  Microsoft publishes **no single system-managed formula**. The minimum follows the crash-dump
  setting; growth follows commit charge, when it passes about 90% of the commit limit. With the
  default *automatic* dump the file starts small and only rises to min(RAM, 32 GB) after a second
  crash within four weeks. "1.5× RAM" and "3× RAM" are troubleshooting heuristics that became
  folklore. *Measured on the host:* 127.9 GiB of RAM, system-managed, **8192 MB
  allocated, peak usage 0** — about a sixteenth of RAM. So the case for pinning a pagefile is not
  that system management is profligate; it is that an unbounded file is permanent in a child. [`dr-forge init`](#making-a-forge-usable-and-unmaking-it-init-and-rm) now fixes both.

  **Why that fix is per-VM and not in the base image:** putting it in a base would mean every VM
  already built on an existing layer needs the whole chain rebuilt to get it. Applied per VM it
  reaches any VM, on any layer, at any time — the difference between a fix and a migration. It
  stops the growth and reclaims nothing: blocks already in a child stay until the chain is
  flattened or the VM is rebuilt.
- **Unproven.** Nothing here has been measured yet; it is the obvious next disk experiment, and it
  is cheap to try on a throwaway VM.

### Where Visual Studio goes, and why it is one layer rather than many

**The engine's Visual Studio requirement tracks its vintage too**, so it cannot simply live in the
shared base: Epic's own table for 4.27 lists *"4.22 or Later: VS 2017 / VS 2019"* and *"4.25 or
Later: VS 2019 (Default)"*, with VS 2022 unmentioned for 4.x, while 5.x moves on to VS 2022
(*read*). A library spanning 4.x and 5.x therefore spans at least two Visual Studios.

**But VS versions install side by side**, which is what makes a single personal base workable:
Microsoft supports it explicitly, each major version (2017 / 2019 / 2022) living in its own folder
with its own components (*read*). So several Visual Studios can sit together in one layer.

They **must** sit together, in fact, rather than one per engine layer: SDKs, C++ toolsets and
runtimes are **shared** between installations, so changing a workload in one version can alter what
another sees, and uninstalling one strips file associations for all. Components that reach across
each other cannot be cleanly separated into different disk layers — they belong in the same one.

One trap inside VS 2022 that a layer cannot fix: **UE 5.0 to 5.5 will not build with an MSVC toolset
newer than 14.38** (*read*). It is a rule about those versions only - **UE 5.8 built here with the
current toolset** (*measured*) - but it means an old engine and a
new one want different compilers. VS 2022 can hold several at once, so the fix is to pin the toolset
rather than the Visual Studio; the layer just has to be built holding both.

#### Where the installer comes from, and why the URL is also the checksum

Use the `aka.ms` redirector, because it is the form the guest can already reach:

```text
https://aka.ms/vs/17/release/vs_community.exe     ->  301
https://download.visualstudio.microsoft.com/download/pr/<guid>/<sha256>/vs_Community.exe
```

Both hops are already in `kits/unreal`: `aka.ms` as the redirector, and
`download.visualstudio.microsoft.com` under `**.visualstudio.microsoft.com`. **No rule needs adding.**
Swap `vs_community.exe` for `vs_BuildTools.exe` for the compiler without the IDE.

**The number is the product version, not the year**, and the two are far enough apart to catch anyone
out. All three resolved and were hash-verified:

| URL | Visual Studio | bootstrapper | SHA-256 (from the redirect) |
|---|---|---|---|
| `aka.ms/vs/15/release/vs_community.exe` | **2017** | 4,420,888 B | `1bf11fc98cf22d93498180d50794219a0cbb860a98880e29836bb66acadc0123` |
| `aka.ms/vs/16/release/vs_community.exe` | **2019** | 4,422,856 B | `d70a79f50e37c337227a928875fcef8d233b71056d4c967f070d92f1584d2c7e` |
| `aka.ms/vs/17/release/vs_community.exe` | **2022** | 4,474,136 B | `e6b61fd64e03ffa252060602e3873ef09dff477c168d3aeab233e07299e82344` |

**A WRONG VERSION NUMBER DOES NOT 404 - IT RETURNS HTTP 200 AND AN HTML PAGE.** An `aka.ms` short link
that does not exist redirects to Bing: `vs/19` and `vs/22`, which look like the obvious spellings of
2019 and 2022, both answer

```text
302 -> https://www.bing.com?ref=aka&shorturl=vs/19/release/vs_community.exe
200    Content-Type: text/html
```

so `curl -O` or `Invoke-WebRequest -OutFile` writes a web page to disk under the name
`vs_community.exe` and reports success. Measured, after exactly that mistake. This is the
strongest argument for checking the hash: a bad engine version, a bad product number or a typo all
arrive as a 200, and only the hash tells them apart from the real thing. Checking the `Content-Type`
is a cheaper first line of defence - `application/octet-stream` for a real bootstrapper, `text/html`
for Bing.

**The redirect target's second-to-last path segment is the file's SHA-256.** Measured:
`aka.ms/vs/17/release/vs_community.exe` resolved to a URL ending
`.../e6b61fd64e03ffa252060602e3873ef09dff477c168d3aeab233e07299e82344/vs_Community.exe`, and
`sha256sum` on the 4,474,136-byte download returned exactly that. So a pinned, verifiable download
costs one `curl -I`: resolve the redirect, keep the URL, and the hash to check against is inside it.
That is the opposite of MSYS2, which publishes no `.sha256` at all and forces a pin to be made by hand
(see `lib/forge/guest/install-msys2.ps1`).

Microsoft's own download page offers
`c2rsetup.officeapps.live.com/c2r/downloadVS.aspx?sku=community&channel=Release&version=VS2022`
instead. It works, and serves the same bootstrapper (4,475,880 bytes - the difference is branding on
the stub), but `c2rsetup.officeapps.live.com` is a **different apex from anything the kit allows**, so
using it from the guest means widening the policy for no gain. Prefer the `aka.ms` form.

Note that all of these are the ~4.3 MB **bootstrapper**, not the product: it then downloads payloads
from `download.visualstudio.microsoft.com`, which is why that host matters more than the installer
link does. The payloads are reachable too, which was worth checking rather than assuming:
Microsoft has moved older Visual Studio releases behind a `my.visualstudio.com` sign-in before.
Measured, with no credentials sent:

| | channel manifest | build it serves |
|---|---|---|
| `aka.ms/vs/15/release/channel` | 200, 73,540 B | `VisualStudio.15.Release/15.9.83` - VS 2017's final servicing build |
| `aka.ms/vs/16/release/channel` | 200, 134,478 B | `VisualStudio.16.Release/16.11.60` |
| `aka.ms/vs/17/release/channel` | 200, 91,781 B | `VisualStudio.17.Release/17.14.41` |

and a payload named by the 2017 manifest - `vs_Setup.exe`, 4,420,872 B on
`download.visualstudio.microsoft.com` - answered 200 with no `WWW-Authenticate` header. So all three
Visual Studios install through the hosts `kits/unreal` already allows.

#### Mounting the vault so the desktop can see it

*(measured, after a base image shipped without the last part and cost an evening)*

`V:` and `S:` are SMB shares over the tunnel, mapped by `guest\mount-vault.ps1` **inside the guest**.
Two things about Windows make a successful mount invisible anyway, and neither says a word:

| | |
|---|---|
| A mapped drive belongs to a **logon session** | One mapped from an ssh session never reaches the desktop. The script reported `V: -> \\127.0.0.1\vault` and `vault entries: 1516`, and `dir V:` on the desktop answered *"A drive with the name 'V' does not exist"* |
| Within one logon it is per **elevation token** | An administrator's logon has two, and a drive mapped in one is not in the other |

Those two combine into a trap, because the vault's password file is readable only by SYSTEM and
Administrators - so `mount-vault.ps1` can only run **elevated**, and the drive it maps is then
invisible to Explorer and to the unelevated Epic Games Launcher. Elevating a shell to reach `V:`
works, but nobody should have to: a mounted drive is something you expect to open in Explorer.

**The base image sets `EnableLinkedConnections`** (`install-guest-base.ps1`, section 9b), which makes
Windows copy a mapping to the linked token, so one mount serves both. It needs a reboot, which a base
image gets anyway. What it costs is worth stating: an unelevated process can then use a connection an
elevated one established. In this guest that boundary is already thin - a single account, a local
administrator, with the agent's own session elevated - and the credential is worth read-only on the
vault plus write on the scratch share. `-SkipLinkedConnections` declines it.

The alternative, loosening the ACL on the password file so the mount can run unelevated, trades the
same boundary the other way round **and** leaves elevated installers without `V:`. It relocates the
choice rather than avoiding it.

So: mount it on the desktop, at either elevation, once.

#### Download once, install many times: `--layout`

A layer that will be rebuilt should not re-download Visual Studio each time, and the guest should not
need Microsoft reachable at all to receive it. `--layout` makes an offline cache; the vault carries it
in, read-only:

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

**Three ways this goes wrong, all measured.**

**1. Run bare, it returns instantly and lies.** `vs_setup.exe` is a **GUI-subsystem binary**
(PE subsystem 2), so no shell waits for it: the prompt comes straight back and `$LASTEXITCODE`
is `0` because the *launch* succeeded. The install may be running, may have finished, or - as
it did here - may have failed fourteen seconds later with nothing on screen. `Start-Process
-Wait -PassThru` is what makes the exit code mean the install.

**2. No `--add` is needed, and naming them can be worse than useless.** Each layout holds a
`response.json` recording what was cached, and the bootstrapper passes it automatically - visible
in the installer log as `--in "V:\installers\vs2022\Response.json"`. So the minimal command
installs exactly what the layout contains. That matters most for **VS 2022**, whose layout here
records *two* components - `Workload.NativeGame` **and**
`Component.VC.14.38.17.8.x86.x64` - and a hand-written `--add Workload.NativeGame` would
quietly get you 14.44 alone, without the 14.38 that UE 5.0-5.5 requires.

**3. `--lang` is a layout switch, not an install switch.** At install time the installer
answers `Option 'lang' is unknown`, prints its usage and exits **87**
(`ERROR_INVALID_PARAMETER`) - before `--quiet` is ever applied, so it looks like a silent
no-op. The install-time spelling is `--addProductLang`, and with a single-language layout
neither is needed: the bootstrapper already passes `--locale`.

A failed attempt still leaves ~125 MB of Visual Studio Installer client under
`C:\Program Files (x86)\Microsoft Visual Studio\Installer`. That is the installer itself, it is
needed anyway, and the next run reuses it. `%TEMP%\dd_installer_*.log` names the real fault in
its first fifteen lines, which is where to look before anything else.

**`--norestart` is not free-standing.** It is refused unless `--quiet` or `--passive` comes with it, and
the refusal arrives as a GUI usage dialog rather than a non-zero exit, so a script that looks like it
ran has in fact done nothing (*measured*, VS 2017 layout). `--passive` shows a progress bar and
needs no input, `--quiet` shows nothing at all. Exit code **3010 is success** with a reboot pending, not
a failure. A layout also carries its own `response.json`, so the `--add` line above is a restatement of
what the bootstrapper would default to, not a requirement.

Four things that cost real money if skipped:

- **`--add` is not optional.** Without it `--layout` fetches the entire product, well over 100 GB.
- **`--lang en-US` is not optional.** Without it, every language pack.
- **The layout must hold every component you will ever want**, because `--noWeb` cannot fetch a missing
  one later. That is where the MSVC &le; 14.38 pin above has to be applied - at layout time, not at
  install time - along with whatever Windows SDK the engine vintage needs.
- Re-running `--layout` on the same directory is **incremental**, so an interrupted download costs
  nothing.

**Record the RESOLVED url, not the `aka.ms` one**, if the same bytes matter. `aka.ms/vs/17/...` follows
the current servicing build and its hash moves with it; the `download.visualstudio.microsoft.com` url
it redirects to names one immutable file and carries that file's SHA-256 in its own path. The `aka.ms`
form is the right thing to *document*; the resolved form is the right thing to *pin*. VS 2017 is the
exception either way - 15.9.83 is its final build, so there is nothing left for it to move to.

#### Will this layer build the engine versions I need?

**The short answer for the layer this repository describes: 4.15 through 5.8, including 5.6 and
5.7.** If that is all you wanted, stop here.

**Why Visual Studio is in the layer at all**, for anyone who does not write C++ and would rather not
start. Unreal is a C++ program. Even a project that is pure Blueprint compiles C++ whenever a plugin
is rebuilt, whenever the engine is built from source, and whenever an asset pack ships code. The
engine does that compiling by calling Microsoft's compiler, so the compiler has to be on the disk.
Nobody has to open Visual Studio or read any C++ for this to matter - it matters the first time an
engine refuses to finish loading a project.

**The one thing that can go wrong** is a version mismatch. Microsoft's compiler is versioned
separately from Visual Studio itself and is called a **toolset**, numbered like `14.44`. One Visual
Studio installation can hold several side by side, and the engine picks one. An engine refuses a
toolset that is newer than it knows about - not older - so the risk is always *too new*, never
*too old*.

That is the whole of it. Everything below is bookkeeping about which numbers are present.

**What this layer holds**, read back from the guest rather than from memory:

| from | toolset | the engines that accept it |
|---|---|---|
| VS 2017 | 14.16 | 4.15 - 4.24 |
| VS 2019 | 14.29 | 4.22 - 5.0 |
| VS 2022 | **14.38** | 5.0 - 5.5, which refuse anything newer (*read*) |
| VS 2022 | **14.44** | 5.4 and up, including **5.8** (*measured*) |

**5.6 and 5.7 are not separately measured here**, and it would be dishonest to claim otherwise. They
are bracketed: 5.5 and earlier are covered by 14.38, and 5.8 was measured building with the current
toolset in this very project - `UnrealBuildTool` reporting `Result: Succeeded`, and Build Solution
succeeding in the IDE, in a guest with no network adapter. A version in between needing something
outside that pair would be a surprise. If you want certainty before committing a layer to it, the
engine states its own answer: `Engine/Source/Programs/UnrealBuildTool/Platform/Windows/`
names the preferred and minimum toolchain versions in source, and a build that dislikes the toolset
says so in its first few lines rather than failing obscurely later.

**What would actually stop this layer serving 5.6 - 5.8**, in order of likelihood:

1. **An engine wanting a toolset newer than 14.44.** 14.44 is the newest that Visual Studio 2022
   17.14 offers, so the fix is not a bigger `--add`: it is a newer Visual Studio servicing build,
   which means refreshing the offline layout and reinstalling. This is the only failure mode that
   the layer genuinely cannot absorb, and it is the one to watch as engines move on.
2. **A missing Windows SDK.** This layer has `10.0.19041.0` and `10.0.26100.0`, which spans what
   5.x asks for. A newer engine wanting a newer SDK is an `--add` and a re-install, not a rebuild.
3. **Nothing about .NET.** Unreal ships its own .NET under `Engine/Binaries/ThirdParty/DotNet`, so
   the build tools do not depend on what Windows has.

Note what is *not* on that list: needing a different Visual Studio per engine. All three live in one
layer on purpose, for the reason given above - their SDKs, toolsets and runtimes are shared.

#### Rebuilding the layouts

*Only relevant if you are making the offline installers again, or adding a toolset to them.*

A layout records its own selection in `response.json`, so this is read back from the layouts rather
than remembered. All three were built from one identical line (*measured*):

```json
"add": ["Microsoft.VisualStudio.Workload.NativeGame;includeRecommended"], "addProductLang": ["en-US"]
```

`--includeRecommended` brings the channel's current toolset and **only** that one, which is why the
2022 layout arrived holding 14.44 alone and had to be told about 14.38 as well. `--noWeb` cannot go
and fetch a missing one at install time, so every toolset you will ever want has to be in the layout
before it is carried into a guest:

```powershell
# on the HOST. Incremental - this fetches the extra toolset, not the 4 GB again.
& $bootstrapper --layout D:\VaultHolder\installers\vs2022 `
                --add Microsoft.VisualStudio.Workload.NativeGame `
                --add Microsoft.VisualStudio.Component.VC.14.38.17.8.x86.x64 `
                --includeRecommended --lang en-US --wait
```

That component id is verified against the layout's own `Catalog.json`, which offers every toolset
from 14.29 to 14.44 under the same `VC.<toolset>.<product>.x86.x64` spelling - so any other engine
pin is one `--add` away by the same pattern. A layout whose toolset set is written down is
repeatable in the sense that matters: it produces the same layer twice, not merely a run that
finishes.

### Layers stack, and only the top one is AppSandbox's

A differencing disk's parent may itself be a differencing disk, so the chain can be as deep as the
design needs:

```text
layer-0.vhdx               Windows, toolchain, screen, mounts, tunnel   read-only
  \__ layer-1.vhdx         the Launcher, VS 2017 / 2019 / 2022          read-only
        \__ layer-2.vhdx   one editor                                   read-only
              \__ layer-3.vhdx   empty on creation - the VM writes here
```

**Layers are numbered, not named after what is in them.** The number is the depth and nothing
else: `layer-0` is the default base this repository builds, and every layer above it is whatever
its owner decided to put there. That is the point — what belongs at layer 1 is a judgement that
differs per person and per project, but *"layer 2 is a child of layer 1"* is structural and cannot
drift. Every layer below the top is read-only, which the numbering makes obvious at a glance.

Two practical notes:

- **Layers 2 and above have siblings**, one per engine version and one per project, so the number
  alone is not a name: `layer-2-ue553`, `layer-3-tabulua`. Layers 0 and 1 are single.
- **The 15-character cap is on VM names, not on disks.** A VM's folder is derived from its disk
  path rather than its name ([why](FORGE-DISKS.md#the-vms-folder-is-derived-from-the-disk-path-not-from-its-name)),
  so disk directories can be as descriptive as you like — `layer-2-ue-5.5.3\disk.vhdx` is fine.
  Only the guest hostname has to fit, and a frozen layer needs no VM at all: one exists while the
  layer is being built, and for the layer-3 VMs that do the work.

The top disk is the only one **AppSandbox ever points at**, and that is the point: `asb_vm_delete`
removes the VM's folder recursively, so a throwaway top layer means the blast radius contains
nothing that took an hour to build. Everything below it lives outside AppSandbox's reach entirely,
and a ruined VM costs a `New-VHD -Differencing` rather than a restore.

What it costs, and what has to be true:

- **Every parent is frozen once a child exists.** Building a layer means booting it *as* the top,
  installing, shutting down cleanly, then never writing to it again. The chain is built once,
  bottom-up.
- **A four-level chain builds, and a child can be bigger than its parent** *(measured)*. `New-VHD -Differencing` three times over a 512 MB dynamic base, then
  `Resize-VHD` on the **top** disk to 1 GB: it reports `VhdType: Differencing`, `Size:
  1073741824`, `ParentPath: L2.vhdx`, and all four files sit at 4 MB on disk. So depth is
  real, thin provisioning holds at every level, and growing a layer above an unchanged
  parent works through the ordinary cmdlet — not only through the API AppSandbox uses for
  template instances.
- **What that does *not* prove**: that HCS boots a guest from four levels, or what reads
  cost when they walk the whole chain. Keep the volatile layers near the top until a real
  guest has run on one.
- **Children share one Windows identity** — same SID, same hostname. With no network adapter that
  is mostly moot, but two children running at once would reach the mound's SMB share as the same
  machine, which is worth measuring before relying on it.

This is the shape `dr-forge` has to manage, and it is more than `base` and `rollback` can carry:
creating a child, freezing a layer, listing a chain, discarding and recreating the throwaway top,
and merging a layer down when it has earned permanence. **Unproven, all of it** — the first
experiment is a two-level chain on a throwaway VM, which costs almost nothing to try.

### One forge per project, which the layers decided

This was [open question 1](#open-questions) for as long as a forge cost 100+ GB. **The only argument
for sharing one forge between projects was its size**, and it was a strong one: a dozen projects each
carrying their own Windows, Visual Studio and engine is a terabyte of near-identical disk. Against it
stood the isolation that *one mound, one repo* exists to provide — a shared forge lets two projects'
agents read each other's code.

The layers remove the cost argument entirely, so the isolation argument wins uncontested:

```text
layer-0  Windows + the default base        ~35 GB    shared, read-only
layer-1  accounts, Visual Studio           ~25 GB    shared, read-only
layer-2  one engine version               ~100 GB    shared, read-only
layer-3  one project                     the delta   per project, writable
```

Three projects on one engine cost **one** copy of the 160 GB, not three. A per-project forge is now
barely more than the project's own footprint, which is what a per-project anything ought to cost.

**How disposable layer 3 is depends on where the project lives, and that is the user's call, not
ours.** Draugr puts a repo's clone *inside* the mound rather than on a host mount for a reason that
applies here unchanged: a source-of-truth the agent can reach directly is one whose history the agent
can rewrite without anyone noticing. By that reasoning the clone belongs on the VM's own disk —
`DRAUGR_FORGE_DIR=D:\work\MyGame`, where `D:` is layer 3 — with the host's repository out of reach
and the agent pushing for review like any other contributor.

The counterweight is specific to games: a project heavy in binary assets is expensive to hold twice,
and `DRAUGR_FORGE_DIR` accepts a mount just as readily (`V:` is the vault, read-only; `S:` is
scratch). So the key takes either, and the trade is stated rather than decided:

| `DRAUGR_FORGE_DIR` | what it costs | what it buys |
|---|---|---|
| `D:\…` — the VM's own disk | the project is held twice, which hurts most with large binary assets | your repository and its history stay outside the agent's reach |
| `S:\…` — the scratch mount | the agent works in your tree, history included | one copy, and no push-to-review round trip |

What is regenerable is disposable either way — the DDC, `Saved\`, `Intermediate\` and cooked output
can always be rebuilt, and keeping them on `S:` keeps layer 3 small whichever choice you make. But
with a clone on `D:`, layer 3 holds work that matters until it is pushed, so **re-forking is not free
and must not be automatic.** That is the recurring cost of layering: **a parent cannot be written to
once it has children**, so updating Visual Studio or patching an engine means building a new layer
beside the old one and re-forking each project onto it — after each one has pushed.

What this decision does *not* change, and one thing it retires:

- **RAM is untouched.** A running forge is a running forge, so the budget still says one at a time
  Per-project forges are *defined* in parallel and *run*
  one at a time, which is how anyone works on a project anyway.
- **Children share one Windows identity** — same SID, same hostname as layer 0. With one forge
  running at a time and no network adapter, this stops being a question worth measuring.
- **The run-state lock is no longer on the critical path.** Sharing a forge would have needed it:
  one desktop, one cache and one editor between two agents at once is a risk to make impossible
  rather than document. Per-project forges never create that situation, so the lock becomes a
  nicety rather than a prerequisite for shipping. It still earns its place wherever a tree has more
  than one writer - which the `S:` choice above creates, since the agent in the VM and you on the
  host are then both working the same files.

### Which directories exist, and which of them you keep

*(decided)* One forge per project settles how many **VMs** there are. How many
*directories* is a different count, because the gateway turns out not to be a project you keep.

| Directory | How many | Pushed | Holds |
|---|---|---|---|
| **Draugr** | one | publicly | the mechanism: `dr-forge`, `dr-layer`, layer-0, and the gateway template |
| **your forge project** | one | privately | the allowlist, the layer-1-and-up build logic, which layer-0 components to enable |
| **a game project** | one per game | wherever that game lives | the agent's mound, `DRAUGR_FORGE`, and where the git loop lands |
| **a gateway** | one at a time, generated | never | derived from the template plus that allowlist |

**Exactly one gateway can run, and that is a constraint rather than a preference.** `DRAUGR_PORTS`
publishes the fixed host ports `18888` and `18445`, `18022` is
[pinned](#the-pinned-port-has-a-price-a-far-end-is-not-identified-by-the-vm-being-up), and the
supervisor holds one mutex, `Global\Draugr.forge.tunnel`. So however many gateway directories
existed, one could be up — and therefore one forge VM is reachable at a time. A gateway per VM would
be a set of mutually exclusive directories: all of the maintenance, none of the concurrency.

**So the gateway is generated, not maintained.** It is nearly all mechanism — tinyproxy, samba, the
denied `sbx` defaults — and only its allowlist is personal. It is created into a local directory
under `DRAUGR_ON_MISSING_REPO=create-data-only`, which inits a repository whose `.gitignore` is `*`:
every Draugr command works, nothing is tracked, and there is nothing to push or keep in step. What
varies is the allowlist, and it varies **by kind of work rather than by VM** — Epic's hosts are the
same for 4.27 as for 5.8 — so it is regenerated when the work changes, not when the VM does.
Narrower is also better rather than merely tidier:
narrowing the defaults means a gateway generated for one job beats one that is the union of
every job.

**The gateway holds no clone, and never did.** [What crosses](#what-crosses) says it plainly: the
code and the data live in the VM, and the gateway governs what the VM may *reach*. Work comes back
two ways that already exist — the git loop with the VM as its far end, landing in the game project on
the host, and `S:`, the writable scratch share. The vault beside it is mounted `:ro`, so scratch is
the only path the guest can write to, which is the whole reason there are two.

**This topology follows from the pin.** Un-pinning `18022` would allow concurrent forge VMs, at the
cost of a mound rule per VM — and then per-VM gateways would be real. The pin buys one stable rule;
this is the other half of that trade.

### An updates layer, for when there are many project VMs

Software updates arrive constantly; a frozen layer cannot take them. Clicking "update now" is trivial
next to reinstalling Windows, Visual Studio and a 100+ GB engine — so the question is where those
updates land.

**The option: a layer that exists to be thrown away.** It starts empty, accumulates patches, and is
*replaced* rather than extended, so the chain never grows. The payoff is in the transition, because an
old layer cannot be deleted until every VM above it has been rebuilt:

| | held during the changeover |
|---|---|
| rebuilding the base layers | old base **and** new base — the full ~160 GB, twice |
| replacing an updates layer | one base, plus the old and new updates layer — tens of GB, twice |

**Where it goes is not obvious, and only one answer works.** Engine layers have *siblings*, one per
vintage, so an updates layer placed **below** them (between layer 1 and the engines) would invalidate
every engine install each time it was replaced — reinstalling 100+ GB to collect a Windows patch.
It has to sit **above** the engine layer, which means **one updates layer per engine vintage**:

```text
layer-1  accounts, Visual Studio
  +-- layer-2-ue553
  |     \__ layer-U-ue553     patches; replaced, never extended
  |           +-- layer-3-projectA
  |           \__ layer-3-projectB
  \-- layer-2-ue58
        \__ layer-U-ue58
```

That duplication is acceptable, because only the **active** vintage's updates layer needs to stay
fresh — a dormant vintage kept for [asset migration](#the-asset-migration-workflow-and-what-it-means-for-the-disks)
is booted rarely and can keep an old one, or none. The deduplication that matters is across *projects
sharing one engine*, and that is exactly what survives.

**What it carries is less than it sounds, which helps.** The engine is *not* in it: a new engine
version is a new layer-2 sibling, not an update. So an updates layer holds Windows cumulative
updates, Visual Studio, and the small things — `pacman -Syu`, `uv self update`. Note that the base
disables Windows Update (`NoAutoUpdate=1`, `wuauserv` stopped), so refreshing this layer means
re-enabling it inside that layer, updating, and turning it off again.

**Rebuilding the VMs above it is unavoidable, and worth understanding why.** A differencing child
stores only the blocks it changed, and its NTFS metadata refers to extents in the parent. Swapping the
parent for one whose contents differ is therefore not safe, whatever `Set-VHD -ParentPath
-IgnoreIdMismatch` will let you do. The children get re-forked; that is the cost.

> ### The annual rebuild is a copy and a merge, not a reinstall *(measured)*
>
> **Copy the engine layer, reparent the updates layer onto the copy, merge it down.** The result is a
> new engine layer with the updates folded in, built without running a single installer. Proved on
> throwaway 512 MB disks — `tmp/test-merge.ps1`, 16 assertions, all passing:
>
> - **`Set-VHD` took the new parent with no `-IgnoreIdMismatch`.** A byte copy preserves the VHDX
>   identity, so Hyper-V considers the copy legitimately the same parent and no safety check has to be
>   overridden. That matters: the flag exists for reparenting onto a *different* disk, which is the
>   dangerous case this scheme never needs.
> - **The chain read correctly through the new parent before merging** — the parent's files, the
>   child's own files, the child's overwrite winning, and the child's **deletion** holding, which is
>   the case a differencing disk has to record as an absence rather than a change.
> - **The merge produced a standalone disk** carrying both layers, deletion included, and consumed the
>   child.
> - **The original parent came through untouched**: its own file intact, the update absent, its version
>   of the shared file unchanged, its deleted file back, and still a plain `Dynamic` disk. That is the
>   property the whole scheme rests on, and it holds.
>
> **Scale the timings before trusting them.** 100 MB copied in 0.1 s and merged in 1.0 s, on one
> volume. A real engine layer is 100+ GB and a cross-volume copy of that was measured at
> [~11 minutes](FORGE-DISKS.md#making-the-wait-cheap-rather-than-short); merge time tracks the
> **child's** size, not the parent's, so an updates layer of a few tens of GB is minutes rather than
> seconds. Still a different order of magnitude from reinstalling Windows, Visual Studio and an
> engine.

**Only worth it with several project VMs.** With one or two, run the updates inside the project's own
layer 3 and skip the extra level entirely: the duplication you are avoiding is one or two copies of a
few tens of GB, which is cheaper than the ceremony. The layer earns its place when enough projects
share one engine that holding the same patches N times stops being free.

This is also why [numbering layers by depth rather than by contents](#layers-stack-and-only-the-top-one-is-appsandboxs)
was the right call: once updates accumulate above it, the layer that *installed* Visual Studio no
longer holds the Visual Studio that runs. A name describing contents would have quietly become false.

### The asset-migration workflow, and what it means for the disks

**Two engine versions are never needed at once** *(the tester's own process)*, which
settles the question the layering depended on. The process is strictly sequential:

1. The asset is either a full project, or an empty project is made and the asset imported into it.
2. Open it in the engine version the asset actually supports. Look around, run validation — some
   assets ship broken — and delete what is not wanted. **Close the engine.**
3. Back the project up.
4. Open the **target** engine (usually 4.27), reveal incompatible projects, pick this one, and accept
   *convert in place*, the backup being the safety net. Look around and validate again.
5. Make a *second* empty project and copy the assets into it, because an asset can appear to work
   while depending on files it wrote **outside its own directory** — it only breaks once its
   directory alone is moved. Validate that project too.
6. Only then does the asset join a library.

Two consequences for this design:

**Switching engine versions must be cheap, because the process switches constantly.** This is where
the [layer chain](#layers-stack-and-only-the-top-one-is-appsandboxs) earns its place: with one child
per engine version, changing versions is a `VhdxPath` edit and a restart — no copying, seconds
rather than the tens of minutes a disk copy costs. Without layers, each switch would mean moving
100+ GB, and the whole workflow would be unusable in a VM.

**Much of the dance is text, not GUI.** Steps 3 and 5 are file operations. Step 4's "show all, then
answer the version prompt" is driven by the `EngineAssociation` field in the `.uproject`, which is
JSON — setting it to the target engine should make the project open directly, with no dialog to
click (*unverified, and cheap to test*). Validation has a commandlet in modern versions. So the
GUI-bound part is narrower than the manual process suggests, and worth attacking at
[rung 1](#the-ladder-of-doors) before anything is automated at rung 4.

### Why a shared screen is not optional

Three facts push in the same direction, and the last one survives the other two being fixed:

1. `open_display` **crashes the daemon** for a GPU-PV VM, on 0.1.8 as much as 0.1.4.
2. AppSandbox's GUI **cannot run beside the headless daemon**, so every look at the screen costs the
   agent its API, plus a VM stop and start at each end.
3. **RDP is absent** from this guest, which is Windows Home.

Even with all three repaired, RDP would still be the wrong tool, because **RDP does not share a
screen — it opens a second one**. The console session is taken away while a human is connected and
handed back changed, and the desktop the agent was driving is not the desktop the human sees. The
requirement is the opposite of remote access: when the agent stalls half-way through an installer,
the human has to finish *that dialog*, on *that desktop*, and hand it back mid-task. That is screen
*sharing*, and VNC is what does it — it attaches to the console session rather than creating one.

So the screen server belongs in the base image beside the engine, not in a list of conveniences. The
practical consequence arrived within the hour: the flat base predated the VNC
install, so the **first boot after the VM was repointed onto it had no screen server at all**, and the
failure did not look like a missing program — `ssh -L` opens the local port whether or not anything
answers, so the tunnel reported success and the viewer simply disconnected. Re-running
`windows\install-screen-access.ps1` fixed it in a scripted minute.

Both scripts now refuse to repeat that lesson: `forge-screen.ps1` reads the guest's greeting through
the forward before opening the viewer (*measured: a live server greets in 0.50 s, a refused forward
closes at 2.01 s*), and `forge-repoint.ps1` checks the screen server after the VM boots. **Anything
installed in a guest after its base was flattened is simply not there after a restore** — the screen
server is only the first thing to notice.

### When the clipboard stops crossing, look at the host, not the VM

*(measured)*

A VM you cannot paste into is half a machine. Every password, every path, every snippet of
configuration has to be retyped by hand off a screenshot, and the agent's whole point is that a
human can step in mid-task - which is hard when nothing can be carried in. So this is worth the
space, even though the fault turned out not to be in the forge at all.

**The symptom.** Copy and paste worked perfectly *inside* the guest. Between host and guest it did
nothing, in both directions, with no error anywhere. It survived a full VM restart and a restart of
the VNC viewer.

**What was actually true**, from the host:

| | while broken | once fixed |
|---|---|---|
| `GetClipboardOwner()` | **NONE** | a live window |
| `SetClipboardData` / `GetClipboardData` (raw Win32) | worked | worked |
| `Clipboard.SetText` (WinForms/OLE) | failed | worked |
| guest's own clipboard, service, policies | healthy throughout | healthy |
| `tvnviewer` as clipboard-chain head | alive, not hung, replied to `WM_NULL` in under 2 s | same |

**The mechanism.** The host's clipboard was sitting **ownerless**. That is the signature of a process
that put data on the clipboard - typically *delayed-rendered* data, where the content is not stored
but produced on demand by sending `WM_RENDERFORMAT` to the owning window - and then exited or stopped
answering. A reader asks a window that no longer exists and gets nothing. The raw API kept working
because it never waits on the owner, which is exactly the split in the table.

**Neither obvious remedy can work, and knowing why saves the time:**

- **Restarting the VM** cannot help, because the stuck state is in the *host's* window station. The
  guest was healthy the whole time. This is the instinct to resist: the symptom appears in the VM,
  so the VM looks guilty.
- **Restarting the VNC viewer** cannot help either. The viewer is only a *listener* in the clipboard
  chain, not the owner, and restarting a listener does nothing about a dead owner. (TightVNC Viewer
  registers through the legacy `SetClipboardViewer` chain, so it does appear as the chain head -
  which makes it look like a suspect when it is a bystander.)

**The fix is one line on the HOST**, and it needs no code:

```cmd
cmd /c "type nul | clip"
```

`clip.exe` opens the clipboard, empties it, and sets its own empty content *with a live owner* -
which is precisely the sequence that cleared it. Copy something normally afterwards and it is back.

**Telling in ten seconds** whether this is what you have:

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

An owner of `0` straight after copying something is the tell. A non-zero *open* window is the other
clipboard fault - a process holding it open - and that one names its culprit, so it is the easier day.

**One measurement trap, which nearly sent this the wrong way.** PowerShell's `Set-Clipboard`, and
anything else built on WinForms, goes through the **OLE** clipboard, which requires `OleInitialize`
on an STA thread. A scripted or tool-spawned shell often has neither, so it throws *"Requested
Clipboard operation did not succeed"* **on a perfectly healthy machine**. That false negative read
exactly like the real fault and produced a confident, wrong diagnosis that the host's clipboard was
broken. Test the clipboard with raw `OpenClipboard`/`SetClipboardData`/`GetClipboardData`, or from a
real interactive session - never with `Set-Clipboard` from a script.

---

### The loopback adapter

With no adapter, Windows has no network at all, and CryptoAPI will not even attempt to fetch OCSP,
CRL or AIA data: `certutil -urlfetch -verify` fails every URL with `ERROR_NOT_CONNECTED (0x800708ca)`
and the chain ends `CRYPT_E_REVOCATION_OFFLINE`. Nothing appears in the gateway's log, because no
request is made. Clients that ignore revocation results are unaffected, which is why an earlier test of the
whole path passed; clients that insist fail, and Visual Studio's engine integration is one
of them.

A Microsoft KM-TEST Loopback Adapter fixes it. It gets a link-local address and **no default route**,
so it adds no way out, but Windows now reports a network and CryptoAPI starts fetching, through the
proxy like everything else. Measured before and after, in the same guest:

| | No adapter | With the loopback adapter |
|---|---|---|
| `INetworkListManager.IsConnected` | False | **True** (`IsConnectedToInternet` stays False) |
| `certutil -urlfetch -verify` on GitHub's certificate | `CRYPT_E_REVOCATION_OFFLINE` | **passed**, `dwErrorStatus=0` |
| `curl` to `api.github.com` through the proxy | TLS failure | **HTTP 200** |
| Direct `curl` to `1.1.1.1`, DNS for `example.com`, ping | all fail | **all still fail** |

By hand, in the guest: run `hdwwiz.exe` → *Install the hardware that I manually select* → *Network
adapters* → *Microsoft* → *Microsoft KM-TEST Loopback Adapter*. `netcfg` cannot do it any more; on
Windows 11 it installs only protocols, services and clients. Scripted, it is what `devcon` does:

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

It takes effect at once, no reboot, and survives reboots. To undo: uninstall the adapter in Device
Manager. Check afterwards that `Get-NetRoute -DestinationPrefix '0.0.0.0/0'` returns **nothing** — if
a default route ever appears, the guest has a way out that the gateway does not control.

## The backend: AppSandbox

[AppSandbox](https://github.com/jamesstringer90/appsandbox) is a headless daemon with an HTTP/JSON
API and a Python SDK, built directly on HCS/HCN (the layer WSL2 uses). For this feature, **having an
API beats every other property**, because a GUI cannot be part of a loop an agent drives:

- **The GPU is one parameter.** `gpuMode=1` does what would otherwise be registry preparation, MMIO
  sizing and injecting the host driver into the guest — and redoing it after every driver update.
  (`0` is none, `2` tries every adapter.)
- **Snapshots are an API** (see [Backup and rollback](#backup-and-rollback), and its bug).
- **Network isolation is one parameter.** `networkMode=0` means no network adapter at all (`1` is NAT,
  `2` external, `3` internal). Both it and `gpuMode` can be changed on a stopped VM.
- **No Hyper-V role.** It runs on any Windows 11 edition, Home included (*read*).
- **MIT-licensed**, like Draugr.

ExHyperV was the alternative and has been dropped: a GUI with no CLI, GPL-3.0, and built on the
Hyper-V role, which forbids checkpoints on a VM with a GPU partition. It remains the better tool for
a human at a desk. It is not an option for a loop.

> ### The cost of this choice, stated plainly
> AppSandbox is **six months old and one person's project**, now at 0.1.8. Its author treats pull
> requests as "suggestions and examples of possible solutions" that he is "unlikely to formally
> review or merge", and uses them as a reference for his own fix (*read*: the repository's PR
> template). So a bug we find is fixed on his schedule, not ours, and Draugr must work on **released**
> versions — never on a patched build nobody else has.
>
> Two things make that acceptable. `dr-forge`'s surface is *verbs* — `up`, `down`, `exec`,
> `snapshot`, `rollback` — so the backend stays swappable. And the whole feature is invisible unless
> `DRAUGR_FORGE` is set. This belonged in `docs/DESIGN.md`'s **Standing risks**, worded at least
> this strongly, and **is there now** *(written)*: the decision in its own right, with
> the backend's age and the snapshot bug as the two standing risks beneath it
> ([DESIGN.md](DESIGN.md#standing-risks)).
>
> One thing cuts the other way. AppSandbox ships **EV-Authenticode-signed binaries with
> Microsoft-attestation-signed drivers**. That does not make it mature, but it means the maturity
> risk is about API churn and bugs, not about whether anyone is home.

### Getting it: the release zip

Use the release zip, not a build from source. Three drivers ship in it — `AppSandboxVDD`, the display
driver, `AppSandboxVAD`, the audio driver, and `AppSandboxSHM`, a transport used only for Windows
guests on a Mac host — and those need Microsoft attestation, which needs an EV certificate on a
hardware token and a Partner Center Hardware account. A build without them
produces test-signed drivers that retail Windows refuses to load. The release zip also carries the
SDK (`headless-api\asb.py`) at its root.

If you ever need to patch AppSandbox itself, **rebuild only the user-mode parts and reuse the
release's signed drivers.** That is the author's own guidance — *"For regular app changes, reuse the
released drivers; don't rebuild them or install the WDK"* — and it works because `AppSandbox.exe`
and `appsandbox_core.dll` carry only a publisher signature, which Windows does not enforce for
user-mode code (*read*: `tools/sign/SIGNING.md` and the vcxproj files). The snapshot fix below is
that kind of change.

Keep a clone of the source anyway — for reading `src/` when the API surprises you, which is how the
snapshot bug was found, and for pinning the version a spike passed against. `dr-forge` never invokes
it.

---

## Network: no adapter, and egress through a gateway

**This is the headline, and it reverses what the first draft of this plan said.** That draft
described the forge as "not a mound — no default-deny egress", and planned a *maintenance mode* that
flipped the VM to NAT to install anything.

Instead the VM has **no network adapter at all** (`networkMode=0`), and reaches the internet only
through an SSH reverse tunnel into a **gateway mound** whose `sbx` policy is the allowlist. So the
forge is filtered by the same rules and the same tools as a mound: `dr-policy --denied` shows what
the VM tried to reach, and a kit says what it may. Measured end to end — the Epic Games Launcher,
Fab, a 131 MB project download, Visual Studio's self-update and Windows Update all went through it,
at full line speed, and an administrator in the guest could not get out any other way.

The allowlist this was tested with ships as `kits/unreal` in the gateway template. Two
consequences for the forge as a whole:

- **Maintenance mode mostly disappears.** Updates, downloads and installs go through the gateway.
  Whether a first ~100 GB engine install should go through it too is *unmeasured*, so bootstrapping
  a fresh base over NAT remains the known-good path.
- **The gateway is optional within an optional feature.** A forge without one has **no egress at
  all** — the most locked-down configuration there is, and enough for a pure build loop once the
  engine is installed. It is what you want to start with.

### Two mounds, two policies

**The gateway is not the agent's mound.** The agent works in the game project's mound; the gateway is
a second mound that runs no agent and only carries the VM's traffic. Merging them looks simpler, and
it would cost three things:

- **Least privilege, both ways.** Each mound's policy covers its own traffic only, and a kit's rules
  stay with the sandbox that uses it *(measured: `kits/unreal` allows `docs.unrealengine.com` on the
  gateway, while a project mound is denied it)*. Merged, the agent could reach everything the VM
  needs — Epic's account and store services, Fab purchases, CDNs — and the VM could reach everything
  the agent needs, starting with the AI endpoints.
- **Lifetimes.** The gateway must be up whenever the VM is; the agent's mound is stopped, recreated
  when its kit changes, and removed. As the gateway, each of those would cut the VM's network,
  possibly mid-build.
- **One forge, several projects.** A shared forge ([open question 1](#open-questions)) needs one
  gateway, whichever project's agent is working.

The cost is one more mound, 2 GiB of RAM, and one more
thing to keep running — which is why [`dr-up` in the project starts it](#commands).

**What the agent can read is the project mound's business, not the gateway's.** A project mound gets
only `sbx`'s defaults plus its own kits, and those do not include Epic's documentation, its forums,
Microsoft Learn or Stack Overflow *(measured: all four denied)*. So Unreal work needs two kits in the
project, neither of them the gateway's:

- **Unreal reference**, on by default for a forge project: `dev.epicgames.com`,
  `docs.unrealengine.com`, `forums.unrealengine.com`, and `learn.microsoft.com` with
  `docs.microsoft.com`, which redirects to it — Visual Studio, MSVC's compiler and linker errors, the
  Windows APIs.
- **Coding guides**, generic and in the kit library for any project: Stack Overflow and the like.

The agent reads them from its mound, not through a browser in the VM: that is faster, and it keeps the
lookups inside the boundary that has the credential scan.

> **The allowlist is per name at the rule and per address in practice.** A name that shares an IP
> with an allowed one resolves and connects, even while `sbx policy check` reports it denied
> (*measured*). This is true of every mound, not only the gateway, so the corrections are
> Draugr-wide fixes, not forge ones.

---

## The channel: how the mound reaches the forge

AppSandbox gives no VM IP. With `sshEnabled` and `sshDeployKey` set at create, the daemon generates
an ed25519 key pair and the guest agent installs the public key (*read*). The guest's `sshd` is then
reached through a **loopback port on the Windows host** — `ssh_info(name)` reports it — carried over
Hyper-V sockets, which is why `networkMode=0` and working SSH are compatible at all.

**Measured path, with no `netsh`, no WSL address and no host administrator rights:**

- On the agent's mound: `sbx policy allow network --sandbox <agent-mound> localhost:<SshPort>`.
- From inside it:
  `ssh -o ProxyCommand='socat - PROXY:gateway.docker.internal:%h:%p,proxyport=3128' -p <SshPort> <user>@host.docker.internal`

The full SSH handshake got through, and the test stopped at authentication on purpose. With a
`localhost:<port>` rule, `host.docker.internal` reaches a service bound to **Windows** `127.0.0.1`
through the mound's proxy; raw direct TCP does not.

The first draft planned `netsh interface portproxy` into WSL and then `DRAUGR_HOST_PORTS`, "with no
changes at all". Both halves were wrong: the path above needs neither, and `dr-hostport` opens WSL's
address, not Windows loopback. That finding also contradicts what `dr-hostport`, `CONFIG.md` and
`SECURITY.md` currently tell every user — that a service must listen on `0.0.0.0` — which is why it
is a Draugr-wide correction, and on this feature's critical path.

Rules that go with it:

- **SSH port only, never the AppSandbox API.**
- **Password logins off first.** The guest's `sshd` accepts passwords by default; a mound given this
  rule could otherwise try to guess the administrator's.
- **Do not write the relay port into a rule at all.** This used to say the port "has stayed
  constant across VM restarts, VM replacement and a host reboot (*measured*)". **That is no longer
  true, measured, twice in one day:** `vms.cfg` said 57351 while the guest was on 54501,
  and the API itself answered 57351 and then 57589 a few minutes later, with `sshState: 2`
  throughout. A rule naming it would be stale within the hour, and reaping stale `localhost:` rules
  is work that should not exist.

  So the port is **pinned on the host instead**: one `-L 127.0.0.1:18022:127.0.0.1:22` on the
  supervisor's ssh, which already re-reads the relay port on every reconnect. 18022 then never
  moves, the mound gets one rule — `localhost:18022` — and nothing has to be kept in sync. The
  number fits the existing scheme: 18888 proxy, 18445 SMB, 18022 ssh.

**Measured, hop by hop:**

| Hop | |
|---|---|
| WSL → mound | works; `*.sbx` is an ssh_config `ProxyCommand "sbx.exe ssh proxy %n"`, so there is **no IP** for the mound and no listener in it would be dialable |
| mound carries a connection | works: `ssh -W localhost:12345` through the mound returned the far end's answer. `socat` is present too |
| mound → Windows loopback | **closed.** 18888, 18445 and 19999 all refused from inside the mound, and no kit holds a `localhost:` rule. Raw TCP never works here — it goes through the mound's own proxy, per the `socat ... PROXY:gateway.docker.internal` line above |
| loopback 18022 → guest `sshd` | works: a test `-L` returned `SSH-2.0-OpenSSH_for_Windows_10.0` off 127.0.0.1:18022, which only the guest's sshd can have sent |
| the guest's end | `git 2.56.0`, `rsync` and `bash` are on the ssh PATH from `C:\msys64\usr\bin`, and `git -C /c/Users` answered *"not a git repository"* rather than *"cannot change to"* — so `/c/...` resolves to `C:\...` and the mound-path convention carries to the VM unchanged |

**The password rule was satisfied first, then the rule was added.** Measured: the guest's
`sshd` reported `passwordauthentication yes`, so it was turned off before the mound was given
anything — it now offers `publickey` only. Three traps on the way:

- **Appending to `sshd_config` does nothing.** Windows' default file ends with `Match Group
  administrators`, and everything after a `Match` line is conditional on it. The appended
  directives applied to administrators alone, `sshd -T` — which reports the *global* config — kept
  answering `passwordauthentication yes`, and the server went on offering it. The directives go
  **above the first `Match` block**.
- **The listener holds the config.** A new connection does not re-read it, so sshd has to be
  restarted. Restarting it from a session sshd is serving can kill the restart halfway and leave
  the guest with no sshd at all, so it is handed to a one-shot SYSTEM scheduled task instead.
- **The restart is asynchronous, and the old listener answers while it is pending.** Measured
  on the first provisioning run against a fresh VM: the file was rewritten, `sshd -T`
  agreed, the task was started — and the check that followed still read
  `publickey,password,keyboard-interactive`, because the scheduler had not picked the task up
  yet. The listener restarted seconds later and the guest was keys-only. Nothing was wrong
  except the measurement, and the same race could have *deleted* the task: the host removed it
  as soon as that single check returned. So the verification polls for the **effect**, and takes
  **positive evidence only** — mid-restart the connection is refused and nothing is offered at
  all, and "nothing offered" must never be read as "passwords are off".

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

The alias is named after the VM, because that is what `dr_sandbox_url` puts in the URL. `socat` does
the CONNECT through the mound's own proxy — raw TCP to `host.docker.internal` does not work, and
`ProxyJump` would try exactly that. A **separate key**, minted in WSL: ssh refuses one read off
`/mnt/c`, where Windows files present as world-readable, and a second credential can be revoked
without touching the Windows-side admin key.

With that in place, `git push ssh://<vm>/c/Temp/x.git` put commit `a088b64` into the guest and the
guest's own git read it back, SHA for SHA — so the mound-path convention carries and the ordinary
git loop needs no forge-specific anything.

**Neither key survives a VM start.** The daemon rewrites `administrators_authorized_keys`
when it brings a VM up and keeps only its own deploy key — measured and detailed
in the technique notes [above](#technique-notes-that-cost-hours-to-find). So the two keys
below are not installed once per guest but **re-installed on every start**, by
`vm.ps1 -Mode keys` through the deploy key, which is the one credential a just-started guest
is guaranteed to accept. `-Mode start` runs it before anything waits on the admin key, `-Mode tunnel` runs it
before it starts or prods a supervisor — a long-lived supervisor retries on its own clock and
can land in the window between a VM start and the key install, which the log shows as
`Permission denied` and `up` reports three steps later as a forward that never carried — and
`dr-layer provision` delegates its own bootstrap to the same mode. A guest can be repaired by
hand the same way, without a full provision run:

```powershell
powershell -ExecutionPolicy Bypass -File lib\forge\vm.ps1 -Mode keys -Vm forge-0
```

The consequence for layers is the useful part: **a frozen base does not need working keys in
it**, because whatever is in that file is replaced on the way up.

**A live supervisor does not see a widened `permitopen`.** The tunnel key is restricted —
`restrict,port-forwarding` plus one `permitopen` per destination — and `sshd` reads those options
at **authentication time** and holds them for the life of the session. Widening the list therefore
does nothing at all for a tunnel that is already connected. Measured on a VM built from
a layer frozen before `127.0.0.1:22` joined the list: the supervisor connected, provisioning added
the port, and the session went on refusing it for forty minutes —

```text
ssh: channel 7: open failed: administratively prohibited: open failed
```

— while the listener stayed bound and every port-based check passed. `dr-forge doctor --deep`
reported **9 of 10 links green** and blamed the mound; the answer was only in the supervisor's own
log, `%LOCALAPPDATA%\Draugr\forge-tunnel.log`. Two consequences worth keeping:

- **Restarting the guest's `sshd` does not clear it.** Windows OpenSSH serves each connection from
  its own `sshd.exe`, and `Restart-Service sshd` leaves those children running — this session
  survived three restarts with its stale options intact.
- **Ending the supervisor's `ssh` child does clear it**, and is the supervisor's own recovery path:
  the loop logs `ssh exited`, reconnects within ten seconds and re-authenticates against the file
  as it now is. `forge-vm-setup.ps1` does this itself, but only when the options actually moved and
  only for a supervisor serving the VM being provisioned.

### Control plane and data plane, split

The daemon's API is on host loopback behind a **random bearer token in a discovery file**. That token
must never enter the mound:

| | Who holds it | What it can do |
|---|---|---|
| **Control plane** | Draugr, host-side, in WSL | create, start, stop, snapshot, branch, delete VMs |
| **Data plane** | the agent, in the mound | one ssh channel to one port |

The agent can build, test and read results. It cannot create a VM, delete one, roll one back, or ask
the daemon anything — the same division Draugr already draws around `sbx`, which the agent has never
been able to run either.

### What crosses

| | |
|---|---|
| `dr-forge exec '<cmd>'` | run it in the guest, output streamed back |
| `dr-sync`, `dr-send`, `dr-merge`, `dr-status` | the git loop, unchanged, with the VM as the far end |
| `dr-data push` / `pull` | the file loop, same far end: logs, cooked artifacts, screenshots |

Draugr already runs a git loop and an rsync loop over ssh to a machine that is not this one. The forge
is another far end, not another mechanism — **the code and the data live in the VM**, so these are the
ordinary commands rather than forge-specific ones. `dr-forge` owns only what is particular to the VM:
its state, its liveness chain, its layers, and running a command inside it.

`dr-forge push` and `pull` do exist, but as the **file-level primitive** underneath that, not as the
data loop: they move one path in or out over the same ssh relay. They are what `dr-data` will sit on
once it can address the VM, and they are useful meanwhile because nothing else can move a file at
all. If you are reaching for them to carry a repository, reach for the git loop instead.

---

## How the agent works the UI

### Most of the loop needs no UI at all

| Task | Where it happens | Needs the desktop? |
|---|---|---|
| Install or update the engine, sign in | the Epic Games Launcher only | **yes** |
| Some Fab items, such as engine plugins | the Launcher | **yes** |
| Create a project | the editor's **Project Browser** — not the Launcher | **yes**, in the editor |
| Add Fab assets to a project | the editor's **Fab window**, on by default in 5.8 | **yes**, in the editor |
| Reconfigure a project | `.uproject` (JSON) and `Config/*.ini` | no — text files |
| Delete a project | it is a folder | no |
| C++: edit, build, run | source files and `UnrealBuildTool` (*measured*, above) | **no** |
| C++: debug | Visual Studio's debugger, or `cdb` headless (*unmeasured*) | usually |

So the core C++ loop — edit in the mound, push, build, run, read the logs — needs no desktop and no
Visual Studio UI. **But the work does not start there.** It starts in the Launcher, which has no
official automation, and continues in the editor's Project Browser and Fab window. **Desktop
automation is the main target**, and it is needed for the editor as much as for the Launcher.

### Putting a screen in front of a human

Not through the API: `open_display` crashes the daemon for this VM (above), and AppSandbox's GUI
takes the API away for as long as it is open. The way that works is a **VNC server inside the guest,
bound to loopback, reached over the same ssh channel** — one action on the host that brings
the daemon up, starts the VM, forwards the port, opens the viewer, and tears the forward down
afterwards. The VM stays up and the agent
keeps the API, so a human looking at the screen interrupts nothing.

**That is now `dr-forge up --screen`, and `dr-forge screen` on a forge already up** *(built)*. Draugr owns the whole sequence, so the gateway script is not needed for it: the
bring-up was already `up`'s, and the screen is the last step after the guest has a way out.

**It does not block.** Showing the screen is the last thing `up` does, so there is nothing left to
wait for — but the forward still has to come down when the viewer closes, so something must outlive
the command and watch. That is `lib/forge/screen.ps1`, started detached and hidden; `up` waits only
for the forward to answer, then returns and leaves the viewer to the human. Being detached, it has
no console, so it logs to `%LOCALAPPDATA%\Draugr\forge-screen.log`, and `up` reports a screen that
failed to open rather than announcing one that did not.

A failed screen is **not** a failed `up`: everything `up` was asked for is already running by then,
and failing the command would misdescribe the forge.

**Why there is a forward at all**, when the viewer and AppSandbox are both on this one host: the
guest has **no network adapter** (`networkMode=0`), so it has no address for anything to dial — the
same reason its egress has to be a reverse tunnel. AppSandbox's ssh relay over Hyper-V sockets is
the only channel in or out, so reaching a port inside the guest means forwarding through it. There
is no shorter path to shorten. And the one direct route the daemon does offer, `open_display`,
crashes it for a GPU-PV VM — which is why a VNC server inside the guest exists in the first place.

The forward is **temporary and on the admin key**, not added to the supervisor's permanent set: the
restricted tunnel key would need another `permitopen`, a real widening of a deliberately narrow key,
and a VNC port on host loopback would then stand open whether or not anyone was looking. This way it
lasts exactly as long as the viewer.

What `forge-screen.ps1` still does that Draugr will not is start the daemon **elevated**. Scheduling
`AppSandbox.exe --headless` at logon covers that, after which the script has no job left.

It shares the **console session**, which is the session autologin creates and the one UI Automation
drives. That is a feature rather than a compromise: the human sees exactly what the agent sees. RDP
would have been the obvious choice and is not available — this guest is Windows Home.

*Measured: `RFB 003.008` through the forward, and a screenshot from inside the guest
showing a drawn 1920×1080 desktop in session 1.*

### Session 0: why ssh alone cannot do it

Windows' `sshd` runs every session in Session 0, the non-interactive services session. The APIs
that see and drive windows — UI Automation, `EnumWindows`, `BitBlt` — are scoped to a desktop, and
Session 0 has none, so they see nothing (*read*: [Cua's
documentation](https://cua.ai/docs/how-to-guides/driver/windows-ssh) and
[Win32-OpenSSH #998](https://github.com/PowerShell/Win32-OpenSSH/issues/998)). Two consequences:

- **Anything that touches the UI runs as a helper in the user's session** — typically a Scheduled
  Task with an interactive logon — and the ssh side only relays to it.
- **The agent must not launch GUI programs over ssh.** They would start in Session 0, where nobody,
  including the agent, can see them.

Both need a logged-in, unlocked desktop, so the guest needs automatic login. AppSandbox 0.1.8 keeps
it working ("Keep Windows VM automatic login and passwords from expiring", *read*).

**The relay exists and the whole loop works** *(measured)*. From WSL, with no desktop
and no MCP client in the path:

```text
dr-forge exec draugr-shot   ->  schtasks runs the task in session 1  ->  C:\Draugr\shot.png
dr-forge pull C:\Draugr\shot.png  ->  1920x1080 PNG on the host, legible
```

Proven new rather than found: the guest's previous `shot.png` was from 4 October and the pulled file
carried the current timestamp, with the taskbar clock in the image agreeing. That is the loop an
agent actually needs — it cannot look at a screen, so a file on the host is the only way anything
visual gets verified.

**The capture half is Draugr's** *(gap found and closed)*. It was not: `draugr-shot.cmd`
and its `capture.ps1` were installed into this layer by an installer that lived **outside
Draugr**, so a forge built from a layer without it had no `draugr-shot` at
all. That was a gap rather than a boundary: the desktop camera is already listed
[above](#which-directories-exist-and-which-of-them-you-keep) among the components layer-0 carries
**unconditionally**, on the test *would a Windows VM built for something else want this?* — and it
plainly would, because an agent that cannot see the screen is the general case, not the Unreal one.
Nothing about it is engine-specific.

So it lives here now, by the same route the other four guest scripts took *(built)*:

- **Draugr ships its own copy**, `lib/forge/guest/install-shot.ps1`, beside `harden-sshd.ps1`,
  `install-tunnel-key.ps1`, `authorize-key.ps1` and `set-computer-name.ps1`. Those were all
  adopted from the gateway the same way, and the forge gained nothing from reaching into another
  project's directory for them.
- **Layer-0 provisioning runs it**, which is where an unconditional component belongs: paid for
  once in the frozen base rather than in every child's writable disk.
- **`init` installs it when the layer predates it**, which is the whole reason `init` exists — it
  applies what has to hold for *this* VM, on VMs built from layers that cannot be rebuilt.

**It is not the gateway's file verbatim, and the difference is `DRAUGR_CHANGED`.** Draugr's guest
scripts end by saying whether they changed anything, which is how `init` reports *installed* apart
from *already installed*; the gateway's copy had no such marker, because nothing there needed one.
Saying it honestly means the idempotence has to be real rather than claimed, so both generated
files are **compared before being written** and the task is registered **only when absent** — a
`Set-Content` or a `Register-ScheduledTask -Force` that rewrote identical content would make every
re-run report a change, which is how a summary starts lying. The phase is **not** optional, unlike
the churn phase: an agent that cannot photograph the screen cannot check its own work.

**It needs a `SECURITY.md` line**, folded into the conditional forge section (track C item 11). The
camera is a scheduled task with an **interactive** principal that photographs whatever is on the
guest's desktop, and `pull` carries the image to the host. That is the forge's intent, not a leak —
but a task that can see everything a logged-in user sees should be written down where the other
trust decisions are, rather than discovered in a guest.

### Desktop automation, through MCP

The mechanism: a **Windows MCP server** in the guest's user session, reached over an ssh port forward
on the agent's existing channel. Several exist; they differ in how they see the screen —
[Windows-MCP](https://github.com/CursorTouch/Windows-MCP),
[windows-mcp-server](https://github.com/deploymenttheory/windows-mcp-server) (UI Automation tree),
and Cua's driver (which solves Session 0 explicitly with a Scheduled Task and a named pipe).

**It is agent-agnostic by protocol.** Claude Code, Codex, Cursor, Gemini CLI and OpenCode all speak
MCP, so the mechanism — an ssh forward to an MCP endpoint in the guest — is the same for every agent.
What differs is only how each agent registers a server, and Draugr already has a place for per-agent
differences: `lib/agents/<agent>.sh`.

### What the tree actually sees *(measured)*

The deciding unknown was Slate, and it is now decided. The probe ran in the guest's **session 1** on
AppSandbox's virtual display with **no host viewer attached** — which answers a second question on
its own: UI Automation does not need anyone to be looking.

| application | framework | window | elements to depth 6 |
|---|---|---|---|
| Character Map | Win32 | — | named elements throughout |
| Notepad | XAML | — | named, once walked with a `TreeWalker` |
| **Visual Studio 2022** | WPF | `class='Window' name='Microsoft Visual Studio'` | **50**, incl. `Button 'Create a new project'`, `Button 'Clone a repository'`, `Button 'Continue without code'`, `Button 'Open a project or solution'` |
| **Epic Games Launcher** | Slate + CEF | `class='UnrealWindow'` | **0** |
| **Unreal Editor 5.8** | Slate | `class='UnrealWindow' name='Unreal Engine 5.8'` | **0** |

Two windows out of five are opaque, and they are Epic's two. The split is **not** native versus
web — it is *who owns the drawing*. Everything drawn with a framework Microsoft ships is
automatable by name; everything Epic draws itself is a rectangle of pixels with no tree inside it.

The Launcher also declines the other semantic door: started with `--remote-debugging-port=9222` it
opened no endpoint, on that port or 9223, and no Epic process listened anywhere — so its embedded
Chromium is not reachable by [CDP](#the-ladder-of-doors) either.

### The ladder of doors

Every task is worth attacking at the cheapest rung that works, and only the top rung needs a model
to look at pixels:

| rung | the door | cost | measured here |
|---|---|---|---|
| **1** | silent switches, CLI, config files | none | the whole C++ loop; `.uproject` and `Config/*.ini` |
| **2** | in-app scripting — Unreal Python, Remote Control, the [5.8 MCP plugin](#an-optimisation-not-the-target-unreals-own-mcp-plugin) | a setting | editor only, and it is where the work is |
| **3** | Chrome DevTools, on an embedded browser | none when it answers | **Launcher: refused** |
| **4** | the UI Automation tree — elements by name | cheap, deterministic, no model | **Win32, XAML, WPF: yes. Slate: nothing** |
| **5** | pixels and a vision model | a model call per step | not attempted — rung 4 covers what matters |

So the plan needs no vision model. What it needs is rung 4 for **installers, dialogs and Visual
Studio**, rung 2 for the editor, and a human for the Launcher — which costs nothing extra, because
signing in and installing the engine is already the one step [the credential
decision](#security) keeps in your hands.

### Discovery is expensive; repetition should not be

Finding the path through a GUI is the part worth a tree walk, a screenshot or a person. *Replaying*
it is not: once the path is known, it should be frozen into a script — an AutoHotkey file, or the
same UIA calls without the search — that runs in milliseconds with no model in the loop, keyed to
the application and version it was recorded against.

The honest caveat is that a frozen path for a **Slate** window can only be coordinates, and
coordinates break on a version bump, a DPI change or a resized window. So a replay script pins the
window size, verifies something cheap afterwards, and treats breakage as ordinary — the fallback
being to re-discover the path, not to fail the task.

### Technique notes that cost hours to find

- **`StrictHostKeyChecking=accept-new` accepts an UNKNOWN host and correctly refuses a
  CHANGED one - and a pinned port guarantees a changed one** *(measured)*.
  `127.0.0.1:18022` is pinned on purpose so the mound carries one rule instead of one per VM
  ([above](#the-pinned-port-has-a-price-a-far-end-is-not-identified-by-the-vm-being-up)), which
  means every guest that has ever been served takes its turn presenting a different host key
  at the same address. `known_hosts` keeps one entry per address, so the second guest trips:

  | dialled | result |
  |---|---|
  | `127.0.0.1:18022`, as `Test-Forward` does it | **rc=255**, `REMOTE HOST IDENTIFICATION HAS CHANGED!` |
  | `127.0.0.1:<relay>`, same guest, same key | rc=0 |
  | `127.0.0.1:18022` with `-o HostKeyAlias=draugr-forge-0` | rc=0 |

  **The forward was carrying the whole time.** `dr-forge up` waited its full 300 s and
  reported *"the forward never carried"*, while the supervisor's own log showed it connected
  at `10:03:53` and held the forwards until the VM was next stopped. The thing being checked
  was healthy; the **check** was broken, and it reported its own failure as the far end's.
  Two days were spent above this on the keys, which were a real and separate fault - a
  pinned port makes an unrelated defect and this one produce the same sentence.

  The fix is `HostKeyAlias`, which keys host-key memory by a name Draugr chooses -
  `draugr-<vm>` - instead of by a socket address. That also settles the RELAY port, whose
  number the daemon reassigns, and which `probe.ps1` had already shrugged at: *"the relay port
  moves, so a pinned key for 127.0.0.1:<port> is wrong more often than it is right"*. With an
  alias neither port needs that excuse. **The point is not to silence the warning but to make
  it mean something**: today a genuine key change at `18022` is indistinguishable from "a
  different VM is being served", so the only way past it is to stop checking - and `no` would
  have hidden this and every real one with it.
- **AppSandbox rewrites the guest's `administrators_authorized_keys` at every VM start, and
  keeps only its own deploy key** *(measured)*. Three keys were in that file -
  `appsandbox`, `draugr_admin_ed25519`, `draugr-tunnel` - and one stop/start through the
  daemon put it back to one:

  | | bytes | lines | file mtime |
  |---|---|---|---|
  | after the morning's boot | 93 | `appsandbox` | boot **+8 s** |
  | our two keys restored by hand | 292 | `appsandbox, draugr_admin_ed25519, draugr-tunnel` | admin key accepted |
  | after one stop/start | 93 | `appsandbox` | boot **+7 s** |

  So a VM that has just started trusts the daemon's key and nothing else. Three things follow,
  and the third is the one that matters for layers:

  * **`dr-forge up` could not work on a stopped VM** - which is every VM after a host reboot.
    Nothing in that path restored our keys. It hid for a month because `dr-layer provision`
    runs its keys phase on *every* invocation and repaired this each time; `up` was simply
    the first path to start a VM without a provision behind it.
  * **The tunnel was collateral, not a second fault.** `18765` and `18000` were down because
    the supervisor authenticates with the key the same rewrite removes. One cause, three
    symptoms - and chasing them separately is how an afternoon goes.
  * **Keys in a frozen layer buy nothing**, because the file is rewritten on the way up. A
    base image does not need working keys baked in, and every boot of every layer above it
    needs the same bootstrap. Uniform, at least, and much better known before a freeze.

  The fix is that the start path installs them: `vm.ps1 -Mode keys` waits for **whichever
  credential the guest accepts** and runs `guest/authorize-key.ps1` and
  `guest/install-tunnel-key.ps1` through that one - both of which already existed for this.
  It tries the admin key before the deploy key each round, because an admin key that answers
  means nothing was wiped and there is nothing to restore.

  **Waiting on the deploy key alone was wrong, and the first version did exactly that.** A VM
  made by `dr-layer new` from a frozen layer has no deploy key at all - `New-VmBlock` writes
  neither `SshDeployKey` nor `SshPubKey` - so that wait could only ever run out: **the full
  300 s on every `dr-forge up`**, before falling through to an admin key that had been working
  the whole time. Every VM built on the engine layers would have paid it. `-Mode start` calls it before waiting on the
  admin key, and `provision.ps1` delegates to it rather than keeping the second copy of
  append-plus-`icacls` it used to carry inline.
- **A wait that discards its own diagnosis misdirects whoever reads it** *(measured, same incident)*. `Wait-GuestCommand` ran `cmd /c echo DRAUGR_OK`, matched the
  output for that token and dropped everything else - so sixty refusals over five minutes
  were reported as **"the VM did not answer a command within 300 s (state: online)"**. That
  sentence describes an unresponsive guest. The guest was answering every time and saying
  `Permission denied (publickey,password,keyboard-interactive)`, and the reader went looking
  at the VM state, the disk and whether `chkdsk` was running - none of which was involved;
  `fsutil dirty query C:` said the volume was clean. The sentence it needed was in a variable
  it threw away. It now keeps the last reply and says which of *refused the key*, *did not
  accept a connection* or *said nothing at all* happened. **A timeout is a shape of failure,
  not a cause, and reporting one in place of the cause sends people to the wrong half of the
  system.**
- **In a `Stop` script, redirecting a native command's stderr makes any stderr line a
  terminating error** *(measured)*. `install-shot.ps1` asked
  `schtasks /query /tn draugr-shot /fo list 2>$null` whether the task already existed, so as
  to register it **only when absent** - and on a guest where it was absent, which is every
  first install, `schtasks` wrote *"ERROR: The system cannot find the file specified."* to
  stderr, PowerShell 5.1 wrapped that line as a `NativeCommandError`, and `Stop` made it
  terminating. **The guard that exists to detect "not there yet" could not be reached when
  the thing was not there.** Measured in the guest, task absent, `Stop` in force:

  | form | result |
  |---|---|
  | `schtasks /query /tn draugr-shot /fo list 2>$null` | **THREW** - `NativeCommandError` |
  | `Get-ScheduledTask -TaskName draugr-shot -ErrorAction SilentlyContinue` | `$null`, no error |

  The *redirection* is what does it; unredirected native stderr passes through harmlessly.
  Eight sites in `lib/forge` redirect native stderr with `Stop` in force, and
  `provision.ps1`'s three are already safe - they sit inside its own `Invoke-Native` helper,
  which saves the preference, sets `Continue`, runs the block and restores. The other five
  were not, and three further files had each met this separately and fixed it in place:
  `mount-vault.ps1`, `install-netfx3.ps1` and `install-vscode.ps1` all carry their own
  save/restore, one of them with a comment explaining the whole mechanism. **A lesson learned
  three times in three files is a rule that does not exist**, so it is one now:
  `tests/lint-native-stderr.sh`. Two of the five needed no guard at all, only the realisation
  that a cmdlet answers the question a native command was being asked.
- **`uv python install` with no version takes the newest CPython, which is the one with the
  fewest wheels** *(measured)*. `install-automation.ps1` asked for an unpinned
  interpreter, got **3.15.2**, and `uv tool install windows-mcp` then resolved
  `pyyaml==6.0.3`, found no `cp315` wheel, fell back to building it from source and stopped
  on *"Microsoft Visual C++ 14.0 or greater is required"* - in a guest whose entire point is
  that it has no compiler. PyPI the same day: PyYAML 6.0.3 ships `cp313` and `cp314` Windows
  wheels and **no `cp315`**. The script's own comments record `CPython 3.14` and
  `Python 3.14.8` measured, so this worked until the day 3.15 shipped and then
  broke with nothing changed on this side. An unpinned interpreter in a base image is **a
  build that breaks on a date somebody else chooses**, so the request is pinned to **3.14**:
  the newest with wheels, and a frozen base wants a reproducible interpreter in any case.
  The pin is one variable at the top of the script, because the next CPython will make it
  wrong in the other direction - a pin is a thing to revisit, not a thing to forget.
- **A check placed after the reboot it documents reads a guest that is going down**
  *(measured)*. `vault-access.ps1` restarts the guest - its own reason: `srv2` and
  `srvnet` hold port 445 until a restart - and seven lines further down asked that guest over
  ssh whether `EnableLinkedConnections` was set. The answer came back empty and the script
  printed **"EnableLinkedConnections is not set in this guest ('')"**, about a guest that has
  it set to `1`, put there by `install-guest-base.ps1` earlier in the same run. Running the
  identical command against the same guest while it is up returns `1`, and so does an
  `-EncodedCommand` form, so the command's shape was never at fault: the ordering was. **Read
  a fact before the restart that makes it true, and treat an unreadable answer as
  unreadable** - `''` is not `0`, and a check that cannot pass costs exactly what a check
  that cannot fail costs, in the opposite direction: this one sent a reader to fix a setting
  that was already correct.
- **Plain double quotes around a remote path lose their BACKSLASHES — but only when the
  script is launched from WSL** *(measured)*. `provision.ps1` sent
  `-File "C:\Windows\Temp\x.ps1"` over ssh and the guest received
  `C:WindowsTempx.ps1`. The same three forms, same guest, two launch contexts:

  | form | from Windows PowerShell | from WSL bash → `powershell.exe` |
  |---|---|---|
  | `-File "$remote"` | intact | `C:WindowsTempx.ps1` — **eaten** |
  | `-File \"$remote\"` | intact | intact |
  | `-File $remote` | intact | intact |

  **The launch context is why it survived adoption**: the gateway's copy was typed in a
  Windows PowerShell, where the bug does not exist, and `bin/dr-layer` runs it from bash.
  A comment in `provision.ps1` had concluded the plain quotes were safe *because the path
  has no space in it* — true about spaces, and the wrong conclusion. **Quote because the
  quoting is measured to survive, never because the value looks harmless.**
- **`powershell -File <missing>` exits 0** *(measured)*. It writes *"The argument
  '…' to the -File parameter does not exist"* to stderr and returns zero, so a path that
  never resolved is indistinguishable from a phase that worked. That is what turned the
  quoting bug above into **fourteen green rows** in a summary. Genuine codes do propagate —
  a guest script exiting 4 arrives as 4 through that same pipeline — so the gap was only
  ever this one case. `Invoke-GuestScript` now lets the guest's own `cmd` decide with
  `if exist` and gives absence code **127**, which it throws on rather than returning.
- **A Cygwin `curl` eats the braces out of `-w '%{http_code}'`** *(measured)*,
  and that killed the one check that proves the guest can reach the internet:

  | `curl.exe` | `-w '%{http_code}'` returns |
  |---|---|
  | `C:\Windows\System32\curl.exe` (Windows 8.18.0) | `500` — a real code |
  | `C:\msys64\usr\bin\curl.exe` (Cygwin 8.22.0) | `%http_code` |

  Bare `curl.exe` resolves to the Cygwin build, because `install-base-tools.ps1` puts
  `C:\msys64\usr\bin` on the machine PATH just before `System32` — a decision whose own
  comment reasons carefully about `find`, `sort`, `link` and `ssh`, and **does not mention
  `curl`**. So `preflight.ps1` was comparing the literal string `%http_code` against `000`,
  which can never match: it reported **egress OK against a proxy on port 9**, and
  `provision`'s phase 6 `exit 5` — the guard that stops an hour of downloads — was dead from
  the moment MSYS2 reached the PATH. The rule this implies for everything else in the guest:
  **if the output format matters, name the binary by absolute path.** `post-up`'s `curl.exe`
  is unaffected: it runs host-side in WSL, where MSYS2 is not on PATH, and it returned a
  real `403` in the same run.
- **A verification that cannot fail is worse than an absent one**, and two of the three above
  are that shape. `preflight.ps1` now checks that what came back *looks like* a status code
  before believing it, and reports a broken probe (**exit 3**) as distinct from no egress
  (exit 1) — because the first is this project's fault and the second is not.
- **`cmd /c echo %VAR%` over ssh comes back with a trailing `"`** *(measured)*. Windows
  OpenSSH re-quotes the command line it sends, so the remote `cmd` receives a stray quote — and
  `echo` prints its argument literally, junk included. The guest's name read back as `TEST"` and
  `init` reported a rename that had plainly worked as one that had not. Anything that **parses** its
  arguments is immune, so `cmd /c hostname` answers cleanly; so does `powershell -Command`. The
  `cmd /c echo DRAUGR_*` probes elsewhere in `lib/forge` are safe only because they **match a marker
  as a substring** rather than capture a value. Read a value back and you need the other form.
- **`return @($x)` does not survive the return** *(measured)*. PowerShell unrolls a
  single-element array on the way out of a function, so the caller gets the bare element and its
  `.Count` is **empty — not 1**. Two or more elements stay an `Object[]` and count correctly, which
  is what makes this hide: it breaks only in the one-element case, which for one baseline with one
  branch is the normal one. Callers must re-wrap: `@(Real ...)`.
- **Do not call `FindAll(TreeScope::Descendants)`** on an unknown window: on XAML Notepad it threw
  `E_UNEXPECTED` and returned nothing. Walk with `TreeWalker::ControlViewWalker` and a depth limit
  instead; the depth limit is also what stops Visual Studio's tree from taking a minute.
- **Every P/Invoke string needs `CharSet = CharSet.Unicode`.** Without it `GetWindowTextW` and
  `GetClassNameW` marshal as ANSI and every title comes back as a single character — a wrong answer
  that looks like a working probe.
- **The guest's session 1 is reached with a transient scheduled task** (`schtasks /create /it` →
  `/run` → wait → `/delete`), started from the ssh session in session 0. This is the mechanism the
  MCP server will need in any case — and `windows-mcp install` turns out to register exactly such a
  task itself, which is most of why it was chosen.
- **`powershell -Command -` executes stdin line by line**, as if typed at a prompt, so a multi-line
  `foreach (...) {` block is read as incomplete and the rest of the script is swallowed: exit code
  0, no output, nothing to read. Three scripts "succeeded" that way before it was spotted. Drive the
  guest with `-EncodedCommand` (one UTF-16LE base64 blob) or `-File`, never with piped stdin.
- **A port WSL can bind is not necessarily one Windows can reach** *(measured)*.
  Hyper-V reserves blocks of the Windows dynamic range - `netsh int ipv4 show excludedportrange
  protocol=tcp` listed about 1260 ports on this machine, in hundred-wide blocks from 49684 up -
  and nothing on Windows may bind one, so WSL2's localhost relay never publishes it. Inside WSL
  the port is perfect: the listener binds and `curl` on the same side answers. From Windows,
  `connect` fails, taking ~2.1 s to say so because Windows retries the SYN, where a published
  port answers within 40 ms of answering WSL-side. `netstat -ano` shows **no socket at all** -
  the relay never bound it, so there is nothing to find. The exclusions are invisible from
  inside WSL, so **no picker there can avoid them**: probe the port from the side that will
  dial it, and discard a port that does not answer rather than waiting on it. This cost a day
  as a flake in `tests/forge-api.bats`, where three of ten tests failed about one full-suite run
  in two and none failed when the file ran alone - the mock bound a port, answered the WSL-side
  readiness probe, and then `powershell.exe` could not reach it, which `snap.ps1` reports as
  exit 10, "nothing answers". The wrong diagnoses it invites are all plausible: the daemon
  died, the client's timeout is too short, the relay is lagging behind the bind.
- **Windows lets a second process bind a port that is already bound.** `ssh` sets `SO_REUSEADDR`, so
  a second tunnel supervisor takes the same `-L` port without an error and the two take turns
  answering. Measured with two identical supervisors holding one forward. A named mutex in the
  supervisor is the only part of the arrangement that notices — **and it does not notice across
  sessions.** Measured: the logon task runs its supervisor in session 0 and creates
  `Global\Draugr.forge.tunnel` there; a token's default DACL grants its own *logon SID*, and logon
  SIDs are per-session, so the same user opening that mutex from an interactive session is denied.
  `vm-tunnel.ps1` reads the denial as "guard unavailable" and continues — leaving two supervisors
  running, which is the one state the mutex exists to prevent. The denial is worth more than it
  looks: a mutex exists only while a handle is held, so being refused is *positive* evidence of a
  second supervisor, and it is currently the single case the guard ignores. `dr-forge` reports it
  as `tunnel_mutex=other-session`; the fix in the supervisor is an explicit DACL for the current
  user, plus catching `UnauthorizedAccessException` separately from "cannot create it at all".
- **A "stopped" server that still holds its log files stops the next one from starting.**
  `windows-mcp uninstall` printed *"Stopped the running server"* and left it running; the
  replacement's `start-server.cmd` could not open its `>>` redirects, cmd exited 1, and nothing was
  written anywhere saying so — while the stale server kept answering on the old port. Stop servers
  by process path and confirm the port is free before starting another.

### Which server, then

A tree-based server is enough for what the tree can see, and nothing gains from screenshots of a
Slate window that a coordinate script cannot do more cheaply. The requirement list shrinks to: run
in session 1, expose the UIA tree, send clicks and keys to a named window, and take a screenshot
when asked — with the editor served by its own MCP plugin beside it rather than through the desktop.

### An optimisation, not the target: Unreal's own MCP plugin

UE 5.8 ships an official **Unreal MCP** plugin (*Experimental*): an MCP server inside the editor
process, at `http://127.0.0.1:8000/mcp`, with tools for actors, lighting, materials, Slate widget
inspection and automation tests (*read*: [Epic's
documentation](https://dev.epicgames.com/documentation/unreal-engine/unreal-mcp-in-unreal-editor)).
Where it covers a task it beats clicking — no pixels, and it runs inside the editor, so it is in the
user's session by construction. It does not reach the Launcher, and it is off by default.

It has **no authentication** and Epic says it is "not safe to expose beyond the local machine". An ssh
forward reachable only through the agent's authenticated channel is the right shape for it;
publishing the port is not. Draugr's `lib/forge/tunnel.ps1` already carries host `18000` → guest `8000` for it, and
the desktop MCP server was moved to 8765 so the two never collide. A local forward costs nothing
while no editor is running, because `-L` only dials the target when something connects.

### Considered: Claude Desktop's computer use

Claude Desktop can now drive a Windows desktop. It does not fit here (*read*: [Anthropic's help
article](https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork)):

- **It controls only the machine it runs on**, from the Desktop app, with no API or MCP interface for
  another process. It would have to run *inside* the VM — a second agent, signed into your Claude
  account in the guest, that the agent in the mound cannot drive. Running the agent inside the forge
  is already [rejected](#considered-and-rejected).
- **It asks permission for each new application**, with no documented pre-approval, which needs a
  human at the screen.
- **It is beta, on Pro and Max plans only**, and Claude-only — against Draugr's agent-agnostic design.

What it offers — working from screenshots — is a capability of the *model*, not the app. A Windows MCP
server that returns screenshots gives the agent in the mound the same thing.

---

## Backup and rollback

AppSandbox's snapshot API, as documented:

| | |
|---|---|
| `snap_take(name, snapname)` | take a snapshot — **VM must be stopped** |
| `start(name, snap_index=N, branch_name="x")` | boot a *branch*: a writable disk forked from that snapshot |
| `start(name, snap_index=-2, branch_name="x")` | branch straight off the base disk |
| `snap_delete` / `snap_delete_branch` | discard a snapshot, or one branch of it |

The base disk itself cannot be deleted (*read*), which is the right default for the thing you most
want not to lose.

### It has a bug that decides the design

**Only the first snapshot captures the VM's current state.** `snapshot_take` builds every snapshot as
a differencing child of the disk recorded at the *first* snapshot, never of the disk the VM is
running on, and then switches the VM onto a fresh branch of it (*read*: `src/backend_win/snapshot.c`,
still present in 0.1.8):

```c
hr = vhdx_create_differencing(vhdx_path, tree->base_vhdx);
```

So a second snapshot silently saves the old baseline, and the VM's work since then is left behind on
a branch nobody is told about. The work is not deleted — selecting that branch again brings it back —
but the snapshot does not contain it.

The fix is not a one-liner. Making a snapshot a child of the *current* disk turns that disk into a
parent, which must never be written again — yet AppSandbox would still list it as a branch you can
boot, and booting it would corrupt every later snapshot. How to prevent that is a data-model decision
for the author. It is reported upstream as
[#152](https://github.com/jamesstringer90/appsandbox/issues/152), with a tested fix offered as a
suggestion, [#199](https://github.com/jamesstringer90/appsandbox/pull/199), which is the form the
author asks for. The fix freezes the branch the VM is on as the new snapshot, and continues on a
fresh branch of it.

**Until a release fixes it, `dr-forge` uses a single baseline.** The first snapshot is correct, so:

- `dr-forge base` takes the baseline **once**, and refuses to take a second one;
- `dr-forge rollback` discards the working branch and starts a new one from that baseline;
- moving the baseline forward waits on upstream.

If even the first snapshot turns out not to work with the GPU attached, the
fallback is stopping the VM and copying its disk file: minutes rather than seconds, done behind
AppSandbox's back, and *unmeasured*.

> **Never take a snapshot of a VM holding work you have not saved elsewhere** until the fix ships.
> This bug has already stranded real work on this machine.

### Two properties of rollback, whatever the implementation

- **Rollback is whole-machine, so it discards the derived data cache too**, and whatever is in the
  baseline is what you get back. An earlier version of this section said the baseline should
  therefore be taken **after a warm build** — stated as advice, on no measurement. It is demoted
  here to an open question, because the saving depends entirely on how much of the
  cache a rollback would have invalidated anyway: a warm DDC inside the baseline helps only to the
  extent that the work being discarded did not already make it stale. Nobody has measured that, and
  the first baseline on this machine was taken cold without anything obviously worse for it. Take it
  when it is convenient; if someone later measures the difference, that number belongs here.
- **Snapshots need the VM stopped**, so `base` and `rollback` both imply a stop, and both say so
  before doing it.

### The call sequence was read, not guessed *(built)*

The gate on this item was whether to wait for the upstream fix (then #153, now
[#199](https://github.com/jamesstringer90/appsandbox/pull/199)). The answer is **no**: it was still
open and unanswered, and the single-baseline design above needs nothing from it. Waiting would have
left the forge with no undo at all for a month and counting.

The four calls came out of the client and the worked example AppSandbox ships at
`C:\AppSandbox\headless-api\` — `asb.py` and `examples\full_lifecycle.py` — rather than out of the
shape of their neighbours, which is the habit that cost a failed `dr-forge rm` and a 405 the day
before:

| | |
|---|---|
| `GET /vms/<n>/snapshots` | `{snapshots:[{index,name,branchCount,branches}], baseBranches, current:{snapIndex,branchIndex}}` |
| `POST /vms/<n>/snapshots` `{"name":…}` | take one — the VM must be **stopped**, else `409` |
| `POST /vms/<n>/start` `{"snapIndex":i,"branchName":n}` | the **only** way to make a branch |
| `DELETE /vms/<n>/snapshots/<i>/branches/<b>` | drop one branch — the VM must be stopped |

**Two of those decide the design, and neither was a choice made here.** A branch is created by
*booting* from a snapshot, so `rollback` cannot leave the VM stopped — it ends up running. And a
branch is deletable only while the VM is stopped, so the old branch has to go **before** the new one
is started; `full_lifecycle.py` does exactly that, shutting the VM down and then dropping the branch
it had just been running on, which is also the proof that the *current* branch is a legal thing to
delete. If the delete lands and the start then fails, the baseline is untouched and re-running makes
the fresh branch, so discarding first is safe as well as forced.

**`base` may not pull the plug; `rollback` may.** Both stop the VM, because a snapshot needs it
stopped. But a baseline taken from a guest whose power was cut is a crash-consistent image of the one
disk you least want to be guessing about, so `base` gives up and says so rather than force one. What
`rollback` force-stops is the working branch it is about to delete, where nothing is lost that was
not already being discarded.

**The baseline itself is never deleted.** `snap_delete(name, -2)` is refused upstream, because
deleting the base disk *is* deleting the VM — and deleting a VM is `dr-forge rm`'s job, guard and
all. So only branches are dropped here, and a test asserts that every `DELETE` in `lib/forge/snap.ps1`
goes to a `/branches/` path.

**Verified against the live daemon** *(on `test` while it was still empty)*. A marker
file was written **after** the baseline was taken, so it existed only on the working branch, and the
check distinguished *gone* from *unreachable* — `Test-Path` answering `False` is positive evidence
that the guest ran a command and the file was absent, where a failed `exec` would have proved
nothing. The result:

| | |
|---|---|
| graceful shutdown | accepted, stopped inside the grace period |
| `base` twice | second run refused, exit 1, before stopping anything |
| `Default Branch` | an ordinary branch — it deleted cleanly |
| the new branch | `work-20261021-2139`, booted from snapshot 0 |
| the marker | `Test-Path` → `False`: discarded with the branch |

Two incidental findings. **Branch indices are recycled** — the fresh branch took index 0, the one
just deleted — so an index is not a stable handle and only `current` should be trusted to say where
the VM is. And **the snapshot does switch the VM onto a fresh branch of itself**, as the bug
description says, so after `base` the VM is already on a working branch rather than on the baseline:
that is the state `rollback` was written for, and it is now confirmed rather than assumed.

The two bugs the live run found were both in *reporting* rather than in action — the rename worked
and was misreported, the baseline was taken and miscounted. Both are in
[technique notes](#technique-notes-that-cost-hours-to-find).

---

## Security

The README's safety model says exactly four host paths cross the boundary and one of them is
writable. The forge adds something that is not a path at all: **a general-purpose Windows machine
with a GPU and a shell on it.**

**What got better, because of the gateway:**

- **The forge has default-deny egress.** No adapter, no route, no DNS; everything leaves through the
  gateway's `sbx` policy, and an administrator in the guest cannot get out another way (*measured*).
  The first draft's worst case — a VM bridged to your LAN — is not something to remember not to do;
  it is a `0` you have to not change.
- **The control/data split.** The agent holds one ssh key to one port. It does not hold the daemon's
  bearer token.

**What remains true and needs saying anyway:**

- **The forge is still not a mound.** No read-only source mount, no credential scan, and whatever
  the agent does there, it does as a Windows user who is probably an administrator in the guest.
- **The Epic account is the agent's to use.** The agent drives a signed-in Launcher, so its session
  token is in the guest where the agent can read it, and Fab sells paid assets. The gateway allows
  `**.fab.com` and `**.epicgames.com`, so the allowlist will not stop a purchase. **Sign the forge
  into an Epic account with no saved payment method** — ideally one used for nothing else, at the cost
  of that account's Fab library being its own. `dr-scan` cannot see inside a VM.
- **Password logins must be off** before the mound is given its `localhost:<SshPort>` rule.
- **GPU-PV widens the *host's* attack surface.** A paravirtualised GPU is a path from guest code into
  the host's GPU driver — a real kernel driver on your machine, and your display driver.
- **Rollback is the mitigation that actually works** — and today it is one baseline, not a history.

**That section now exists** *(written)*: [SECURITY.md](SECURITY.md#the-forge-if-you-turn-it-on),
"The forge, if you turn it on", conditional on `DRAUGR_FORGE` being set at all. It carries the
sentence this plan drafted for it — *if you enable the forge, the mound still cannot reach your
machine; it can now reach a machine you own, over one port, with no network of its own except
through the same policy that governs the mound* — plus the four warnings a reader needs **before**
deciding: the Epic account's spending power, GPU-PV widening the host's attack surface, the desktop
camera, and `DRAUGR_FORGE_NOSCAN=*` disabling Defender outright on a path nobody has exercised. The
forge's own refusals went into that page's refusals table beside the rest.

---

### The two passwords, and why they are not one

There are exactly two, both asked for once at the start of a provisioning run with a generated
default, and both kept in files beside the ssh keys — never in the repository, never in anyone's
head.

| | Where it comes from | Where it lives |
|---|---|---|
| Windows account | `create()`'s `adminUser`/`adminPass`; the unattend makes the account | `~/.ssh/draugr_forge.pass` on the host |
| VNC | generated 8 characters, pushed in with the MSI, then the guest copy is deleted | `~/.ssh/draugr_vnc.pass` on the host |

**The agent needs neither.** It authenticates with an ssh key, and that session lands elevated
with a full token (*measured: writes System32, reads HKLM, controls services, never prompted*). The
guest user name it needs for the connection comes free from `ssh_info()`. The Windows password is
used in exactly one place in the whole codebase - `adminPass` at create time - and never again; it
exists for a **human**, for the case where autologon breaks or the desktop locks and ssh is not a
login prompt. Note that it is not a boundary against the agent either way, since it is cleartext in
the guest registry and the agent is elevated in there.

Sharing one secret between them looks tidy and is a bad trade:

- **VNC's auth key is eight bytes.** TightVNC truncates anything longer silently, so a shared
  password would really be *the first eight characters of* the Windows password — not shared, just
  confusingly related, and capping the Windows account at eight characters if you matched them by
  hand.
- **TightVNC's stored password is reversible.** It sits in `HKLM\SOFTWARE\TightVNC\Server` as 8
  bytes of DES under the fixed, published VNC key — *measured in the guest: an 8-byte
  `Byte[]`, readable by Administrators and SYSTEM*. That is plaintext with extra steps.
- **The agent is elevated.** ssh into the guest lands with a full token, so the agent can read that
  value whenever it wants. A shared secret hands it the Windows account as well.

The Windows password is independently recoverable inside the guest anyway — AppSandbox's autologon
writes it to `Winlogon\DefaultPassword` as a **cleartext string** (*measured: type `String`*) — which
is the reason the forge assumes the guest keeps no secrets, and the reason sharing buys nothing.
Neither password is ever typed from memory, so one password is no more convenient than two.

## Config surface

New keys, following the standing rule that Draugr configures the boundary and never the inside:

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

**Two keys are read by code today**, `DRAUGR_FORGE` and `DRAUGR_FORGE_NOSCAN`. The rest are the
planned surface, and each earns its `docs/CONFIG.md` section and `share/config.example` line as it
is built, or `tests/docs.bats` goes red — which is why none of them is there yet.

**There is deliberately no `DRAUGR_FORGE_GATEWAY`.** An earlier draft of this section had one;
`DRAUGR_REQUIRES` replaced it *(decided)*. The gateway is the required repository whose
mound publishes `127.0.0.1:18888`, which is a declared fact readable while everything is down — so
a second key naming the same repository could only ever disagree with the first. See **Commands**,
below.

No `DRAUGR_FORGE_USER` or `DRAUGR_FORGE_PORT` either: `ssh_info()` reports both.

**Deliberately not keys: `gpuMode`, `networkMode`, `ramMb`, `hddGb`.** They describe the inside of the
VM, which is AppSandbox's business in the way the inside of a mound is a kit's. Draugr reports them
in `dr-forge status` and sets none of them. If bootstrapping a base over NAT is ever scripted, it
becomes a verb (`dr-forge maintenance`), not a key, so that opening the forge to a network is always
something you did, never something a file did.

House rule 7 — *"nothing is written outside the repo, `~/.config/draugr`, and `$DRAUGR_MEM_STORE`"*
— holds unamended: Draugr calls a daemon that owns its own storage, exactly as it calls `sbx`.

---

## Commands

`dr-forge` is a dispatcher over a family, the shape `dr-data` and `dr-mem` already use:

| | |
|---|---|
| `dr-forge` | status: VM state, ssh reachability, `gpuMode`, `networkMode`, current branch, the gateway |
| `dr-forge init` | make a registered VM usable: its name, keys-only `sshd`, the tunnel key, the vault and the screen server. Idempotent |
| `dr-forge up` | in order: the gateway's `dr-up`, the VM, the tunnel, then a check from inside the guest |
| `dr-forge up --screen` | the same, and the guest's desktop on screen at the end. Does not block |
| `dr-forge screen` | just the desktop, on a forge already up |
| `dr-forge down` | `shutdown`, then `stop` after a timeout — literally those two daemon calls |
| `dr-forge rm` | delete the VM, refusing when its disk sits in a folder you are keeping |
| `dr-forge exec <cmd>` | run in the guest, streamed |
| the ordinary git and data commands | the git loop and the file loop, host ↔ forge. `dr-forge` adds no verbs of its own for these: the clone lives in the VM |
| `dr-forge base` | stop, take the baseline — **once**, while the snapshot bug stands |
| `dr-forge rollback` | discard the working branch, re-branch from the baseline. Stops the VM and leaves it **running**: a branch is created by booting one. Refuses without confirmation |
| `dr-forge doctor` | every link, each naming its own fix |
| `dr-forge gateway <dir>` | write the gateway mound into `<dir>` from Draugr's template, and start nothing |

**One `dr-up` in the project starts everything, if needed.** That is the requirement: go to the game
project, run `dr-up`, and the gateway, the VM and the tunnel come up first if they are not already
running, in that order, before the agent's mound. It makes the mounds depend on each other at run
time — something Draugr has never had, since every mound so far stood alone — so it is planned on its
own: [run-state dependencies](#run-state-dependencies-planned-separately).

**Everything after the daemon is Draugr's, and so is every file it needs** *(built,
corrected)*. The AppSandbox daemon is the one step `up` cannot take, because starting it
needs elevation — so `up` reports that and hands over `AppSandbox.exe --headless`, which is worth
scheduling at logon. The mound, the VM and the tunnel are then Draugr's work, and the code for them
ships here.

The first version got that wrong in two places, and both were the same mistake. It told the reader to
run `forge-screen.ps1` when the daemon was down, and it started the tunnel by reading
a supervisor script **from outside this repository** — a file Draugr does not ship. So
`dr-forge` depended on another directory's layout: a checkout elsewhere, or renamed, broke `up`
with a message about someone else's files. The supervisor now lives at
**`lib/forge/tunnel.ps1`**, beside the `vm.ps1` that starts it, and nothing is passed in.

Its mutex, claim file and log keep the paths the gateway's copy used — `Global\Draugr.forge.tunnel`
and `%LOCALAPPDATA%\Draugr\forge-tunnel.{log,claim}`. That is deliberate: `probe.ps1` and `vm.ps1`
read that claim to work out who holds the forward, and a supervisor still running from the old copy
has to be visible to the new one. Renaming any of them would make the two generations invisible to
each other, which is exactly the two-supervisor state the guard exists to prevent. Measured:
Draugr's supervisor started while a logon-task one for another VM held the mutex, read
its claim, and carried on rather than standing down — leaving the guest a way out, as intended.

**A supervisor is not the same thing as a bound port, and reading only the port hid one**
*(found)*. `Get-ForwardOwner` began with
`Get-NetTCPConnection -LocalPort 18022 -State Listen` and returned `$null` when nothing held it,
so the claim file was consulted *only when a port holder already existed*. A supervisor that has
claimed a VM but is **between reconnects** — its `ssh` exited, the next attempt is up to ten
seconds away — holds no port and was therefore invisible. `vm.ps1 -Mode tunnel` then started a
second supervisor, which read the claim, saw the incumbent, and dutifully exited; the stalled
incumbent recovered on its own clock, and `up` reported *"the forward never carried"*.

The claim file answers this without a port, and `tunnel.ps1` already writes it in the right
order: `Write-Claim` runs **after** the stand-down decision, so a supervisor that exits never
overwrites it, and `Read-Claim` rejects a recycled pid by checking the process is a PowerShell.
So the three states are distinguishable and are now distinguished:

| forward | live claim | what it means | what `-Mode tunnel` does |
|---|---|---|---|
| carries | — | healthy | nothing — early exit |
| bound, dead | this VM | stale `permitopen`, or a far end that went away | end the `ssh` child; its loop reconnects |
| **none** | **this VM** | **between reconnects** | **wait for the incumbent — do not start a second** |
| none | another VM | that supervisor can never serve this one | refuse, naming its pid |
| none | none | nothing is serving this VM | start a supervisor |

**It waits rather than killing.** A stuck incumbent cannot be prodded the way a bound-but-dead
one can — there is no `ssh` child to end — so the choice is to wait or to kill the supervisor
itself. Killing is refused for the reason the neighbouring refusal already gives: whatever
started it, a logon task or a by-hand run, is not something this script can know, and a
session-0 one may not even be killable without elevation. So it waits, and if the incumbent
still is not carrying it says so **and names the pid**, which is actionable in a way that
"the forward never carried" was not.

`probe.ps1` had the same gate and so `dr-forge doctor` could not report this state either. It
now emits `sup_pid` and `sup_vm` from the claim regardless of who holds the port, and `doctor`'s
"nothing is holding the tunnel forwards" branch says when a supervisor for this VM is alive and
merely between attempts — which is a wait, not a break.

It also stopped parsing `vms.cfg` for the relay port and asks the daemon's `sshInfo` instead. That
file is undocumented and was measured wrong — it said `57351` while the guest was on `54501` — and
asking the API also makes the daemon's absence visible, so a supervisor started before AppSandbox
waits for it rather than dialling a port nobody is serving.

**The mound comes up through `DRAUGR_REQUIRES`, and the forge adds no key of its own.** That key
already means "this repo needs that one's mound running", and `bin/dr-dep`'s own header calls the
forge's gateway *the case it was written for*. `up` does not have to work out **which** required
repository is the gateway: `dr-dep up` brings up all of them. So the only question left is whether
the gateway is *this* repository, answered from its own `DRAUGR_PORTS` — the gateway is the mound
publishing `127.0.0.1:18888`, which is a declared fact readable while everything is down, which is
when it has to be read. Going through `dr-dep` also inherits the whole protocol rather than a copy:
trust before anything is sourced, the claim written before anything starts, a clean environment so
each dependency's own config decides what it is, the cycle guard, and the warden that stops `sbx`
auto-stopping an idle mound after 30 s.

`up` then **claims** `vm:<name>`, and `down` refuses to pull the VM out from under another project
holding a valid claim without being asked twice.

### The pinned port has a price: a far end is not identified by the VM being up

*(measured)* Pinning `18022` is what lets the mound carry one rule instead of one per VM.
The price is that **every** VM's alias resolves to the same place. `ssh -G` on two of them:

```text
test          hostname host.docker.internal  port 18022
ue-427-test   hostname host.docker.internal  port 18022
```

Byte-identical. The VM's name lives only in the `Host` line used for the lookup and is dropped at
the first hop, so what answers is whichever VM the **supervisor** serves.

That produced a false pass in `dr-forge doctor`: a run for a *stopped* `ue-427-test` reported
`ok 10 WSL reaches the VM — a command ran over the alias`, because the command ran in `test`. Link 10
is the only effect check on that direction, so a pass there was certifying the wrong guest. It now
declines to measure when the VM is not running or the forward serves another VM.

The same confusion on the **data** path is worse than a misleading report: `dr-sync`, `dr-send`,
`dr-merge` and `dr-data` all reach the VM through that alias, so a push aimed at one VM would land in
the other. `dr_forge_far_end_running` — the forge branch of `dr_sandbox_exists` — therefore requires
the supervisor's pin to name **this** VM, not merely that the VM is running.

**An unreadable pin refuses**, and that differs from link 7 on purpose. Link 7 treats unknown as a
pass so that a session-0 supervisor it cannot inspect does not nag about a forge that is fine. The
gate governs *writing files into a VM*, where guessing wrong does not undo, so it wants the pin
stated rather than assumed.

### Naming the phases you want: `provision --only` *(designed)*

A layer above layer-0 is finished by the same two phases that finish a base: `cleanup`, which
empties the temp trees a build leaves behind, and `manifest`, which records what ended up in the
disk. Everything else `provision` does — Windows, the toolchain, the components — is already in
the parent and must not run again.

**Twelve `--skip-` flags is not an interface, it is a transcription.** That is what naming those
two costs today, and the cost is not the typing: the list is a *copy of the phase table*, held in
somebody else's repository, and the day a fifteenth phase is added every copy of it silently starts
running that phase on a finished layer. A flag list that must be updated elsewhere whenever this
repository changes is a drift the type system cannot see.

**So `--only <phase>[,<phase>...]` says it the other way round**, and the asymmetry is the whole
point: `--skip` names what you do not want, which is open-ended, while `--only` names what you do,
which is short and stable. `dr-layer provision layer-2-ue412 --only cleanup,manifest`.

**It is sugar over `--skip`, computed from the phase list rather than from a second table.** Every
phase not named becomes a skip, so `provision.ps1` gains nothing, learns nothing, and cannot
disagree with the front end — and a phase added to `_DR_LAYER_PHASES` tomorrow is skipped by every
existing `--only` without anyone editing anything. The inversion is the feature; a hand-written map
from `--only` to `-Skip*` arguments would be the same drift with a different owner.

**`--only` and `--skip-` together are refused**, for the reason `--skip-netfx` is refused: two
switches for one decision can disagree, and a run that honoured both would be obeying neither. The
same refusal catches a phase name that is not one, naming the alternatives rather than ignoring the
word — which is why the spellings are matched against the list instead of enumerated as flags.

**`netfx` is not an `--only` name**, because it is not on by default: `--netfx <path>` is what turns
that phase on, so asking for it here would be a second switch for a decision one flag already makes.
It is refused with that sentence rather than silently accepted and ignored.

**Who needs it.** Draugr builds layer-0 and stops; what sits above is the project's
([where the line falls](#where-the-line-falls-draugr-owns-the-mechanism-you-own-the-contents)). But every project that builds a layer above
one needs the same two phases at the end of it, and has no business re-implementing either — so
this is the seam where a project hands a finished guest back for tidying, and the reason it belongs
here rather than in whichever repository asked for it first.

### Taking the daemon down is a command, not a recipe *(built)*

`dr-layer adopt`, `freeze`, `thaw`, `drop` and `new` all rewrite `vms.cfg`, so they refuse
while AppSandbox is up — and the daemon has no window, so *"close it"* is not an instruction
anyone can follow. `layer.ps1` therefore printed six lines to paste into an elevated
PowerShell: read `host.json`, build an auth header, shut down each running VM, wait, shut down
the daemon, and a seventh to bring it back. Asked to be made one thing to run.

**Only one of those steps needs elevation, and it is not the one the instructions said.** The
headless API's own README is explicit that the gate is on *running* the daemon — HCS and the
`http.sys` bind both require it — and not on calling it; an authenticated request carries the
bearer token and nothing else. Measured the same day: `POST /vms/<n>/stop` succeeds from an
ordinary shell. So the VM shutdowns and the daemon shutdown need no elevation at all, and
**only `--headless` relaunch does**, which `Start-Process -Verb RunAs` raises one prompt for.
Telling people to open an elevated PowerShell for the whole recipe taught them to elevate for
work that never needed it.

`lib/forge/daemon.ps1` is that one thing, reached as `dr-forge daemon <verb>`:

| verb | what it does | elevation |
|---|---|---|
| `status` | daemon up or down, its version, and which VMs are running | none |
| `stop` | each running VM gracefully, waited for, then the daemon | none |
| `start` | `AppSandbox.exe --headless` | one UAC prompt |
| `restart` | `stop` then `start` | one UAC prompt |

**The VMs go down gracefully and are waited for**, in that order, because `POST /shutdown` is
refused with **409** while any VM runs unless `{"force":true}` — which *terminates* the guests.
A terminated guest is a dirty disk, and these commands exist to freeze disks, so force is not
offered. **The exe's path is asked of the running process** rather than guessed from a list of
likely directories, with the default install as the only fallback; `status` records it while
the daemon is up so `start` can still find it once there is no process left to ask.

**AND THE SAME PIN CONFUSES `known_hosts`** *(measured)*. One address presented by
many guests over time is exactly what ssh's host-key memory is built to complain about, so the
second guest to be served through `18022` is refused with `REMOTE HOST IDENTIFICATION HAS
CHANGED` — and every Draugr check that dials through the forward then reports the *far end* as
dead. Every ssh and scp Draugr makes to a guest therefore passes
`-o HostKeyAlias=draugr-<vm>`, so the key is remembered against the VM rather than against a
port that both moves and is shared. The technique note
[above](#technique-notes-that-cost-hours-to-find) has the measurement and why `no` is the
wrong answer.

**None of this applies to a mound**, and the reason is structural rather than a matter of care: a
mound's route is `sbx ssh proxy %n`, so the name travels to the resolver, and `dr_sandbox_state`
matches on name as well. Both sides name the same thing, so "it exists" and "that is what I will
reach" cannot disagree. Only the forge drops the name, and only the forge needs the extra check.

**`up` and `doctor` exist mostly because of the gateway.** Its liveness chain is long — AppSandbox →
VM → tunnel supervisor → keeper → tinyproxy → gateway — and bringing it back after a reboot is four
ordered steps across two operating systems. That is exactly the kind of recipe `dr-plugin` replaced,
and `doctor` checking each link is the chain's best defence.

**Every link must be checked by its effect, not by its existence** *(learned)*. The
tunnel is the link that makes this concrete: a supervisor process running is not the same as a
forward working, and a forward being open on the host is not the same as anything answering inside
the guest. The same mistake was made one layer up on the same day — `forge-screen.ps1` reported a
healthy tunnel because `ssh -L` had opened the local port, while the guest end led nowhere. So
`doctor` checks link 4 by asking the **guest** whether `127.0.0.1:3128` answers, not by looking for
an `ssh.exe` on the host; that is also what makes link 5, the guest preflight, worth keeping as a
separate check rather than folding it in.

The failure this prevents is the expensive one: every link was healthy except the
tunnel supervisor, which a host reboot had quietly removed, and the symptom surfaced three links
away as *Unreal Engine reporting no internet connection*. Nothing in the VM looked wrong, because
nothing in the VM was wrong.

House rule 5 generalises: **AppSandbox stays visible.** Every error names the API call that failed, so
the problem is reproducible without Draugr.

### `down` asks the daemon, not the guest *(corrected)*

`down` used to run `shutdown /s /t 0` inside the guest over ssh and leave `vm.ps1` to wait it
out, on the stated reasoning that *stopping a VM through the daemon is pulling its plug*. That was
half right. `POST /vms/<name>/stop` is indeed the plug — the API README calls it "force power-off
(pull the plug)" — but `POST /vms/<name>/shutdown` beside it is a **graceful ACPI power-off**, with
a documented `stopping` state for the interval. The premise was not wrong about `/stop`; it was
wrong that `/stop` was all there was.

So the ssh step is gone and `vm.ps1` asks for the graceful call itself. Two things improve rather
than one: the mode stops depending on a caller having fired something first — a coupling its own
comment had to explain — and ACPI is a *hardware* event, so it reaches a guest whose `sshd` has
stopped answering, which is precisely the guest you most want to shut down cleanly.

The wider lesson is the one [`dr-forge rm`'s 405](#making-a-forge-usable-and-unmaking-it-init-and-rm)
taught on the same day: this API ships its own README and reference client at
`C:\AppSandbox\headless-api\`, and reasoning about what it probably offers is more expensive than
reading them.

### Making a forge usable, and unmaking it: `init` and `rm`

*(planned, not built)* `forge-layer.ps1 new` registers a VM on a frozen parent and stops
there: the VM boots, but three things it needs live in its **own** writable disk rather than in the
layer underneath — its computer name, its `sshd`'s password setting, and its authorised keys. Today
a gateway script supplies them, which makes a working data path depend on another project's
directory layout. That is the same mistake [corrected
above](#the-pinned-port-has-a-price-a-far-end-is-not-identified-by-the-vm-being-up) for the tunnel.

**`dr-forge init` is one verb because none of its steps is ever wanted alone.** A VM with keys but
no name is the trap, where every VM called itself `layer-0`; a VM with a name but no
alias cannot be addressed at all; a VM with both but no screen server breaks `dr-forge screen`. It
is idempotent and re-runnable, reports one line per phase, and needs the daemon **up** and ordinary
privileges.

**Built, as far as *reachable and correctly identified*.** `lib/forge/init.ps1` carries
the phases that make a fresh VM answer to Draugr — keys-only `sshd` confirmed by effect, the tunnel
key's `permitopen` with the supervisor nudged when it moves, the WSL key authorised, and the
computer name last because it is the only change owing a reboot — over Draugr's own copies of four
guest scripts in `lib/forge/guest/`. The `-WslPubKey` argument is a **path**, never the key's text:
a public key contains spaces, and an unquoted argument carrying one already cost this codebase a
silent failure in `vm.ps1`. `dr_path_win_kit` spells a WSL-native file as
`\\wsl.localhost\<distro>\...`, so the Windows side reads it in place.

**It also stops the guest writing into the child for no return** *(built)*, and what
belongs in that list was decided by measurement rather than by reasoning — the first draft of this
phase went after the wrong two things.

*Measured inside `ue-427-test`:* a **2 MB** differencing block means a 4 KB change to a
file living in the parent costs 2 MB, so scattered small writes are amplified enormously. Its child
was 31.0 GiB over a 21.6 GiB parent while everything written since the VM was created came to only
**6.63 GiB across 3,907 files** — the gap was amplification, not any one file. In the same run,
`hiberfil.sys` was **absent** (an AppSandbox guest never creates one) and `pagefile.sys` was
**512 MB with a peak usage of 71 MB**. Both files the phase was originally written for were
non-problems.

So it targets what writes **often and in scattered places**:

| | |
|---|---|
| **Scheduled defrag** | disabled. The worst thing that can run on a differencing disk: it rewrites swathes of the volume for a contiguity the guest cannot influence, since the real layout is the host's VHDX chain |
| **SysMain** | stopped and disabled. Continuous small scattered writes to predict launches a build VM does not make |
| **System Restore** | off, and existing shadow copies deleted. Block-level churn, and a rollback mechanism inside a VM that already has [one](#backup-and-rollback) |
| **Hibernation** | off. Kept as insurance although `hiberfil.sys` was absent: one registry read against 40–75% of RAM if a guest ever did create one |
| **Pagefile** | pinned to 512–8192 MB. The floor is what Windows itself chose, so it adds nothing; the ceiling is the part that earns its place. WMI needs both numbers, which is the only reason a floor is named |

`--no-tune` declines the lot. None of these needs a reboot except the pagefile, so `init` advises a
restart only for that.
They are on by default and that is a deliberate exception to *Draugr configures the boundary and
never the inside*: neither is anything Draugr needs in order to work, but both are a direct cost of
**Draugr's own** layer mechanism, so the thing paying for them is the thing that should fix them.
Only the pagefile change owes a reboot — hibernation takes effect immediately — so the guest script
reports the two separately and `init` advises a restart only for what actually needs one.

**Defender is not disabled, and the paths are yours.** Real-time protection reads every file a
build writes and reads back, which is the pattern a 2 MB block punishes hardest — but `init` is
generic and cannot know which trees are regenerable output and which hold something worth scanning.
So `DRAUGR_FORGE_NOSCAN` carries the paths and Draugr carries the mechanism; empty leaves Defender
untouched. It only ever **adds** an exclusion: removing one somebody made by hand, because a config
file no longer lists it, is not a decision a setup script should take.

A lone **`*`** in that list disables Defender outright instead — the list doubles as the switch,
because one key with a sentinel is less to keep in step than two keys that can disagree, and `*`
cannot be a path. It is checked **by effect**: Tamper Protection is on by default on Windows 11 and
refuses the change while the cmdlet returns quietly, so reporting success on the call returning
would be precisely the false green this family of scripts keeps being bitten by. See
[`DRAUGR_FORGE_NOSCAN`](CONFIG.md#draugr_forge_noscan) for when that is defensible. *(decided)*

**Considered and not done: reserved storage**, which Windows 11 enables and which the published VDI
lists suggest disabling. *Measured* with `fsutil storagereserve query C:` inside the
guest: the reserves **guarantee** about 6.9 GB but have **291 MB actually used** — it is an
allowance subtracted from the free space Windows *reports*, not blocks written to the disk. Since
the cost this phase exists to control is blocks written into a differencing child, disabling it
would reclaim essentially nothing on the host, and the guest had 467 GB free besides. So: we can,
and we should not.

**Considered and refused: the shell, Themes and the UWP stack**, which the VDI lists strip freely
because they assume a human on RDP who wants responsiveness. Two reasons not to. The narrow one is
that session 1 with a working desktop is the agent's main door — UI Automation drives it, and the
measurement that picked the automation server found that *Microsoft frameworks expose everything
while Slate exposes nothing*, so the Microsoft UI stack is load-bearing here. The broader one
matters more: **this is a public tool, and we do not know what someone else wants their forge to
do.** An optimisation that breaks a use case we never imagined is a worse trade than a few
megabytes. *(decided)*

**Considered and dropped: moving the derived data cache out of the VM.** It would keep gigabytes out
of the child, but a DDC is project data rather than something to share between projects, and the
normal recovery for a forge is [rollback](#backup-and-rollback) rather than delete-and-recreate — so
a cache inside the VM is what you want, surviving in the baseline. *(decided)*

**Still specification: *equipped*.** The vault credential and mount, and the screen server, remain
in the gateway — so `dr-forge screen` still works only on a guest that was prepared there. They join
`init` under the rule below, as does the desktop camera. Worth knowing when reading `init.ps1`:
its bash side is covered by `tests/forge.bats` against a mock, and the
daemon-facing PowerShell is *executed* against a mock daemon by `tests/forge-api.bats`. The guest
half is not and cannot be: `reduce-churn.ps1`, `install-shot.ps1` and `harden-sshd.ps1` touch
scheduled tasks, the registry, Defender and `sshd`, which no mock makes exist, so they still rest on
being a faithful port of measured code, plus a live run.

**A thing joins `init` when a Draugr verb's contract depends on it**, which paces the migration
rather than demanding it at once. The desktop camera joins when screenshots-through-`pull` are
built; the automation server joins if the UI verb is.

**`dr-forge rm` needed a guard nothing had** *(built)*. `asb_vm_delete` calls
`remove_dir_recursive` on the folder *derived from the disk path*, guarded only against a drive root
([the delete hazard](FORGE-DISKS.md#the-vms-folder-is-derived-from-the-disk-path-not-from-its-name)),
so the question is never "is this VM disposable" but "what else is in its folder".

**And the answer is closer to the edge than it looks.** *Measured:* every VM on this
machine reports `diskDirectory: C:\ForgeLayers` — the store holding `layer-0`, `layer-1` and
`layer-2-ue427`. It is safe only because each VM gets a **subfolder** of its own, so the frozen
layers are siblings rather than children. A VM pointed one level higher would have the whole store
in its blast radius.

So `lib/forge/rm.ps1` works out the folder that would go, confirms it by finding a disk in it rather
than trusting the name, and **refuses outright** on three shapes: the VM pointed at the store
itself, a read-only `.vhdx` anywhere beneath it (that is what frozen means, and a frozen parent is
what every child depends on), or another disk nested under it. A refusal is never offered as a
confirmation, because being asked to confirm something unsafe invites saying yes to it. Otherwise it
reports the folder, its size in GiB and its contents, and `dr-forge rm` shows all three before
asking. The verdict gates and the reasons explain — a verdict arriving without reasons still refuses.

It also clears the **shared** forge host key. Every forge VM presents on the same pinned
`host:port`, so they have one `known_hosts` entry between them, and left behind it makes the next VM
on that port look like a man-in-the-middle rather than a new machine. Clearing it cannot touch a
real server's key, because `dr-setup --forge` gives forge hosts a file of their own. What `rm` does
**not** do is rewrite `DRAUGR_FORGE`: which VM a project uses is a declared choice, and the
replacement does not exist yet, so it says so instead of guessing.

**The ssh alias is one wildcard block, not a file written per VM** *(built)*.
`dr-setup` already solved this problem for mounds — its own header notes that without a matching
block in WSL's `~/.ssh/config` neither `ssh <name>.sbx` nor git's `ssh://` transport works — and it
did so with **one** block for `*.sbx`. The pinned port makes the forge case easier still: every
forge VM's resolved config is [byte-identical apart from the `Host`
line](#the-pinned-port-has-a-price-a-far-end-is-not-identified-by-the-vm-being-up), so one `*.forge`
block covers every VM, there is no per-VM write step, and **a stale alias stops being possible** —
which is the class of bug that had `ue-427-test` reaching `test`.

It is written by `dr-setup --forge`, is **opt-in and sticky**: a machine that never asked for it
never carries a block mentioning a forge, and a later plain `dr-setup` puts back what it found
rather than deleting it. The key the block names is minted at the same time, separate from the
Windows-side admin key because ssh refuses one read off `/mnt/c`. Forge host keys get a
`UserKnownHostsFile` of their own, since every VM presents on the same pinned `host:port` and would
otherwise collide on one line — clearing a rebuilt guest's key cannot then touch a real server's.

**The two consequences, as settled.** The `ProxyCommand` names the gateway mound, and that name is
substituted when the block is written rather than resolved at connect time: git invokes `ssh`
directly, so the command has to work from any directory with no Draugr process in the path. It
defaults to `draugr-gateway` — the name Draugr itself will use once it
[generates the gateway](#which-directories-exist-and-which-of-them-you-keep) — is overridable with
`dr-setup --forge-gateway <mound>`, and is remembered from the existing block on a rewrite so a
re-run cannot quietly repoint the route. And the far end is now **`<vm>.forge`**, which
`dr_sandbox_ssh_host` composes for `dr-sync`, `dr-data` and `dr-code` alike. That suffix is spelled
in both `lib/common.sh` and `lib/forge/common.sh`, because no core script may source the forge
library; a test asserts the two agree.

### The gateway, generated: `dr-forge gateway` *(designed and built)*

The [topology](#which-directories-exist-and-which-of-them-you-keep) decided that the gateway is
generated rather than kept. This is the verb that generates it, and the design is here before the
code because the interesting parts are all refusals.

```text
dr-forge gateway <dir> [--vault <host path>] [--scratch <host path>] [-y]
```

**What it writes.** The template is `share/gateway.example/`, beside `config.example` and
`kit.example`, and the tree it produces is:

| generated | from the template | substituted |
|---|---|---|
| `.draugr.conf` | `draugr.conf.in` | the VM's name, the mound's name, the two host paths |
| `.draugr/kit/spec.yaml` | `kit/spec.yaml` | nothing — the deny list travels verbatim |
| `.draugr/hooks/post-up` | `hooks/post-up` | the two host paths, **and the mode** |
| `kits/base/spec.yaml` | `kits/base/spec.yaml` | nothing |
| `kits/unreal/spec.yaml` | `kits/unreal/spec.yaml` | nothing |
| `README.md` | `README.md.in` | the paths, so the commands in it can be pasted |

**Only three things in a gateway are not mechanism**, which is what the arguments are for: the forge
VM's name, taken from `DRAUGR_FORGE`, and the vault holder and scratch directories, which are host
paths this machine happens to have. Everything else — tinyproxy with no destination filtering, the
keeper, the SMB share, the deny list that narrows `sbx`'s ~190 defaults to the hosts the tools were
*seen* to use — is identical on every machine, and is why this is a template rather than a tutorial.

**No `.gitignore` in the template, on purpose.** The gateway is a data-only repository, and
`create-data-only` writes that file itself — unconditionally, `*` and nothing else — so a template
copy would be clobbered by the first command that created the repo. Generation therefore writes
`DRAUGR_ON_MISSING_REPO=create-data-only` into the config and leaves the repository to `dr-up` or
`dr-init` - *measured*: `dr_context_create` is called by exactly those two, and by nothing else, so
those are the commands that can make one. Either creates it on first use, with the `*` `.gitignore`
and two commits, after which `git status` is empty forever. The protocol stays in one place; the
generator stays a writer of files.

**The executable bit is load-bearing, and `share/` must not carry it.** `dr_hook` is
`[ -x "$hook" ] || return 0`: a hook that is not executable is **silently skipped**. A gateway
generated with a mode-644 `post-up` would come up with no keeper, no tinyproxy and no vault share,
and `dr-up` would not say a word — the mound would simply stop answering 30 s later. Meanwhile
`tests/executable-paths.sh` deliberately holds `share/` to non-executable (*"share/ is mostly
examples that must not be"*), so the bit cannot be inherited from the template. Generation sets it,
and a test asserts it on the generated copy rather than on the template.

**Trust is granted, because Draugr wrote the file.** `.draugr.conf` is sourced and `post-up` runs on
the host as you, so both are trust-checked, and an untrusted hook is refused mid-command. There is
precedent for granting it: `create-data-only` calls `dr_trust_add` on the `.draugr.conf` it writes
itself. Generation does the same for the two files it writes, on the same grounds — you ran the
command that wrote them — and **only** for files it actually wrote. A file left in place because it
differs is not re-trusted, because nobody here has read it.

**Re-running is the normal case, so it must not clobber.** The allowlist varies by kind of work
rather than by VM (Epic's hosts are the same for 4.27 as for 5.8), so a gateway is regenerated when
the work changes, and after a Draugr upgrade that improves the deny list. Each file lands in one of
three states, reported per file: **created**, **already current** when the content is identical, or
**differs — kept**, which is a refusal naming the file and the command that would overwrite it.
`-y` overwrites. Anything the template does not name is left alone, which covers `.git/`,
`.draugr/tmp/`, the `.applied` stamps, `.draugr.local.conf` and the password files a gateway's
neighbours keep.

**A generated gateway is not a second gateway you can run.** `DRAUGR_PORTS` publishes the fixed
`18888` and `18445`, `18022` is pinned, and the tunnel supervisor holds one mutex — so
[exactly one gateway can run](#which-directories-exist-and-which-of-them-you-keep), generated or
hand-made. Generating another is free and recommended while the first one is the one in use; bringing
it up beside the first is the one thing that does not work, and on Windows it fails *quietly*,
because a second process may bind a port that is already bound and the two then take turns answering.
`gateway` therefore generates and stops: it starts nothing, and `dr-forge up` reaches the gateway
through `DRAUGR_REQUIRES` exactly as before.

**What the build changed**. Two things, both refusals, and both found by running
the verb rather than by reading it. The guard against a mistyped directory was written as "an
existing `.draugr.conf` that does not publish 18888" - and a *tool's* checkout has no `.draugr.conf`
at all, so `dr-forge gateway` into Draugr's own directory wrote a config, a hook and two kit specs
into it instead of refusing. It kept the README, which is the only reason that was obvious within
the second. The guard is now **emptiness**: a non-empty directory is refused unless it already
publishes 18888, which is also what identifies the gateway being regenerated. And the per-file
report printed `overwrittenyes`, because `${had:+overwritten}${had:-written}` fires *both* arms when
`had` is set - `:-` returns the value of a variable that has one.

**The name is the weak part of this.** `gateway` is a noun among verbs (`up`, `down`, `init`, `base`,
`rollback`), and `dr-forge gateway <dir>` reads as a question rather than an instruction. The
alternatives considered were worse: `mkgateway` is unlike anything else in Draugr, `init-gateway`
collides with `init`, which means the VM, and a top-level `dr-gateway` would put a command in a
public `bin/` for a feature almost nobody turns on. It stands as `gateway` until someone has a
better one — the same open question `dr-layer` carries.

### The layer mechanism as a command: `dr-layer`

*(planned, built)* The layer verbs are **not** `dr-forge` verbs, and the reason is
structural rather than tidiness. Two things separate them:

- **The preconditions are opposite.** Everything `dr-forge` does needs the daemon **up**. Every disk
  verb needs it **down** with AppSandbox closed, because the daemon rewrites `vms.cfg` whenever
  anything changes and an edit made underneath it is simply lost. One command whose verbs disagree
  about so basic a precondition is how a symptom ends up three steps from its cause.
- **The gate is opposite too.** `dr-forge` is inert unless `DRAUGR_FORGE` names a VM — that is the
  whole optionality claim. But these verbs *create* the thing that key would name, so they cannot be
  gated on it, or you could never build a first forge.

**Verbs:** `list`, `adopt`, `new`, `freeze`, `thaw`, `drop`, and `provision` to build a layer-0 from
an ISO. Not `base` — that word is `dr-forge`'s, and the two mean different things.

**It must never run elevated, and this is the trap worth stating first.** Integrity runs one way: an
elevated client can use a `sandboxd` an ordinary shell started, but not the reverse. A `dr-*` command
run elevated with no `sandboxd` up starts an **elevated** one, `post-up`'s keeper pins it for the
mound's whole life, and every later command from an ordinary terminal then fails in the worst
available way — `dr-up` reporting `Status: stopped` about a daemon that is serving perfectly, because
its command line reads as DENIED from medium integrity. *Measured, and it cost an
evening.* So `dr-layer` stays ordinary and escalates only the short steps that genuinely need it —
the VHD cmdlets — handing their output back through a transcript, which is the road
`forge-engine-layer.ps1` took for the same reason.

**The `vms.cfg` editing lives in one file, by itself.** It is a workaround for two upstream gaps at
once: there is no promote-a-VM-to-a-template route, so a template can only ever be clean Windows
(*read from source*), and the
[snapshot bug](#it-has-a-bug-that-decides-the-design) rules out the other route. The format is
undocumented and was measured stale. Keeping it in one clearly-marked file means that if
[#199](https://github.com/jamesstringer90/appsandbox/pull/199) lands, the fix is deleting a file
rather than untangling it from the orchestration.

**PowerShell stops being something anyone types.** It cannot leave: the VHD cmdlets are
PowerShell-only, the daemon's API binds the Windows loopback and *(measured)* WSL cannot
reach it at all, and the guest is a Windows machine. But the pattern is already here — `bin/dr-forge`
is bash and every `lib/forge/*.ps1` says **not meant to be typed**. The front ends become bash; what
stays PowerShell shrinks to library files behind a verb.

#### What it is, verb by verb

The mechanism existed first as a hand-written script, 955 lines that work and are measured.
`dr-layer` is that script **adopted**, not rewritten: the order its verbs use is the whole
difficulty, and none of it was guessable the first time.

| verb | what it does | needs elevation |
|---|---|---|
| `list` | the registered VMs, each disk's chain, and every layer under the root | no — degrades, saying so |
| `adopt` | a finished VM's disk becomes a frozen layer: capture settings, move, prove, freeze, de-register, remove the emptied folder | yes |
| `new` | a differencing child on a frozen parent, with a VM block and an ssh port | yes |
| `freeze` | read-only on, and with `--unregister` the VM block off | yes |
| `thaw` | the undo: read-only off, `vm_state.json` back, the VM block rebuilt from `layer.json` | yes |
| `drop` | the layer directory and its VM block go | yes |

**Three files, split along what would be deleted if the upstream bug were fixed.**

- `lib/forge/vmscfg.ps1` — everything that knows the shape of `vms.cfg`: the block reader, the
  writer that keeps UTF-8-with-BOM and CRLF because that is what AppSandbox wrote, and the VM-block
  layout `new` and `thaw` both emit. This is the workaround, by itself, as the paragraph above
  requires. If [#199](https://github.com/jamesstringer90/appsandbox/pull/199) ever lands and a VM
  can be promoted to a template, this is the file that goes.
- `lib/forge/layer.ps1` — the six verbs, the disk work, the elevation relaunch, and `layer.json`.
  The sidecar is *not* in the file above, because it is not a workaround for the config format: it
  exists because de-registering a layer deletes the only record of the RAM, cores, GPU mode and
  network mode its children must inherit.
- `bin/dr-layer` — the bash front end, which is where the verbs, the flags and the refusals live.

**`layer.json` is why a chain is self-describing.** `new` copies `RamMB`, `CpuCores`, `GpuMode`,
`GpuName` and `NetworkMode` from a VM block — and a frozen layer's whole point is that no VM block
points at it any more. Without the sidecar the fallback was *the first VM block in `vms.cfg`*: some
unrelated VM whose GPU and network settings were then copied into the layer **without a word**. A
layer that differs from its parent in `GpuMode` or `NetworkMode` behaves differently from the thing
it was built on, and that surfaces three steps away.

**The guard that matters most looks wider than the root.** `thaw` and `drop` both refuse when
anything differences from the disk, because writing to a parent a child differences from corrupts
the child silently, with nothing in the stack reporting it. *Measured*:
`C:\ForgeLayers\layer-1` is the parent of `D:\ForgeLayers\layer-2-ue411`, and a check that scanned
only the root found no children for `layer-1` — one `drop` away from orphaning every engine layer on
the other drive. So the search covers the root, `<drive>\ForgeLayers` on every **fixed** drive, and
every `VhdxPath` in `vms.cfg`; a disk that cannot be interrogated is reported **unreadable** rather
than absent, and the caller decides.

**Exit codes**, because a front end has to tell a refusal from a failure: `0` done, `2` the arguments
are wrong, `3` AppSandbox is up and nothing was touched, `20` a guard bit (a writable parent, a layer
with children, a name or ssh port already taken, a size below the parent's), `21` something named
does not exist, `24` elevation was declined.

**Where layers live** is [`DRAUGR_FORGE_LAYERS`](CONFIG.md#draugr_forge_layers), empty by default and
meaning `C:\ForgeLayers`, with `--root` to override one invocation. It must be your **fastest** disk
rather than your biggest: reads walk the chain, so the frozen parents holding Windows, Visual Studio
and the engine are the hot read path. A store per drive is the normal shape here, not an exotic one —
the engine layers are the big ones.

#### What the build changed

**The daemon is checked before elevation is asked for**, which the script this was adopted from had
the other way round. `Get-Process` needs no elevation and the relaunch raises a UAC prompt, so the
original order made you accept a prompt and *then* told you AppSandbox was running and nothing had
been done. A refusal that costs a prompt first is how people learn to click through prompts.
Verified on this machine with the daemon up: `dr-layer freeze test` printed the shutdown recipe and
exited 3, with no prompt.

**A flag aimed at the wrong verb is a refusal.** `layer.ps1` takes them all and uses each where it
means something, so a misaimed one was accepted in silence - and `dr-layer drop x --force` would
read as "I forced it" while forcing nothing at all. The front end is the only place that knows what
was *typed*, so that is where it is caught, along with `new`'s missing `--parent`: the answer then
arrives without crossing to Windows, instead of the daemon-is-up check answering something else
first.

**Verified live, including the elevation round-trip**. `dr-layer new
my-test-layer3 --parent layer-2-ue427 --dry-run`, run from WSL with the daemon still up:

```text
  the VHD cmdlets need elevation - asking for it once (accept the UAC prompt).

=== new layer 'my-test-layer3' on layer-2-ue427 ===
  parent  C:\ForgeLayers\layer-2-ue427\disk.vhdx (512 GB)
  child   C:\ForgeLayers\my-test-layer3\disk.vhdx
  size    512 GB (inherited)
  nothing was created (-WhatIfOnly)
```

Four things at once, and none of them was certain beforehand. `Start-Process -Verb RunAs` works
when the chain *starts in WSL* — bash, `powershell.exe`, UAC, an elevated child. The
**transcript** carries that child's output back: its console is a separate window that closes the
instant the script ends, so every line above was recovered from a file rather than inherited.
`Get-VHD` answered under elevation, which is the whole reason the relaunch exists. And `--dry-run`
skipped the daemon check while AppSandbox was running, which is deliberate — rehearsing a layer
while the forge is up is most of its value — with the parent already frozen, so the
writable-parent refusal correctly stayed quiet.

#### What is deliberately not in it

- **Engine layers.** `forge-engine-layer.ps1` turns one engine version into one frozen layer by
  driving the Launcher, naming `layer-2-ue412`, and calling the verbs above. That is the forge
  *project's* build logic, which the
  [topology](#which-directories-exist-and-which-of-them-you-keep) puts in your private repository,
  not in Draugr. It keeps working by calling `dr-layer new` and `dr-layer freeze` instead of a
  sibling script.
- **`provision`**, building a layer-0 from a Windows ISO. It belongs here by the verb list above,
  and it is **stage two** — designed below, in three parts, because it is ~3,980 lines of adopted
  script and one reviewable change cannot be that.

#### Stage two: `dr-layer provision` *(designed and built, in three stages)*

A layer-0 is a generic Windows guest an agent can drive: no network adapter of its own, reachable
over ssh, able to get out only through the gateway, and carrying the components
[judged unconditional above](#where-the-line-falls-draugr-owns-the-mechanism-you-own-the-contents). The gateway's
`forge-provision.ps1` builds one in a single idempotent run, including creating the VM and
installing Windows unattended, and it is what this verb adopts.

**The size, measured, because it decides the shape of the work:**

| | lines |
|---|---|
| `forge-provision.ps1` | 1,243 |
| guest scripts Draugr does not have yet | 2,738 |
| guest scripts it already has, reused rather than re-adopted | — |

The six already here — `authorize-key`, `harden-sshd`, `install-shot`, `install-tunnel-key`,
`reduce-churn`, `set-computer-name` — are called where the original called its own copies.

**Three parts, each ending somewhere that can be checked:**

- ~~**2a, the base.**~~ **Built**: `lib/forge/provision.ps1` (1,050 lines, adopted by
  patching a copy) plus the five guest scripts — `install-guest-base`, `install-windows-online`,
  `write-manifest`, `cleanup`, `preflight` — and `dr-layer provision` in front of them. Phase 0
  creates the VM and installs Windows unattended, with the network already `None` and a key
  already in place; the phases after it are the host keys, the guest's OS settings, *make Windows
  believe it is online*, the restricted tunnel key, the egress proof, cleanup and the manifest.
  **One password, not two**: the second is VNC's, for a screen server stage 2b installs, and
  asking for a password for something nothing will install is how a person comes to believe a
  secret was set.

  *Verified* as far as it can be without an hour and an ISO: the argument surface and every
  refusal from bash, and the preconditions against the live daemon — it reported AppSandbox
  0.1.8 and refused an unknown VM, naming the one that exists. **Not yet exercised:** phase 0
  itself, and the ssh-dependent phases, which need the guest up and the gateway with it.
- ~~**2b, the unconditional components.**~~ **Built**: six more guest scripts and the
  two host-side ones, ~1,430 lines, again adopted by patching copies. Seven phases between the
  egress proof and cleanup, in this order:

  | phase | what it puts in the guest | where it comes from |
  |---|---|---|
  | `msys2` | MSYS2, pinned to one mirror *before* its first sync | `repo.msys2.org`, which `kits/base` already allows |
  | `tools` | the Unix set: git, rsync, jq, ripgrep, make, openssl, 19 in all | the same pinned mirror |
  | `automation` | `uv`, a real `python`, the UIA MCP server as a **session 1** task, AutoHotkey | hosts `kits/base` already allows |
  | `shot` | the desktop camera: how an agent with only a shell can *see* | already adopted — `install-shot.ps1` |
  | `screen` | TightVNC's server, loopback-only, pinned by SHA-256 | the vendor, fetched **on the host** |
  | `vault` | the share password and `mount-vault.ps1`, then a reboot | the mound's SMB share |
  | `vscode` | VS Code, 233 MB | the vault if it holds a copy, else the vendor |

  **`vault` before `vscode` is the reason there is an order at all.** The installer is 233 MB, the
  guest's only way out is the proxy over the ssh tunnel, and the vault phase is what puts the share
  credential in the guest. The other way round, every rebuild pays for the download again.

  Nothing in that table is Unreal-shaped, which is what makes it a base rather than a layer: it is
  what any Windows VM an agent drives would want. Two of the seven are **not** guest scripts — the
  screen server and the vault reach *into* the guest from the host — and that is the first of 2b's
  own decisions below.

  *Verified* the same way 2a was, and no further: the argument surface and every refusal from
  bash, every file parsed by PowerShell's own parser, and `--skip-netfx` refusing while its seven
  new siblings are accepted. **Not exercised:** anything that needs the guest up. Every phase in
  that table installs something over ssh, so the whole table is unrun — and its comments carry the
  gateway's measurements, cited as the gateway's, not re-measured here.
- ~~**2c, the optional component.**~~ **Built**: `.NET Framework 3.5`, one guest
  script, `install-netfx3.ps1`, 126 lines. Unreal wants it — installing UE 4.27 raised Windows' own prompt
  for it (measured) — and it belongs in the base rather than an engine layer, because
  every engine version would hit it separately.

  **It cannot install itself, and that is what shapes the stage.** `NetFx3` is a *Feature on
  Demand*: the payload is not on the installed system, and Windows fetches it from Windows Update.
  This guest has Windows Update turned off *and* no network adapter, so the prompt's own button
  fails twice over and reports neither cause. The payload exists in exactly one place — the
  `\sources\sxs` folder of a Windows ISO — and **it must match the guest's build**, or `DISM`
  fails with `0x800f081f`, which reads as a missing file rather than as a version mismatch.

  **So the payload is a thing a human has to produce, and that is why the phase is off.** A phase
  whose precondition no script can satisfy would fail on every fresh machine, and a provisioning
  run that always ends with one red row teaches you to ignore red rows.

  **One flag, which is both the switch and the precondition**: `--netfx <path>`, naming the cab or
  the folder holding it, **on the host**. Its presence turns the phase on; its value is what makes
  the phase possible. That collapses "off by default" and "refuses up front" into one mechanism
  rather than two, and the refusal is a `Test-Path` in the preconditions block — *before* phase 0,
  so a missing payload costs a second rather than an hour.

  **The host holds it and pushes it in**, the way `screen-access.ps1` does with the pinned MSI,
  rather than the guest fetching it from the vault. Three reasons, in order of weight: the check
  has to happen before phase 0 and the guest cannot reach the vault until phase 11 has installed a
  credential and rebooted it; `--netfx` then works on a gateway that serves no vault at all; and
  the 68 MB goes over `scp` on loopback, which is seconds. The guest script keeps its vault route
  for anyone running it by hand — `-Share` and `-SubDir` are untouched — it is simply not the road
  `provision` takes.

  **`--iso` is where the matching cab comes from**, and the error message says so: if the run
  created the VM, the ISO it installed from is by definition the matching build. Draugr does not
  mount it itself, because `Mount-DiskImage` needs elevation and nothing in `provision` claims
  any — the third change above is what removed the last of it. It tells you the path inside the
  ISO instead.

  **`--skip-netfx` stays refused**, with a different reason now: the phase is off unless `--netfx`
  names a payload, so omitting that flag *is* how it is turned off, and a second switch for the
  same decision is one that can disagree with the first.

  *Verified*, as with 2a and 2b: the argument surface and both refusals from bash, the files
  parsed, and — the one worth naming — a test that reads the **line numbers** to assert the
  payload check sits above phase 0's heading, because "before the hour" is a claim about
  position and nothing else would catch it moving. Mutation-tested by moving the block below
  phase 0. **Not exercised:** the phase itself, which needs a guest, a cab and `DISM`.

**Two phases must change rather than be copied**, and this is the part worth settling before any
code moves.

- **The gateway (phase 4).** The original runs `dr-kit validate` and `dr-up` against a hard-coded
  gateway directory. Draugr already has the answer to "bring the gateway up": `DRAUGR_REQUIRES` and
  `dr-dep up`, which is how `dr-forge up` does it, inheriting the whole protocol — trust before
  anything is sourced, the claim written before anything starts, the cycle guard, and the warden
  that stops `sbx` auto-stopping an idle mound. So `provision` is run **from the project that names
  the gateway**, and the bash front end brings it up that way. With nothing requiring a gateway it
  says so and refuses the phases that need egress, rather than building a base that cannot download
  anything.
- **The tunnel (phase 5).** The original calls the gateway's `install-tunnel-autostart.ps1`, which
  is both a different file and a *logon task* — and
  [keeping host changes minimal](#considered-and-rejected) ruled that out. The supervisor lives at
  `lib/forge/tunnel.ps1` now, started by `vm.ps1 -Mode tunnel`, and that is what `provision` calls.
  The same correction `dr-forge` already carries, for the same reason: depending on another
  project's directory layout is how `up` broke when a gateway was renamed.

**A third thing changed that the design had not predicted**. The original *runs
elevated* and brought the mound up itself, which is what made the integrity hazard real — and its
`-AllowElevatedGateway` existed to overrule the refusal that followed. Here the front end brings
the gateway up through `dr-dep`, in the ordinary shell you typed in, and the script only ever talks
to the daemon over HTTP, which needs no elevation at all: the token is in `host.json` and every
other `dr-*` command does the same. So the claim, the flag and the three helpers that existed only
to run `dr-up` from inside PowerShell are all gone, and the measurement that explains *why* nothing
here starts a daemon stays. A port that kept the flag would have kept a switch with nothing left to
allow.

##### 2b's own five decisions

- **`install-` means "runs in the guest".** Host-side forge scripts are `lib/forge/<thing>.ps1`;
  anything copied into the guest and run there lives in `lib/forge/guest/`. Two of the gateway's
  installers are host-side despite their names — they hold a pinned MSI and a share password the
  guest must never choose for itself, and push them in over ssh — so they are adopted as
  `lib/forge/screen-access.ps1` and `lib/forge/vault-access.ps1`, and the prefix stops lying.
- **A provisioning run does not install the host's VNC viewer.** The gateway's screen installer puts
  TightVNC's *viewer* half on the host as well, behind `Start-Process -Verb RunAs`: a UAC prompt, in
  the middle of an hour-long unattended run, which is precisely what "every question is asked up
  front" exists to prevent — and [keeping host changes minimal](#considered-and-rejected) points the
  same way. So it is skipped by default and named in the summary, with `--install-viewer` to ask for
  it. Nothing is lost by waiting: `lib/forge/screen.ps1` already handles a host with no viewer by
  leaving the forward up and saying that any viewer pointed at `127.0.0.1:15900` will do.
- **The vault phase asks whether there is a vault — and the question had to be made answerable
  first.** The phase writes a share password into the guest and then **reboots** it, because the
  guest's own `LanmanServer` holds port 445 until a restart, so doing that for a share nobody
  serves spends a reboot on nothing. The obvious check is the mound's `18445`, which phase 4
  already probes — and *as first written this was wrong*: the generated config published `18445`
  **unconditionally**, and a published port is bound on the host by the publisher, not by whatever
  is meant to be behind it. The host would have answered for a service nobody was running.

  So the generator changed too: `dr-forge gateway` publishes `18445` only when a `--vault` was
  given, gated on the same path `post-up` gates the share itself on. The port is now a fact about
  this gateway rather than a line in a template, which is what makes it readable from the other
  side. `post-up` skips the share in a **second** case as well — no `draugr_vault_smb.pass` on the
  host — and that one the phase simply reads, because the file is on its own side. Both report and
  skip; neither reboots.
- **The second password arrives now, not in 2a.** 2a asks for one because nothing it installs has a
  second; `screen` is what makes VNC's eight-byte key real. `Get-Secret`'s truncation arm — warn,
  cut to 8, write the cut value back so the file and the server cannot disagree — was adopted in 2a
  unused, for this.
- **`Add-ToMachinePath` stays duplicated in two guest scripts.** Each guest script is copied in
  alone and run alone, so a shared helper would make "copy one file, run it" false. The forty lines
  are identical in both, and both say which other file carries the twin.

**One parameter deliberately gets no flag.** The MCP server's port is `8765` inside the guest because
`lib/forge/tunnel.ps1` forwards `18765` to it; a `--mcp-port` would let someone move the server away
from the tunnel that reaches it. It stays a `provision.ps1` parameter with a default, passed to the
automation phase and to the manifest so the two cannot drift, and the front end does not offer it.

**What provision must never do**, all three inherited deliberately: install AppSandbox, enable
`VirtualMachinePlatform` (it needs a reboot), or produce a Windows ISO — those stay a human's, and
it says so. It will not change an **existing** VM's network to `None` either; it reports the setting
and refuses, because provisioning a guest that still has its own way out would bake a hole into the
base image. The API can make that change; opening a forge to a network stays something you did.

**`-DiskGb` is the number that cannot be taken back**, and it binds every layer above: this disk can
never be resized, a child inherits the capacity and can only be grown, and AppSandbox's own
snapshots take no size argument at all. The VHDX is dynamically expanding, so a generous number
costs nothing until it is used — 512 GB leaves room for an engine, a project and a warm cache.

#### The one tension, stated rather than hidden

Everything else about the forge is invisible unless `DRAUGR_FORGE` names a VM. `dr-layer` cannot be:
it *creates* the thing that key would name, so gating it there would mean never building a first
forge. The cost is a command in a public `bin/` that almost nobody wants, and the mitigation is only
that it says so — on a machine with no AppSandbox it refuses with one line and a pointer here, rather
than explaining layers to someone who was looking for something else.

### Run-state dependencies, planned separately

**The requirement:** in the game project, one `dr-up` starts whatever the agent's mound depends on
and is not already running, then the mound itself. Nothing starts twice, and nothing that is running
is restarted.

That is a general Draugr feature with no forge in it, so it has its own plan:
**[DEPENDENCIES.md](DEPENDENCIES.md)**. It carries the six-link chain, the claim model, the optional
lock, the counted stop with its linger, the security consequences of requiring another repository,
and the acceptance criteria. The decisions taken — elevation stays manual, the
mechanism lives in core, the lock is optional and declared by the dependency, stopping is counted —
are recorded there, and are not repeated here so that the two cannot drift apart.

**What stays on the forge's side of that line**, and is planned here rather than there: the
AppSandbox daemon check (link 1), the VM (3), the tunnel (4) and the guest preflight (5). None of
them is a mound. The gateway (2) is a mound, so core starts it and `dr-forge` only asks whether it
answers — which is what keeps [optional by construction](#optional-by-construction) intact: core
gains a general mechanism, and every forge-shaped step stays behind `DRAUGR_FORGE`.

One consequence worth keeping in view here: the plan makes **core** responsible for the keeper
session that stops `sbx` auto-stopping an idle dependency 30 s after its last session *(measured)*.
The gateway's `post-up` hook does that today, and keeps doing it for the times the gateway is
brought up by hand rather than as a dependency — the two keepers do not fight.

---

## What runs where

The daemon is a Windows process and Draugr runs in WSL, so `dr-forge` reaches it the way Draugr
already reaches `sbx.exe` — through `powershell.exe`, with path translation. `asb.py` is
dependency-free, so the shim is a Windows Python invocation, not a packaging project.

**The daemon must run elevated** (*read*, and how every test here was run). The first draft said
elevation was not needed; it is. `dr-forge` cannot elevate for you, so it checks, and says so.

The tunnel supervisor and the gateway's keeper are long-running Windows processes, started the way
the gateway's `post-up` hook already starts the keeper: `Start-Process -WindowStyle Hidden` through
`powershell.exe`.

---

## Considered and rejected

- **ExHyperV as the backend.** No CLI, so it cannot be part of a loop; GPL-3.0; and it needs the
  Hyper-V role, whose checkpoint ban on GPU-partitioned VMs made rollback hard.
- **Scripting GPU-PV setup ourselves.** Driver injection is welded to the host driver version and
  breaks on every GPU driver update. `gpuMode=1` makes the question moot.
- **Running the agent inside the forge** — including Claude Desktop's computer use there. Then there
  is no mound and no boundary, and this stops being Draugr. The forge is a machine the agent *talks
  to*, never one it lives in.
- **Giving the mound the daemon's bearer token.** It would hand the agent the power to create and
  delete VMs on your machine. The control/data split is the whole reason this is safe to build.
- **`netsh portproxy` into WSL, then `DRAUGR_HOST_PORTS`.** Needs host administrator rights and a
  second hop; the `localhost:` rule reaches Windows loopback directly.
- **A guest firewall instead of no adapter.** The agent is a guest administrator, so it can turn any
  guest firewall off (*measured* in NAT mode).
- **A separate project rather than a Draugr feature.** The channel is the mound's own proxy, the code
  loop is `dr-send`'s, the file loop is `dr-data`'s, the egress is `dr-policy`'s, and the consent
  model is `dr-trust`'s. A sibling project would reimplement five things Draugr already does, and
  being optional inside Draugr costs nothing.

---

## Open questions

*Resolved: whether to share one forge between projects — the disk layers answered it
([above](#one-forge-per-project-which-the-layers-decided)). What becomes of a gateway directory,
and whether Draugr ships a gateway template — the
[topology](#which-directories-exist-and-which-of-them-you-keep) answered both: it ships one, and the
gateway stops being a repository anybody keeps.*

1. **Which Epic account.** A dedicated one is safest and has its own, empty, Fab library. Your own
   is convenient and puts your library and your account in reach of the agent. See
   [Security](#security).
2. **How much does AppSandbox's youth cost?** The snapshot bug is the first real answer, and the
   author's stance on pull requests is the second: fixes arrive on his schedule. Worth watching
   before building much on top of it.
3. **Is `dr-layer` the right name?** It sits beside `dr-up` and `dr-mem` in a public `bin/`, where
   "layer" means nothing until you read the forge docs. No better candidate yet.
