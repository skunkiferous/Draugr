# The forge: a Windows VM your agent can build and test in

> ### Optional. Most people using Draugr will never want this.
> The forge is a **"by the way, you can also do this"** feature: a GPU-accelerated Windows VM on your
> own machine, so an agent in a mound can build and test a Windows game. If you do not set
> `DRAUGR_FORGE`, none of this exists — no command runs it, no check mentions it, and nothing needs
> installing. See [Optional by construction](#optional-by-construction) for how that is enforced.

> ### Status: proposed, partly measured, not built.
> Claims carry one of three labels, the same bar the rest of these docs use: *measured* (run on this
> machine, result quoted), *read* (from source code or documentation, not run), and *unmeasured*.
> The network half is measured end to end and has its own document,
> [FORGE-GATEWAY.md](FORGE-GATEWAY.md).

An agent in a mound can write UE5 C++, edit Blueprints, and reason about a game it can never build.
The mound is Linux; the target is a Windows game. That gap is what the forge closes.

---

## Optional by construction

"Optional" is enforced by the structure of the code, not by remembering to be careful:

- **One switch.** Everything is inert unless `DRAUGR_FORGE` names a VM — the same gate `dr-plugin`
  uses with `DRAUGR_PLUGIN_STORE`. `dr-doctor` says nothing about the forge while it is empty.
- **Isolated code.** All of it lives in `bin/dr-forge` and `lib/forge/`. No core script sources it,
  and `dr-up` and `dr-go` never call into it unless the switch is set.
- **No new dependency for anyone else.** No Python, no AppSandbox, no PowerShell module on the
  default path.
- **Tests against a mock AppSandbox**, the way `tests/mocks/sbx` stands in for `sbx`, so they run
  on any machine with zero skips.
- **Its security claim is separate.** The forge makes a weaker promise than a mound does, and
  `SECURITY.md` keeps it in its own clearly conditional section, so the core safety model stays
  exactly as it is for everyone who never turns this on.
- **Nothing game-specific in core.** The Unreal network rules live with the gateway, not in
  `share/`.

The Draugr fixes this work turned up are the exception, and rightly: they correct things that are
wrong for every Draugr user today, and none of them is forge-shaped. They are
[track B](#order-of-work).

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

The README's mental model is three repositories. The forge adds a fourth clone and a second
*machine*, plus a gateway mound that gives that machine its only way out:

```text
      YOUR REMOTE  (origin)
           ▲  │
      push │  │ pull
           │  ▼
      HOST REPO  ◄──── dr-sync ────  SANDBOX CLONE  ──── dr-forge push ───►  FORGE CLONE
   /mnt/c/Code/MyGame                (the mound —                     (Windows 11 VM:
           │                          where the agent                  UE5, MSVC, and
           └── mounted READ-ONLY ──►   actually lives)                 a slice of the GPU)
                                             ▲                                  │
                                             └───── logs, artifacts, PNGs ──────┘
                                                                                │ no network adapter
                                                                                ▼
                                                    GATEWAY MOUND ◄── ssh -R tunnel
                                                    (tinyproxy; the sbx policy is the allowlist)
                                                                                │
                                                                                ▼
                                                                            internet
```

**The agent never leaves the mound.** What it gains is one ssh channel to one port on one machine,
and that machine has no network of its own. Three planes, kept apart:

| Plane | Between | Who holds it |
|---|---|---|
| **Control** | Draugr ↔ AppSandbox's API: create, start, stop, snapshot, delete | Draugr, host-side, in WSL. Never the mound |
| **Data** | the agent ↔ the VM, over ssh | the agent, one key, one port |
| **Egress** | the VM → the internet, through the gateway | the `sbx` policy, exactly as for a mound |

---

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
> `DRAUGR_FORGE` is set. This belongs in `docs/DESIGN.md`'s **Standing risks**, worded at least this
> strongly.
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

## What has been measured

On this machine, AppSandbox **0.1.4**, a Windows 11 guest, an RTX 4090 host. *Measured* throughout
unless labelled.

### GPU-PV works, and the guest reports DirectX 12 Ultimate

`gpu-test.exe` renders **all six** of its cubes — D3D9, D3D10, D3D11, D3D12, OpenGL and Vulkan. The
Vulkan one matters more than it looks: Vulkan drivers are vendor-supplied, so a working one means
NVIDIA's real driver is in the guest rather than a generic shim. `dxdiag` reports **Feature Level
12_2** — DirectX 12 Ultimate, which is the capability Nanite and Lumen require. Task Manager's
Performance tab shows the 4090 with live counters, so the performance path works through
paravirtualisation too.

### The UE5 editor runs, and builds

Unreal Engine 5.8.2 and Visual Studio 2022, in a guest with **no network adapter** (2026-09-14 and
2026-09-18; details in [FORGE-GATEWAY.md](FORGE-GATEWAY.md)):

- the editor opened projects, the Fab plugin loaded, and Play worked;
- Lightmass through Swarm finished `170/170 mappings`, twice;
- a C++ project built: `UnrealBuildTool` reported `Result: Succeeded` in 115 s from the command line,
  and Build Solution succeeded in the IDE;
- a **Windows 11 Home** guest works.

### The guest has three display adapters, and only one of them is the GPU

```text
Name                                DriverVersion   PNPDeviceID
Microsoft Hyper-V Video             10.0.26100.1150 VMBUS\{DA0A7802-…}
NVIDIA GeForce RTX 4090             10.0.26100.1150 PCI\VEN_1414&DEV_008E&…
App Sandbox Virtual Display Adapter 0.1.4.0         ROOT\DISPLAY\0000
```

- **`dxdiag`'s Display tab shows the virtual display, not the GPU.** The "App Sandbox Virtual
  Display Adapter" is the synthesized 1920×1080 monitor; rendering is delegated to the
  paravirtualised adapter behind it, the same split WSL2 uses. Do not read GPU health off that tab.
- **The GPU's vendor ID is Microsoft, not NVIDIA.** `VEN_1414` is Microsoft. That is what GPU-PV
  *is*: a Microsoft paravirtual device fronting the real card. UE5 logs the name correctly, and
  `IsRHIDeviceNVIDIA()` returns false, so NVAPI, Aftermath and vendor extensions stay off. The
  editor running at all (above) settles that UE5 accepts it.
- **`nvidia-smi` is not in the guest.** GPU-PV injects what D3D, Vulkan and CUDA need, not the full
  driver package, so NVML — and almost certainly NVAPI — are absent. `dr-forge` cannot check the GPU
  with `nvidia-smi`.
- **Adapter selection is a live risk.** With three display devices, UE5 picks one at startup, and
  picking `Microsoft Hyper-V Video` would look like a broken GPU. The lever is
  `-graphicsadapter=<n>`, or `r.GraphicsAdapter` under `[/Script/Engine.RendererSettings]` in
  `DefaultEngine.ini` (`-1` auto, `-2` first non-integrated, `0` and up by index). The editor's
  `Saved/Logs/<Project>.log` lists every adapter it found and names the one it chose, so
  `dr-forge doctor` should report that line.

### The API drives the VM, and it is fast *(measured 2026-09-20)*

Driven from `tools/headless-api/asb.py` on the host's Python, against `AppSandbox.exe --headless`
0.1.4:

| Call | Result |
|---|---|
| discovery | `%ProgramData%\AppSandbox\host.json` gives endpoint, port and a per-run bearer token; `asb.connect()` needs no configuration |
| `version()` | `0.1.4`, `apiVersion v1`, capabilities `snapshots` and `templates` |
| `host()` | 32 cores, 130 998 MB RAM, 222 GB free — the numbers `dr-forge status` would report |
| `list()`, `status()` | every field the forge needs: `state`, `running`, `agentOnline`, `sshPort`, `networkMode`, `gpuMode` |
| `start()` + `wait_online()` | **14 s** from stopped to `agentOnline`, booting the current state — no argument means no branch is created |
| `ssh_info()` | host, port, user, `sshState`, `keyDeployed` |
| `open_display()` | **crashed the 0.1.4 daemon**; on 0.1.8 it opens a real window and `display_status` follows it — see the limit below |

So a mound can start the VM, wait for it, learn where to `ssh`, and put a screen in front of a human,
with nobody touching a GUI — on 0.1.8. The display call kills 0.1.4; see the limit below. What the
daemon costs is AppSandbox's **management** window, since the mutex allows one instance: no VM list,
no settings dialog, no snapshot tree while it runs.

**The tunnel supervisor self-heals, measured the hard way.** Restarting AppSandbox stopped the VM
out from under a running `vm-tunnel.ps1`. After the API started the VM again, the supervisor
reconnected on its own and the guest's preflight passed with no human action.

### Limits found

- **Ray-tracing shaders can take the guest down.** Compiling the path tracer's shaders first killed
  NVIDIA's user-mode driver in an editor worker, and a later run ended in a guest bugcheck
  (`0x3B SYSTEM_SERVICE_EXCEPTION`), with AppSandbox's own display driver `AppSandboxVDD.dll`
  crashing six times in 45 s until Windows gave up on it. The GPU itself stayed healthy.
  `r.RayTracing=False` and `r.PathTracing=False` avoid it — and a project template may set
  `r.RayTracing=True` further down the same section, where the last value wins.
- **Windows reports the guest offline**, because it has no adapter. No tool tested refused to run
  because of it; the Visual Studio Installer warns first and then carries on.
- **Certificate revocation fails with no interface at all**, which breaks anything strict about it.
  A dummy loopback adapter fixes it and adds no route out. See
  [FORGE-GATEWAY.md, the loopback adapter](FORGE-GATEWAY.md#the-loopback-adapter).
- **The guest patches itself** through the gateway and reboots mid-build. Automatic Windows Update
  is turned off in the base image.
- **The display is fixed at 1920×1080, 60 Hz** for Windows guests (*read*). For an agent taking
  screenshots that is mostly a feature — a fixed size makes a screenshot a repeatable test artifact —
  and a real limit only for a human who wants to work in the editor at 4K.
- **The guest's display blanks at random** *(reported by the tester, 2026-09-20)*: a black rectangle
  while it redraws, lasting long enough to notice. Harmless to a human, but it decides how the agent
  may read the screen: an all-black or partly black frame is **"retry"**, never state, and a check
  that samples a single screenshot can be wrong about what is on screen. It also weakens any "I saw
  nothing fail" report from inside the VM, this plan's included.
- **`open_display` crashes 0.1.4, and is fixed in 0.1.8** *(both measured 2026-09-20)*. On the
  0.1.4 build the call returned `200 {"displayOpen": true}`, a window titled `<vm> - IDD Display`
  existed just long enough to register as the process's main window, nothing was ever visible on
  screen, and `AppSandbox.exe` then died with **exception `0xc0000005` in `ntdll.dll`** (Application
  Error, faulting PID matching the daemon). The daemon owns its VMs, so the VM went down with it,
  ungracefully. `display_status` also reported `{"open": false}` throughout.

  On pristine 0.1.8, against a throwaway VM in an isolated data root, the same call opened a real
  window (1936×1119, on screen), `display_status` reported `{"open": true}`, and the daemon was
  still answering ten seconds later. Nothing to report upstream — but it is a concrete reason to
  **run 0.1.8 rather than 0.1.4**, which the forge needs anyway for the snapshot fix in
  [PR #153](https://github.com/jamesstringer90/appsandbox/pull/153).

  The design lesson survives the fix: the daemon can die, and when it does it takes every VM with
  it, so the agent's session, the tunnel and any running build must tolerate that. There is a
  ready-made signal for it — a clean `shutdown_daemon()` **deletes** `host.json`, so a discovery
  file with no daemon behind it means the last one died. `dr-forge doctor` should say so in those
  words instead of reporting a dead endpoint.

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

The build document, the Unreal allowlist and the full measurement record are
[FORGE-GATEWAY.md](FORGE-GATEWAY.md). Two consequences for the forge as a whole:

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

The cost is one more mound, 2 GiB in the [budget](#budget-on-this-specific-machine), and one more
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
> (*measured*). This is true of every mound, not only the gateway; it is one of the
> [track B](#order-of-work) fixes.

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
is a [track B](#order-of-work) item and on this feature's critical path.

Rules that go with it:

- **SSH port only, never the AppSandbox API.**
- **Password logins off first.** The guest's `sshd` accepts passwords by default; a mound given this
  rule could otherwise try to guess the administrator's.
- **Resolve the port at every start**, and reap stale `localhost:` rules. It has stayed constant
  across VM restarts, VM replacement and a host reboot (*measured*), and 0.1.8 retries saved ports
  before picking a new one (*read*) — but a value you can resolve is one you should never ask a human
  to keep in sync.

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
| `dr-forge push` | the agent's commits into the forge's clone over `ssh://` — `dr-send` with a different far end |
| `dr-forge pull <path>` | logs, cooked artifacts, screenshots — `dr-data pull` with a different far end |

Draugr already runs a git loop and an rsync loop over ssh to a machine that is not this one. The forge
is a third far end, not a third mechanism.

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

**The deciding unknown is Slate.** Most of these servers see an application through Windows'
accessibility tree, which gives them named buttons and fields. The Unreal Editor draws its interface
with Slate, Unreal's own toolkit, not with Windows controls, and the Launcher mixes its own UI with
embedded Chromium views. If Slate exposes little to the accessibility tree, a tree-based server sees
one opaque window and must fall back to screenshots and coordinates. Visual Studio, built on WPF,
exposes it well. So the first question for [spike S6](#order-of-work) is whether the tree can see
inside the Launcher and the editor — and the answer picks the server. The likely answer is a server
that does **both**: the tree where it works, screenshots where it does not.

### An optimisation, not the target: Unreal's own MCP plugin

UE 5.8 ships an official **Unreal MCP** plugin (*Experimental*): an MCP server inside the editor
process, at `http://127.0.0.1:8000/mcp`, with tools for actors, lighting, materials, Slate widget
inspection and automation tests (*read*: [Epic's
documentation](https://dev.epicgames.com/documentation/unreal-engine/unreal-mcp-in-unreal-editor)).
Where it covers a task it beats clicking — no pixels, and it runs inside the editor, so it is in the
user's session by construction. It does not reach the Launcher, and it is off by default.

It has **no authentication** and Epic says it is "not safe to expose beyond the local machine". An ssh
forward reachable only through the agent's authenticated channel is the right shape for it;
publishing the port is not.

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
[#152](https://github.com/jamesstringer90/appsandbox/issues/152), with a tested fix attached as a
suggestion, [#153](https://github.com/jamesstringer90/appsandbox/pull/153), which is the form he asks
for. The fix freezes the branch the VM is on as the new snapshot, and continues on a fresh branch of
it.

**Until a release fixes it, `dr-forge` uses a single baseline.** The first snapshot is correct, so:

- `dr-forge base` takes the baseline **once**, and refuses to take a second one;
- `dr-forge rollback` discards the working branch and starts a new one from that baseline;
- moving the baseline forward waits on upstream.

If even the first snapshot turns out not to work with the GPU attached ([S4](#order-of-work)), the
fallback is stopping the VM and copying its disk file: minutes rather than seconds, done behind
AppSandbox's back, and *unmeasured*.

> **Never take a snapshot of a VM holding work you have not saved elsewhere** until the fix ships.
> This bug has already stranded real work on this machine.

### Two properties of rollback, whatever the implementation

- **Rollback is whole-machine, so it discards the derived data cache too** — and re-cooking shaders
  from cold is not a rollback, it is a punishment. So the baseline should be taken **after a warm
  build**, and the DDC lives inside it. With a single baseline, that one snapshot is worth taking
  carefully.
- **Snapshots need the VM stopped**, so `base` and `rollback` both imply a stop, and both say so
  before doing it.

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

The sentence for `SECURITY.md`, in its own conditional section: *if you enable the forge, the mound
still cannot reach your machine; it can now reach a machine you own, over one port, with no network
of its own except through the same policy that governs the mound. That is a weaker claim than the one
Draugr makes about the mound, and it is a choice you make per project, in a config file you had to
trust.*

---

## Budget on this specific machine

128 GB of RAM, one RTX 4090.

- `ramMb` is fixed at create time and editable only while stopped, so a 48 GB forge holds 48 GB from
  power-on to power-off.
- `DRAUGR_MEMORY` defaults to 50% of host RAM capped at 32 GiB, so a mound takes 32. The gateway is
  a mound too, and runs fine on 2 GiB and 2 CPUs (*measured*).
- **The GPU is shared three ways** — your desktop, the forge's editor, and a local model if
  `DRAUGR_MODEL` is set. GPU paravirtualisation does not partition capacity; this is cooperative.
- UE5 plus a project plus a warm DDC is comfortably 250 GB before anything is cooked. Snapshots and
  branches each add their own delta.

A working split: **forge 48 GB, mound 32 GB, gateway 2 GB, host the rest.**

> ### `hddGb` is the one number you cannot take back
> `edit()` accepts `ramMb`, `cpuCores`, `gpuMode` and `networkMode` on a stopped VM. **It does not
> accept `hddGb`**, and the API has no resize anywhere. Undersizing it costs a **full reinstall** —
> Windows, the Launcher, the vault enumeration, the engine. Size generously at create: an oversized
> sparse disk costs disk space; an undersized one costs a day.
>
> Growing the disk file outside AppSandbox and extending the partition in the guest may be possible.
> It is not exposed, not documented and *unmeasured*, so do not plan around it.

---

## Config surface

New keys, following the standing rule that Draugr configures the boundary and never the inside:

```bash
DRAUGR_FORGE=                        # VM name. EMPTY = no forge, feature invisible
DRAUGR_FORGE_DIR=                    # where the clone lives in the guest, e.g. D:\work\MyGame
DRAUGR_FORGE_GATEWAY=                # the gateway repo. EMPTY = the VM has no egress at all
DRAUGR_FORGE_START=auto              # auto|manual|off  — does dr-up start the gateway and the VM?
DRAUGR_FORGE_STOP=auto               # auto|manual|off  — stop when the last user leaves
DRAUGR_FORGE_LINGER=10m              # grace period after the last user, before stopping
DRAUGR_FORGE_SNAPSHOT=               # the baseline rollback returns to. Empty = the base disk
```

No `DRAUGR_FORGE_USER` or `DRAUGR_FORGE_PORT`: `ssh_info()` reports both. Every key needs a
`docs/CONFIG.md` section and a `share/config.example` line or `tests/docs.bats` goes red.

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
| `dr-forge up` | in order: the gateway's `dr-up`, the VM, the tunnel, then a check from inside the guest |
| `dr-forge down` | `shutdown`, then `stop` after a timeout |
| `dr-forge exec <cmd>` | run in the guest, streamed |
| `dr-forge push` / `pull` | the git loop and the file loop, mound ↔ forge |
| `dr-forge base` | stop, take the baseline — **once**, while the snapshot bug stands |
| `dr-forge rollback` | discard the working branch, re-branch from the baseline. Stops the VM. Refuses without confirmation |
| `dr-forge doctor` | every link, each naming its own fix |

**One `dr-up` in the project starts everything, if needed.** That is the requirement: go to the game
project, run `dr-up`, and the gateway, the VM and the tunnel come up first if they are not already
running, in that order, before the agent's mound. It makes the mounds depend on each other at run
time — something Draugr has never had, since every mound so far stood alone — so it is planned on its
own: [run-state dependencies](#run-state-dependencies-to-be-planned).

**`up` and `doctor` exist mostly because of the gateway.** Its liveness chain is long — AppSandbox →
VM → tunnel supervisor → keeper → tinyproxy → gateway — and bringing it back after a reboot is four
ordered steps across two operating systems. That is exactly the kind of recipe `dr-plugin` replaced,
and `doctor` checking each link is the chain's best defence.

House rule 5 generalises: **AppSandbox stays visible.** Every error names the API call that failed, so
the problem is reproducible without Draugr.

### Run-state dependencies (to be planned)

**The requirement:** in the game project, one `dr-up` starts whatever the agent's mound depends on and
is not already running, then the mound itself. Nothing starts twice, and nothing that is running is
restarted.

**The chain, and what each link needs:**

| # | Link | Up when | Brought up by | Known from |
|---|---|---|---|---|
| 1 | AppSandbox daemon | its API answers | **needs elevation** — see below | *measured*: it must run elevated |
| 2 | Gateway mound | `sbx ls` shows it running *and* the post-up probe passes | `dr-up` in `$DRAUGR_FORGE_GATEWAY` | *measured*: idempotent, 1–1.5 min cold, seconds warm |
| 3 | VM | the API reports it running and `sshd` answers | the API | *read* |
| 4 | Tunnel | `ssh.exe -R` holds, supervised by `vm-tunnel.ps1` | a hidden Windows process | *measured*: the pieces; the script whole is not |
| 5 | Preflight | `curl.exe -x http://127.0.0.1:3128 …` in the guest is neither `000` nor `500` | `ssh` into the guest | *measured* |
| 6 | The agent's mound | as today, plus its `localhost:<SshPort>` rule | `dr-up`, as today | — |

Links 2 and 3 are independent and can start in parallel; 4 needs 3; 5 needs 2 and 4.

**Decided (2026-09-20), so the plan starts from these:**

- **Link 1 stays the human's job.** AppSandbox is started by hand, once per host boot, or from the
  user's own startup sequence if that grates. Draugr only **checks** whether the daemon answers, and
  **refuses** to go on when it does not, saying what to start. No Scheduled Task, no elevation, no
  persistent change to the host for a feature most people never turn on.
- **Mound → mound dependencies belong in core**, as an ordinary Draugr feature (a repo's mound can
  require other repos' mounds, brought up in order, idempotently). What stays in `dr-forge` is the
  part that is not a mound at all: the VM, the tunnel and the preflight. The gateway is a mound, so
  core starts it; `dr-forge` only asks whether it answers. That keeps
  [optional by construction](#optional-by-construction) intact: core gains a general mechanism with
  no forge in it, and every forge-shaped step stays behind `DRAUGR_FORGE`.
- **Sharing needs a lock, or it is not offered** — for *this* dependency. A shared gateway or forge
  that two project mounds use at once is not safe, and the plan must make concurrent use impossible
  rather than merely unlikely. But the general mechanism must not impose it: a required mound that
  serves concurrent callers happily, a database being the obvious one, should be shared without a
  lock. So **locking is available and optional, and the dependency declares it**, not the projects
  that use it: exclusivity is a property of the resource, and leaving it to each consumer means one
  careless repo defeats it. Default: shared. The forge's gateway repo opts in; `dr-forge` claims the
  VM the same way, through the same helper, since the VM is not a mound.
- **Stopping is automatic, and counted.** A dependency knows how many projects are using it, and when
  the last one goes away it is released — which also means a single-project setup never has to be
  switched off by hand. The count is what makes both halves safe: it is what an exclusive lock
  enforces at 1, and what a shared dependency uses to know when nobody needs it any more. Release is
  deliberately **late**, never immediate: see question 3.

**Why the lock is not optional.** Two projects pointed at one forge would drive one Windows desktop,
one derived-data cache and one editor at the same time — and one project's `dr-up --recreate` or kit
change cuts the other's egress mid-build. So the second project must be refused, by name, not
warned.

**Questions the plan has to answer:**

1. **How the lock behaves, and how a dependency asks for one.** It lives in core beside the
   dependency mechanism, since any required mound may want it, and it must be:
   - **Off unless asked for**, so requiring a database stays as simple as naming it.
   - **Self-healing**: a lock whose holder's mound is gone is stale, so it is validated against live
     state rather than trusted as a file.
   - **Re-entrant for the same project**, so a second terminal on the same repo is not locked out by
     the first.
   - **Informative**: it names the holder and since when, and refuses rather than waits. Whether
     waiting is ever worth offering is a later question.

   Open within it: whether one claim covers "the forge and its gateway" or each resource is claimed
   separately.
2. **GUI or headless — answered 2026-09-20 *(measured)*.** The API is served by the daemon, not by
   the window, and the mutex allows one of them: with the GUI up there is no `host.json` and no
   socket; with `--headless` there is, and it drove the VM end to end
   ([the API drives the VM](#the-api-drives-the-vm-and-it-is-fast-measured-2026-09-20)). So "start
   AppSandbox yourself" means **start it with `--headless`**, and what the user gives up is
   AppSandbox's management window, not the VM's screen. `dr-forge` can tell the two apart exactly as
   this was measured: `AppSandbox.exe` running with no `host.json` beside it is a GUI instance, and
   the refusal should say so in those words.
3. **How long "nobody is using it" has to last.** The count going to zero must not stop anything at
   once. `dr-up --recreate`, a crash and a retry, or closing one terminal to open another all drop
   the count for a few seconds, and a Windows VM that takes minutes to boot must not fall over
   because of it. So zero starts a **linger timer** and only its expiry stops the dependency; a new
   user inside the window cancels it. The plan has to pick the default (minutes, not seconds, and
   longer for the VM than for a mound), decide whether each dependency sets its own, and say what
   holds the timer — a host-side process, since by then no mound is alive to hold it, and it has to
   survive the case where nothing ever comes back. `DRAUGR_FORGE_STOP=manual` stays for anyone who
   wants the VM up until they say otherwise.
4. **Failure midway.** What `dr-up` does when a dependency will not come up — refuse to start the
   agent, or start it with the forge marked unavailable — and how `dr-forge doctor` reports each link.
5. **Recovery.** A Windows reboot takes down links 1, 2 and 4 (the keeper, the daemon's sessions, the
   tunnel). `dr-up` must be the whole recovery, which is acceptance criterion A5.

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

## Order of work

### Spikes

| | Question | Status |
|---|---|---|
| **S1** | Does the UE5 editor run under GPU-PV, and can a packaged game run? | **Answered: yes** — editor, Lightmass, Play, C++ build. New limit: ray-tracing shaders. Packaged game *unmeasured* |
| **S2** | Can AppSandbox and `sbx` run side by side? | **Answered: yes** — every gateway test ran a mound beside the VM |
| **S3** | How does the mound reach the VM's ssh? | **Answered, differently** — a `localhost:<SshPort>` rule, not `netsh` ([the channel](#the-channel-how-the-mound-reaches-the-forge)) |
| **S4** | Can a `gpuMode=1` VM be snapshotted and branched? | **Blocked by the snapshot bug** — single baseline until it is fixed |
| **S5** | Does UE5 build, cook and package a Windows game with `gpuMode=0`? | Half answered: the C++ build works. Cook and package *unmeasured* |
| **S6** | Can the agent drive the Launcher, the editor and Visual Studio? | **New, and now the main open question** — below |

**S6, in order:** does the accessibility tree see inside the Launcher and the editor (Slate), or only
screenshots do? Does UI automation work on AppSandbox's virtual display with no host viewer
attached? Does the session stay logged in and unlocked, unattended? Which Windows MCP server, given
those answers? Then: does the agent complete *create a project* and *add a Fab asset* end to end?

**S5's known trap:** `-nullrhi` is [reported as not being passed down to the
cooker](https://forums.unrealengine.com/t/failure-when-cooking-on-headless-mac/316805), which is the
classic way a headless cook fails on a machine with no GPU. Cooking on GPU-less build agents is
ordinary practice, so this is configuration rather than a wall — but it is a spike, not an
assumption.

### Tracks

- **A — the gateway, first.** Built, and narrowed ([FORGE-GATEWAY.md](FORGE-GATEWAY.md), steps 1 and
  5): `dr-up` creates it and recovers it after a daemon restart, with no new Draugr code, and it
  denies every `sbx` default the VM did not use. Left: the VM side against the real gateway (steps
  2–3), so that a real tool's traffic has crossed the narrowed gateway.
- **B — Draugr fixes the gateway turned up.** Wrong for every user today, independent of the forge:
  - `dr-go` says the mound is "still running"; `sbx` stops it 30 s after the last session. An opt-in
    keep-alive key would also replace the gateway's hand-written keeper.
  - The kit docs recommend `commands.startup` for services; it stops running after the first reboot.
  - `dr-hostport`, `CONFIG.md` and `SECURITY.md` say a service must listen on `0.0.0.0`; a
    `localhost:<port>` rule reaches Windows loopback. If it also works for the local model,
    `share/ollama-proxy` could listen on loopback only — strictly safer. **This one blocks track C.**
  - `dr-policy --denied` lists the `.docker.internal` echoes as real hosts.
  - `dr-policy --check` is presented as authoritative, but checks names while enforcement is per IP.
  - Wildcard semantics are undocumented: `*.` is one label, `**.` is the apex and any depth, both
    quoted.
  - **`dr-kit apply` has never worked on `sbx` 0.37.1**: it runs `sbx kit add <kit> --sandbox <name>`,
    and `sbx` wants `sbx kit add <name> <kit>` *(measured)*. The test mock accepts any arguments, so
    nothing caught it. Separately, `kit add` appends to the sandbox's kit list, so whether applying
    an *edited* kit can remove a rule is unmeasured; if it cannot, `apply` should rebuild instead.
- **Upstream — the snapshot bug.** Filed: the issue with the analysis,
  [#152](https://github.com/jamesstringer90/appsandbox/issues/152), and a fix built on 0.1.8 with the
  released drivers and tested on a throwaway VM,
  [#153](https://github.com/jamesstringer90/appsandbox/pull/153). Waiting on the author.
- **C — `dr-forge`, after A and the loopback item of B:**
  1. **Vertical slice at `gpuMode=0`**: VM through the API, ssh working, `up`/`down`/`exec`, status.
  2. **The gateway under `up` and `doctor`**, on top of core's mound-to-mound dependencies and the
     lock ([run-state dependencies](#run-state-dependencies-to-be-planned)), which are core work and
     come first.
  3. **The code loop**: `push` and `pull`, reusing the `dr-send` and `dr-data` transports.
  4. **Rollback**, as a single baseline.
  5. **`gpuMode=1`**: the editor, running the game, screenshots back through `pull`.
  6. **The UI**, from whatever S6 found.
  7. **The paperwork**: the conditional `SECURITY.md` section, `CONFIG.md` keys, `config.example`,
     tests against a mock AppSandbox, and the entry in `DESIGN.md`'s standing risks.

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

1. **One forge per project, or one shared by every game project?** UE5 is 100+ GB, so sharing is
   strongly tempting — and it means two projects' agents can read each other's code, which is the
   isolation "one mound, one repo" exists to provide. Recommendation: allow a shared forge, say so
   loudly in `SECURITY.md`, and let `DRAUGR_FORGE` name it per project so the choice is visible.
   **Sharing ships only with the lock** from [run-state
   dependencies](#run-state-dependencies-to-be-planned): sharing one desktop, one cache and one
   editor between two agents at once is not a risk to document, it is one to make impossible.
2. **Which Epic account.** A dedicated one is safest and has its own, empty, Fab library. Your own
   is convenient and puts your library and your account in reach of the agent. See
   [Security](#security).
3. **How much does AppSandbox's youth cost?** The snapshot bug is the first real answer, and the
   author's stance on pull requests is the second: fixes arrive on his schedule. Worth watching
   before building much on top of it.
