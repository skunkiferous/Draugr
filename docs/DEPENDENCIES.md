# Run-state dependencies: one `dr-up` starts what the mound needs

**Status: implemented.** `dr-dep`, the three keys and the integrations below all ship; the tests are
`tests/dep.bats`. This page stays the design document — what was decided and why — and
[the deviations](#what-shipped-differently) records where the implementation disagreed with the
plan. Claims marked *(measured)* or *(read)* are evidence; anything unmarked is still a judgement.

The requirement in one line: **in a project, `dr-up` brings up whatever that project's mound depends
on and is not already running, then the mound itself.** Nothing starts twice, nothing running is
restarted, and the last project to leave turns the lights off.

---

## What this is, and what it is not

This is a **run-state** dependency: repository A's mound needs repository B's mound to be *running*.
It is not any of these, which are decided elsewhere and stay decided:

> **Two words, because both things are virtual machines.** A **mound** is the `sbx` microVM an agent
> lives in. The **forge** is the Windows machine AppSandbox runs, which `docs/FORGE.md` is about.
> Neither is called "the VM" here: this mechanism is about mounds, and the forge is only its first
> and most demanding consumer.

- **Not multi-repo mounds.** One repository per sandbox, still
  ([DESIGN.md](DESIGN.md#deliberately-not-in-v1)). Two mounds that depend on each other are two
  mounds.
- **Not a build graph.** Nothing is compiled, nothing is cached, and there is no "out of date". The
  only question ever asked is *is it up, and is it ready*.
- **Not a service manager.** No supervision tree, no restart policy, no daemon that owns the
  machine. What exists between commands is one short-lived process per running dependency, and its
  death is survivable — see [the warden](#counting-the-linger-and-the-warden).
- **Not the forge.** The forge is the case that forced this, and it is the first consumer, but
  nothing in this document knows what a forge is. The forge-shaped parts stay in `dr-forge`.

---

## The case that forced it

From [FORGE.md](FORGE.md#run-state-dependencies-planned-separately): working on a game in the forge means six
links have to be up before the agent can do anything.

| # | Link | Up when | Whose job |
|---|---|---|---|
| 1 | AppSandbox daemon | its API answers | **the human**, once per boot — *decided, see below* |
| 2 | Gateway mound | `dr-up` in its repo returns and its post-up probe passed | **core**, this plan |
| 3 | Forge VM | the API reports it online and `sshd` answers | `dr-forge` |
| 4 | Tunnel | `vm-tunnel.ps1` holds the reverse forward | `dr-forge` |
| 5 | Preflight | the guest's request through the proxy is neither `000` nor `500` | `dr-forge` |
| 6 | The agent's mound | as today | `dr-up`, as today |

Only link 2 is a mound. That is the whole reason this plan is small: **core learns one thing — "this
repo needs that repo's mound running" — and everything else the forge needs stays in `dr-forge`,
built on the same claim helper.**

---

## Decided already (2026-09-20)

These came from the user and are not reopened here.

- **Elevation stays manual.** AppSandbox is started by hand once per host boot, with `--headless` if
  anything is to drive it *(measured: the GUI serves no API)*. Draugr checks and refuses; it never
  elevates, installs a Scheduled Task, or changes the host for a feature most people never enable.
- **The mechanism belongs in core**, as an ordinary Draugr feature, with the non-mound parts (the
  forge VM, tunnel, preflight) in `dr-forge`.
- **The lock is available, optional, and declared by the dependency** — not by the projects that use
  it. Exclusivity is a property of the resource: a gateway fronting one desktop is exclusive, a
  queueing database is not. Leaving the declaration to each consumer means one careless repository
  defeats it. Default: shared.
- **Stopping is automatic and counted**, with a **linger** so that a `dr-up --recreate`, a crash and
  a retry, or a terminal closed and reopened do not tear down something that takes minutes to come
  back.

---

## The model

Four nouns. Everything else follows from them.

| Noun | What it is |
|---|---|
| **Resource** | something that must be running: a mound, or — for `dr-forge` — the forge VM. Identified by a key: the sandbox name for a mound, `vm:<name>` for a forge |
| **Claimant** | a repository that needs it. Always a repository, never a person or a process |
| **Claim** | a file recording that a claimant needs a resource, since when |
| **Warden** | one process per running dependency that keeps it alive and, when the last claim goes, lets it go |

### Claims, and what makes one valid

A claim lives in `${XDG_STATE_HOME:-$HOME/.local/state}/draugr/run/<resource-key>/`, one file per
claimant, named after a hash of the claimant's repository path, holding the path itself, the
claimant's sandbox name, and a timestamp.

**A claim is not trusted because it exists.** It is valid only if the claimant is still real:

```text
valid(claim) = sandbox(claim) is running        # the ordinary case
             OR claim is younger than 5 minutes # the window between claiming and starting
```

That is what makes the whole thing self-healing, and it is why claims are keyed by repository rather
than by process id. A host that reboots wakes with every claim stale, because no sandbox is running;
a crashed `dr-up` leaves a claim that ages out; a mound stopped by hand releases its claim by the
act of stopping. Nothing has to be cleaned up, and no file is ever authoritative on its own.

The five-minute grace exists for one real window: a consumer claims *before* its own mound is
running, because the dependency has to be up first. Without the grace, its claim would read as
invalid for the minute its own mound takes to build, and a second project could walk through an
exclusive lock.

### The lock is a claim that refuses company

An exclusive resource is one whose `.draugr.conf` says `DRAUGR_EXCLUSIVE=true`. For those, the claim
directory is created with `mkdir`, which is atomic, and a second claimant is **refused by name**:

```text
dr-up: draugr-gateway is exclusive, and /home/you/code/TabuLua has been using it since 14:02
  Its own config says DRAUGR_EXCLUSIVE=true, so one project at a time.
  Stop that project's mound, or release it there:  dr-dep release
```

Four properties, all of them from the decision above:

- **Off unless asked for**, so requiring a database stays as simple as naming it.
- **Self-healing**: a lock whose holder is invalid is taken over, once, rather than waiting for a
  human to delete a file.
- **Re-entrant for the same repository**, so a second terminal in the same project is not locked out
  by the first. The claim is per repository, not per shell.
- **Informative, and it refuses rather than waits.** Waiting hides a queue; refusing names a holder.

Each resource is claimed **separately** — a forge project holds one claim on the gateway and one on
the forge VM — because their lifetimes differ: the gateway can serve while the forge is off, and one
claim covering both would make the shorter-lived one hostage to the longer.

### Counting, the linger, and the warden

A shared resource counts its valid claims. When the count reaches zero, nothing happens *yet*: zero
starts the linger, and only its expiry stops anything. Any new claim inside the window cancels it.

The counting is done by the **warden**, one bash process per running dependency, started by the
`dr-up` that started the dependency:

1. It ensures a **keeper** session exists, because *(measured, sbx 0.37.1)* sbx stops a sandbox 30 s
   after its last session, and traffic through a published port is not a session. The keeper is a
   detached `sbx exec <name> sleep infinity`, the same trick
   `draugr-gateway/.draugr/hooks/post-up` uses today — started from WSL rather than through
   PowerShell, see [what shipped differently](#what-shipped-differently).
2. Every 60 s it counts valid claims. Non-zero: nothing to do. Zero: note when zero began.
3. When zero has lasted `DRAUGR_LINGER`, it kills the keeper, stops the mound, and exits.

**The gateway's post-up keeper becomes core's dependency keeper**, and that hook loses a job. A
mound that an agent attaches to does not need a keeper — the session is the keeper — which is why
this is a dependency behaviour rather than a `dr-up` behaviour.

Two deaths are worth naming, because both are safe in the same direction:

- **The warden dies** (WSL shuts down on idle, the terminal is killed): the keeper is a Windows
  process and survives, so the dependency **stays up**. The next `dr-up` re-arms a warden.
- **The keeper dies** (a reboot, `sbx daemon` restart): the dependency stops within 30 s, and the
  next `dr-up` brings it back — *measured 2026-09-20: 65 s for the gateway, with rules intact*.

The failure direction is always "something stayed up that could have stopped", never "something
stopped while in use".

### Bringing a dependency up is just `dr-up` in the other repository

No new bring-up protocol, no health-check key, no readiness DSL. Core runs `dr-up` in the
dependency's repository and lets it do exactly what it does for a human:

- it is **idempotent** — absent creates, stopped starts, running says so;
- it runs that repository's **`post-up` hook**, which is where a dependency's readiness check
  already lives. The gateway's hook starts tinyproxy and then probes the whole path before it
  returns *(measured)*. A hook that fails fails the dependency, and therefore the `dr-up` that
  needed it.

So "ready" means "that repository's own `dr-up` returned 0". Nothing else is defined, and nothing
else has to be.

---

## Config surface

Two keys on the dependency, one on the consumer. Empty by default, so the feature is invisible to
every repository that does not use it — the rule the forge follows
([FORGE.md](FORGE.md#optional-by-construction)).

```bash
# In the CONSUMER's .draugr.conf - what this project needs running.
DRAUGR_REQUIRES=                     # space-separated repo paths. EMPTY = no dependencies

# In the DEPENDENCY's .draugr.conf - what kind of resource this repo's mound is.
DRAUGR_EXCLUSIVE=false               # true = one claimant at a time, refused by name
DRAUGR_LINGER=10m                    # idle time before the last user's exit stops it; off = never
```

- **Paths, not names.** `DRAUGR_REQUIRES=~/code/draugr-gateway` names a repository, because a
  repository is the only thing `dr-up` can bring up. Resolution follows `DRAUGR_KIT`'s habit:
  absolute, `~`-relative, or relative to this repository.
- **`DRAUGR_LINGER` only applies to a mound that is up as a dependency.** A mound you started
  yourself is yours until you stop it; nothing about today's behaviour changes.
- **`10m` rather than `off` as the default**, because the point of counting is that a single-project
  setup never has to switch anything off by hand. Minutes rather than seconds because the resource
  this was designed for takes minutes to boot.
- **Deliberately not keys**: a start timeout, a retry count, a parallel-start switch, a "wait for the
  lock" flag. Each is a guess until something measured asks for it; see [open
  questions](#open-questions).

---

## `dr-dep`

One more `dr-<one word>` command, in the shape every other one has
([HACKING.md](HACKING.md#the-shape-of-every-command)). `status` is the default because it moves
nothing.

| Command | Mound? | What it does |
|---|---|---|
| `dr-dep` (= `status`) | no | what this repo requires, each resource's state, and who else holds a claim |
| `dr-dep up` | yes | bring the chain up without starting this repo's mound — what `dr-up` calls |
| `dr-dep release` | no | drop this repo's claims now, starting the linger |
| `dr-dep claim <key> [--exclusive]` | no | the helper `dr-forge` uses for the forge VM, which is not a mound |
| `dr-dep unclaim <key>` | no | its opposite |
| `dr-dep warden <key>` | no | internal: the loop above, started detached by `dr-dep up` |

`dr-dep claim` is what keeps the forge honest: the forge VM is claimed through the same code, with the same
validity rule and the same refusal text, so "exclusive" means one thing on this machine rather than
two.

### What changes in the commands that exist

| Command | Change |
|---|---|
| `dr-up` | before its own work, and before `--recreate` destroys anything: resolve `DRAUGR_REQUIRES`, bring each up in order, claim each. `--skip-deps` is the escape hatch. Refuses if one will not come up |
| `dr-stop` | after stopping this repo's mound, release its claims, so the linger starts when you left rather than at the next tick |
| `dr-rm` | the same, after removal — a destroyed mound is the one case where nobody is coming back |
| `dr-go` | releases too, but only when `DRAUGR_STOP_ON_EXIT` actually stopped the mound |
| `dr-status` | a line per dependency: its mound and that mound's state, or that its config is untrusted |
| `dr-doctor` | each declared path exists, is a repository and is trusted; plus claims this repo still holds on things it no longer requires |
| `dr-ls` | **unchanged.** It lists what sbx knows, and a dependency is a mound like any other; `dr-dep` is where the relationships live |

---

## Security

A dependency is **code execution**, and the plan has to say so plainly.

Requiring a repository means Draugr will source its `.draugr.conf` and run its `pre-up`,
`post-create` and `post-up` hooks, on your machine, as you. That is the same exposure `dr-trust`
exists for, so it is the same answer:

- **Every dependency's config and hooks must be trusted**, by the existing mechanism, before its
  `dr-up` runs. `dr_trust_check` already refuses to source an untrusted config — but it refuses by
  *warning and carrying on with defaults*, and a default `DRAUGR_SANDBOX` is `draugr-<leaf>`, which
  would silently claim and start **the wrong mound**. So the dependency path must check trust
  explicitly and `dr_die` on it, rather than inheriting the warn-and-continue behaviour.
- **`dr-trust` output names the dependency**, so "you are about to trust code in another repository
  because this one requires it" is visible at the moment it is decided, not later.
- **A cycle is refused**, naming the loop. The chain of repositories is carried down the recursion in
  one variable and checked at each step.
- **No claim is authority.** A claim file says who *wants* a resource; it never grants access to
  anything. The gateway's allowlist, the mound's policy and the forge's tunnel are unchanged by any of
  this — a claim cannot open a host or a port.
- **House rule 7** — *"nothing is written outside the repo, `~/.config/draugr`, and
  `$DRAUGR_MEM_STORE`"* — is **amended by this plan** to add
  `${XDG_STATE_HOME:-$HOME/.local/state}/draugr`. Run-state is not configuration: it is deleted
  freely, never backed up, and meaningless on another machine. Putting it in the config directory
  would make `~/.config/draugr` unsafe to copy. The amendment lands in
  [HACKING.md](HACKING.md#house-rules) in the same change, as rule 8 requires.

---

## Failure modes, and what each one does

| Situation | What happens |
|---|---|
| A required path does not exist, or is not a git repository | `dr-up` refuses, naming the path and the config line that asked for it |
| Its config or a hook is untrusted | refuses, naming `dr-trust <file>` |
| Its `dr-up` fails (create fails, `post-up` probe fails) | refuses, printing that repository's own error. `--skip-deps` starts this mound alone |
| It is exclusive and someone else holds it | refuses, naming the holder and since when |
| A cycle: A requires B requires A | refuses, printing the cycle |
| The host rebooted | every claim is stale by the validity rule; the first `dr-up` rebuilds the chain — this is acceptance criterion A5 of [FORGE-GATEWAY.md](FORGE-GATEWAY.md#step-6-acceptance-criteria) |
| The warden was killed | the dependency stays up; the next `dr-up` re-arms one |
| A consumer's mound is stopped by sbx's own 30 s timer | its claim becomes invalid at the next warden tick; the linger then runs normally |
| Two `dr-up`s race for an exclusive resource | `mkdir` decides; the loser is refused by name |

The pattern behind the table: **refusing is the default, and every refusal names the command that
resolves it** — house rules 2 and 4.

---

## What the forge adds on top

Nothing in core knows about VMs, so `dr-forge` keeps exactly the parts that are not mounds:

| Link | Where it lives |
|---|---|
| AppSandbox daemon running (1) | `dr-forge`, as a **check that refuses** — never a start |
| Gateway mound (2) | core: `DRAUGR_REQUIRES=<gateway repo>` in the project |
| Forge VM (3) | `dr-forge`, which claims `vm:<name>` through `dr-dep claim --exclusive` |
| Tunnel (4) and preflight (5) | `dr-forge`, after the forge is online |
| The agent's mound (6) | `dr-up`, as today |

So the forge's contribution shrinks to: check the daemon, claim the forge, start it, hold the tunnel,
probe the guest. `DRAUGR_FORGE_STOP` and `DRAUGR_FORGE_LINGER` become thin wrappers over the core
behaviour rather than their own machinery.

---

## Order of work

Each phase is useful on its own and testable before the next begins.

| Phase | What ships | State |
|---|---|---|
| 1 | Claims: the directory, the validity rule, `dr-dep status`, `dr-dep claim/unclaim` | **done** |
| 2 | `dr-dep up` and the `dr-up` integration, without stopping anything | **done**, with `--skip-deps` |
| 3 | Exclusivity: `DRAUGR_EXCLUSIVE`, the atomic claim, the refusal text | **done** |
| 4 | The warden: keeper, counting, `DRAUGR_LINGER`, stop | **done** |
| 5 | `dr-stop`/`dr-rm`/`dr-status`/`dr-doctor` | **done**. `dr-ls` was left alone: it lists what sbx knows, and a dependency is a mound like any other |
| 6 | `dr-forge` moves its forge claim onto `dr-dep claim` | waiting on `dr-forge`, which does not exist yet |

**Testing.** Everything through the existing `sbx` mock
([HACKING.md](HACKING.md#pattern-mocking-sbx-and-ssh)), which needs one addition: per-sandbox state,
so that "running" and "stopped" can differ between two named mounds in one test. Two rules from the
testing strategy bite here and must be respected rather than worked around: a test that passes for
the wrong reason is worse than none — so the claim tests assert the *argv* and the file contents,
not a call count, which is exactly the hole that hid the `dr-kit apply` bug — and no real sleeping:
the linger and the poll interval are injectable, and the warden is driven one tick at a time.

---

## Acceptance criteria

| # | Criterion | State |
|---|---|---|
| B1 | One `dr-up` brings up a chain | **measured against real `sbx`, 2026-09-20**: from everything stopped, `dr-dep up` in a repo requiring `draugr-gateway` had it running and claimed in 68 s. Also tested through the mock |
| B2 | Idempotent | covered by `dr-up`'s own idempotence, which predates this; the second run above started nothing |
| B3 | Order | **tested**: the claim exists, and the dependency is up, before this repo's mound is created |
| B4 | Readiness is the dependency's own | **measured**: the gateway's `post-up` ran and probed (`gateway answers -> 403`) before `dr-dep up` returned. A hook that fails fails the consumer's `dr-up` |
| B5 | Shared by default | **tested** |
| B6 | Exclusive refuses by name and since-when | **tested**, twice: at the helper and through `dr-up` |
| B7 | Re-entrant | **tested** |
| B8 | Self-healing | **tested**: a lock whose holder is stopped is taken over |
| B9 | Counted stop | **measured against real `sbx`**: with the claim released, a warden tick past the linger killed the keeper and left the mound `stopped`. Tested tick by tick through the mock |
| B10 | Linger cancels | **tested**: a claim during the window leaves it alone |
| B11 | Reboot recovery | **unmeasured**. It is the gateway plan's A5 and needs a real reboot |
| B12 | Untrusted refuses | **measured**: an untrusted dependency stopped `dr-dep` before it read anything. `dr-doctor` and `dr-dep status` both report it |

---

## What shipped differently

Three places where building it disagreed with planning it. Each is a decision, not an oversight.

- **The keeper is started from WSL, not through PowerShell.** The plan copied the gateway's `post-up`
  hook, which starts a hidden Windows-side `sbx.exe exec … sleep infinity` so that the session
  survives a WSL restart. Core does not call `powershell.exe` anywhere, and adding that dependency
  for one detail was the larger cost, so the warden starts the keeper with `setsid` and owns it. The
  consequence is honest and small: `wsl --shutdown` now stops dependencies instead of orphaning them,
  which is closer to what "shut down WSL" ought to mean.
- **A detached process must close what it inherited.** Redirecting stdin, stdout and stderr is not
  enough: under `bats` the warden inherited the test runner's pipe on fd 3 and held the whole run
  open after every test had passed. The warden now closes every descriptor above stdio, and
  [HACKING.md](HACKING.md#pattern-a-process-that-outlives-the-command-that-started-it) carries the
  pattern, since it will apply to the next long-lived helper too.
- **The claim records its own key.** The directory name is sanitised (`vm:UE5-Test` becomes
  `vm_UE5-Test`), which cannot be reversed, and `dr-doctor` needs the original to tell a mound from
  a resource that is not one. It is a field in the claim file rather than a second lookup table.
- **A warden that dies young now says so.** The first detached warden of the end-to-end run died
  before writing its pid file, leaving an empty log and no evidence at all; the retry worked and the
  cause is still unknown. So the warden writes its pid and a start line *first*, and `dr-dep up`
  checks a second later that it is really there — because a missing warden means no keeper, and
  sbx stops an idle mound 30 s after that.

**Not deviations, but worth stating:** the grace period is five minutes and the poll interval sixty
seconds, both overridable through `DR_DEP_GRACE` and `DR_DEP_POLL` so that tests never sleep; and the
warden is driven one tick at a time with `--once`, which is how the linger is tested without wall
clock time.

---

## Rejected alternatives

- **A daemon that owns the dependencies.** It would answer every question here cleanly and it is the
  wrong shape for a tool whose whole premise is scripts you can read. The warden is a loop that can
  die without consequence; a daemon is something to install, supervise and explain.
- **Refcounts inside `sbx`.** There is no such feature, and `sbx kit`/`sbx settings` are already
  flagged as standing risks ([DESIGN.md](DESIGN.md#standing-risks)). Building lifecycle on an
  undocumented surface would add a third.
- **Reading the dependency's `.draugr.conf` directly** to learn its sandbox name. It is shell code;
  sourcing it is the trust decision, and half-parsing it with `grep` would be a second, worse config
  reader. `dr-config KEY` in that directory already answers, with that repository's own trust check.
- **A claim per process rather than per repository.** It makes the lock non-re-entrant — a second
  terminal in the same project would be refused — and turns validity into pid-liveness, which lies
  after a reboot.
- **Waiting for an exclusive claim instead of refusing.** A queue with no visible position is worse
  than a refusal that names a holder. It can be added later; it cannot be removed later.

---

## Open questions

1. **Parallel start.** Links 2 and 3 are independent, and a cold gateway takes 60–90 s *(measured)*.
   Sequential is simpler and predictable; parallel is faster and harder to report. Worth measuring
   the real cost before choosing.
2. **A start timeout.** A dependency whose `dr-up` hangs hangs the consumer. Today's answer is
   Ctrl-C. Whether a timeout is better than a visible "still creating draugr-gateway (90 s)" is
   unmeasured.
3. **Whether the linger should differ per resource kind.** A forge that takes three minutes to boot and
   a database that takes two seconds arguably want different defaults, and one key cannot say so.
4. **Whether `dr-go` should hold a claim of its own**, so that an attached session keeps a dependency
   alive even when the mound would otherwise look idle. Probably unnecessary — an attached session is
   a running mound — but it is the kind of thing that only shows up in use.
5. **Cross-user or cross-machine claims.** Out of scope: the state directory is per user, and a
   second user on the same host would not see the first's claims. Naming it here so it is a decision
   rather than an oversight.
