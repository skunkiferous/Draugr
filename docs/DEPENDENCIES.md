# Run-state dependencies: one `dr-up` starts what the mound needs

**Status: implemented.** `dr-dep`, the three keys and the integrations below all exist. The tests
are in `tests/dep.bats`. This page stays the design document: what we decided, and why.
[The deviations](#what-shipped-differently) record where the code is different from the plan.
Claims marked *(measured)* or *(read)* are evidence. Claims with no mark are still a judgement.

The requirement in one line: **in a project, `dr-up` starts each mound that the mound of the
project needs and that does not run yet, then the mound itself.** Nothing starts two times, nothing
that runs restarts, and the last project to leave turns off the lights.

---

## What this is, and what it is not

This is a **run-state** dependency: the mound of repository A needs the mound of repository B to be
*running*. It is none of the following. Other places decide those, and those decisions stay:

> **Two words, because both things are virtual machines.** A **mound** is the `sbx` microVM where an
> agent lives. The **forge** is the Windows machine that AppSandbox runs, and `docs/FORGE.md` is
> about it. Neither is "the VM" here. This mechanism is about mounds, and the forge is only its
> first and most difficult consumer.

- **Not multi-repo mounds.** Still one repository for each sandbox
  ([DESIGN.md](DESIGN.md#deliberately-not-in-v1)). Two mounds that depend on each other are two
  mounds.
- **Not a build graph.** Nothing is compiled, nothing is cached, and there is no "out of date". The
  only question is *is it up, and is it ready*.
- **Not a service manager.** No supervision tree, no restart policy, no daemon that owns the
  machine. Between commands, there is one short-lived process for each running dependency, and its
  death causes no damage. Refer to [the warden](#counting-the-linger-and-the-warden).
- **Not the forge.** The forge is the case that made this necessary, and it is the first consumer.
  But nothing in this document knows what a forge is. The forge parts stay in `dr-forge`.

---

## The case that forced it

From [FORGE.md](FORGE.md#run-state-dependencies-planned-separately): for work on a game in the
forge, six links must be up before the agent can do anything.

| # | Link | Up when | Whose job |
|---|---|---|---|
| 1 | AppSandbox daemon | its API answers | **the human**, once for each boot: *decided, refer to the next section* |
| 2 | Gateway mound | `dr-up` in its repo returns, and its post-up probe passed | **core**, this plan |
| 3 | Forge VM | the API reports it online, and `sshd` answers | `dr-forge` |
| 4 | Tunnel | `vm-tunnel.ps1` holds the reverse forward | `dr-forge` |
| 5 | Preflight | the request of the guest through the proxy is neither `000` nor `500` | `dr-forge` |
| 6 | The mound of the agent | as today | `dr-up`, as today |

Only link 2 is a mound. That is the full reason why this plan is small. **Core learns one thing,
"this repo needs the mound of that repo to run". All else that the forge needs stays in `dr-forge`,
built on the same claim helper.**

---

## Decided already

These came from the user, and this page does not open them again.

- **Elevation stays manual.** You start AppSandbox by hand once for each host boot, with
  `--headless` if something must control it *(measured: the GUI serves no API)*. Draugr tests and
  refuses. It never elevates, installs a Scheduled Task, or changes the host for a feature that most
  people never enable.
- **The mechanism belongs in core**, as a normal Draugr feature. The parts that are not mounds (the
  forge VM, tunnel, preflight) are in `dr-forge`.
- **The lock is available and optional, and the dependency declares it**, not the projects that use
  it. Exclusivity belongs to the resource. A gateway in front of one desktop is exclusive. A database
  that queues its callers is not. If each consumer declares it, one careless repository defeats it.
  Default: shared.
- **Draugr stops a dependency automatically, by count**, with a **linger**. Thus a
  `dr-up --recreate`, a crash and a retry, or a terminal closed and opened again do not stop
  something that takes minutes to come back.

---

## The model

Four nouns. All else follows from them.

| Noun | What it is |
|---|---|
| **Resource** | something that must run: a mound, or, for `dr-forge`, the forge VM. A key identifies it: the sandbox name for a mound, `vm:<name>` for a forge |
| **Claimant** | a repository that needs it. Always a repository, never a person or a process |
| **Claim** | a file that records that a claimant needs a resource, and since when |
| **Warden** | one process for each running dependency. It keeps the dependency alive, and lets it go when the last claim goes |

### Claims, and what makes one valid

A claim is in `${XDG_STATE_HOME:-$HOME/.local/state}/draugr/run/<resource-key>/`. There is one file
for each claimant, named after a hash of the repository path of the claimant. It holds the path
itself, the sandbox name of the claimant, and a timestamp.

**Draugr does not trust a claim only because it exists.** It is valid only if the claimant is still
real:

```text
valid(claim) = sandbox(claim) is running        # the ordinary case
             OR claim is younger than 5 minutes # the window between claiming and starting
```

That makes the full mechanism repair itself. It is also why the key of a claim is the repository,
not the process id. After a host reboot, each claim is old, because no sandbox runs. A crashed
`dr-up` leaves a claim that becomes old. A mound that you stop by hand releases its claim by the
stop. Nothing needs a clean-up, and no file alone is the authority.

The five-minute grace exists for one real window. A consumer claims *before* its own mound runs,
because the dependency must be up first. Without the grace, its claim is invalid while its own
mound builds. During that minute, a second project can get past an exclusive lock.

### The lock is a claim that refuses company

An exclusive resource is one whose `.draugr.conf` says `DRAUGR_EXCLUSIVE=true`. For those, Draugr
creates the claim directory with `mkdir`, which is atomic. It **refuses a second claimant by name**:

```text
dr-up: draugr-gateway is exclusive, and /home/you/code/TabuLua uses it since 14:02
  Its own configuration says DRAUGR_EXCLUSIVE=true, so only one project at a time can use it.
  Stop the mound of that project, or release it there:  dr-dep release
```

Four properties, all from the decision above:

- **Off unless you ask for it**, so a dependency on a database stays as simple as its name.
- **It repairs itself.** Draugr takes over a lock whose holder is invalid, once. It does not wait
  for a human to delete a file.
- **Re-entrant for the same repository.** The first terminal in a project does not lock out a
  second terminal in the same project. The claim is for each repository, not for each shell.
- **It informs, and it refuses, and does not wait.** A wait hides a queue. A refusal names a holder.

Draugr claims each resource **separately**. A forge project holds one claim on the gateway, and one
on the forge VM, because their lifetimes are different. The gateway can serve while the forge is
off. With one claim for both, the shorter-lived one depends on the longer-lived one.

### Counting, the linger, and the warden

A shared resource counts its valid claims. When the count is zero, nothing happens *yet*. Zero
starts the linger, and only its end stops anything. A new claim inside the window cancels it.

The **warden** does the count. It is one bash process for each running dependency, started by the
`dr-up` that started the dependency:

1. It makes sure that a **keeper** session exists. *(Measured, sbx 0.37.1)*: sbx stops a sandbox
   30 s after its last session, and traffic through a published port is not a session. The keeper
   is a detached `sbx exec <name> sleep infinity`, the same trick that
   `draugr-gateway/.draugr/hooks/post-up` uses today. It starts from WSL, not through PowerShell.
   Refer to [what shipped differently](#what-shipped-differently).
2. Each 60 s, it counts valid claims. Not zero: nothing to do. Zero: note when zero started.
3. When zero lasted `DRAUGR_LINGER`, it kills the keeper, stops the mound, and exits.

**Core keeps a dependency up, so a hook does not need to.** A mound where an agent attaches needs
no keeper, because the session is the keeper. That is why this is a behavior of dependencies, not of
`dr-up`. But it covers only a mound started *as* a dependency. A plain `dr-up` in the own repository
of the dependency starts no warden. Thus a repository that you also start by hand keeps its own
keeper. The `post-up` hook of `draugr-gateway` is exactly that case. Two keepers cost nothing and
never fight. The warden kills only the keeper in its own `keeper.pid`, and the next `sbx stop` ends
all sessions anyway.

Two deaths are important, because both are safe in the same direction:

- **The warden dies** (WSL shuts down when idle, or the terminal is killed). The keeper is a Windows
  process and stays, so the dependency **stays up**. The next `dr-up` starts a new warden.
- **The keeper dies** (a reboot, or a restart of `sbx daemon`). The dependency stops within 30 s,
  and the next `dr-up` brings it back. *Measured: 65 s for the gateway, with the rules intact*.

The failure is always "something stayed up that was safe to stop", never "something stopped while in
use".

### Bringing a dependency up is just `dr-up` in the other repository

No new start protocol, no health-check key, no readiness language. Core runs `dr-up` in the
repository of the dependency, and lets it do exactly what it does for a human:

- It is **idempotent**: absent creates, stopped starts, running says so.
- It runs the **`post-up` hook** of that repository, which already holds the readiness test of the
  dependency. The hook of the gateway starts tinyproxy, then probes the full path before it returns
  *(measured)*. A hook that fails makes the dependency fail, and thus the `dr-up` that needed it.

Thus "ready" means "the own `dr-up` of that repository returned 0". Nothing else is defined, and
nothing else needs to be.

---

## Config surface

Two keys on the dependency, one on the consumer. Empty by default. Thus a repository that does not
use the feature does not see it. The forge follows the same rule
([FORGE.md](FORGE.md#optional-by-construction)).

```bash
# In the CONSUMER's .draugr.conf - what this project needs running.
DRAUGR_REQUIRES=                     # space-separated repo paths. EMPTY = no dependencies

# In the DEPENDENCY's .draugr.conf - what kind of resource this repo's mound is.
DRAUGR_EXCLUSIVE=false               # true = one claimant at a time, refused by name
DRAUGR_LINGER=10m                    # idle time before the last user's exit stops it; off = never
```

- **Paths, not names.** `DRAUGR_REQUIRES=~/code/draugr-gateway` names a repository, because `dr-up`
  can start only a repository. The resolution follows that of `DRAUGR_KIT`: absolute, relative to
  `~`, or relative to this repository.
- **`DRAUGR_LINGER` applies only to a mound that is up as a dependency.** A mound that you started
  yourself is yours until you stop it. Nothing about the current behavior changes.
- **`10m`, not `off`, as the default.** The purpose of the count is that a setup with one project
  never needs a manual stop. Minutes, not seconds, because the resource for this design takes
  minutes to boot.
- **On purpose, these are not keys**: a start timeout, a retry count, a parallel-start switch, a
  "wait for the lock" flag. Each one is a guess until a measurement asks for it. Refer to [open
  questions](#open-questions).

---

## `dr-dep`

One more `dr-<one word>` command, with the same shape as all the others
([HACKING.md](HACKING.md#the-shape-of-every-command)). `status` is the default, because it moves
nothing.

| Command | Mound? | What it does |
|---|---|---|
| `dr-dep` (= `status`) | no | what this repo requires, the state of each resource, and who else holds a claim |
| `dr-dep up` | yes | start the chain, but not the mound of this repo. `dr-up` calls this |
| `dr-dep release` | no | drop the claims of this repo now, and start the linger |
| `dr-dep claim <key> [--exclusive]` | no | the helper that `dr-forge` uses for the forge VM, which is not a mound |
| `dr-dep unclaim <key>` | no | its opposite |
| `dr-dep warden <key>` | no | internal: the loop above, started detached by `dr-dep up` |

`dr-dep claim` keeps the forge honest. The forge VM is claimed through the same code, with the same
validity rule and the same refusal text. Thus "exclusive" means one thing on this machine, not two.

### What changes in the commands that exist

| Command | Change |
|---|---|
| `dr-up` | before its own work, and before `--recreate` destroys anything: resolve `DRAUGR_REQUIRES`, start each in order, claim each. `--skip-deps` is the way out. Refuses if one does not come up |
| `dr-stop` | after the stop of the mound of this repo, release its claims. Thus the linger starts when you left, not at the next tick |
| `dr-rm` | the same, after removal. A destroyed mound is the one case where nobody comes back |
| `dr-go` | also releases, but only when `DRAUGR_STOP_ON_EXIT` really stopped the mound |
| `dr-status` | a line for each dependency: its mound and the state of that mound, or that its configuration is not trusted |
| `dr-doctor` | each declared path exists, is a repository, and is trusted. Also claims that this repo still holds on things that it does not require now |
| `dr-ls` | **unchanged.** It lists what sbx knows, and a dependency is a mound as all others are. `dr-dep` holds the relationships |

---

## Security

A dependency is **code execution**, and the plan must say so clearly.

If you require a repository, Draugr sources its `.draugr.conf`, and runs its `pre-up`,
`post-create` and `post-up` hooks, on your machine, as you. That is the same exposure as the one
`dr-trust` exists for. Thus it is the same answer:

- **The configuration and hooks of each dependency must be trusted**, by the existing mechanism,
  before its `dr-up` runs. `dr_trust_check` already refuses to source a configuration that is not
  trusted. But it refuses with *a warning, and continues with defaults*. A default `DRAUGR_SANDBOX`
  is `draugr-<leaf>`, which silently claims and starts **the wrong mound**. Thus the dependency
  path must test trust explicitly, and `dr_die` on it. It must not keep the warn-and-continue
  behavior.
- **The output of `dr-trust` names the dependency.** Thus "you will trust code in another repository,
  because this one requires it" is visible at the time of the decision, not later.
- **Draugr refuses a cycle**, and names the loop. One variable carries the chain of repositories down
  the recursion, and Draugr tests it at each step.
- **No claim is authority.** A claim file says who *wants* a resource. It never gives access to
  anything. None of this changes the allowlist of the gateway, the policy of the mound, or the
  tunnel of the forge. A claim cannot open a host or a port.
- **House rule 7**, *"nothing is written outside the repo, `~/.config/draugr`, and
  `$DRAUGR_MEM_STORE`"*, **changes with this plan**, to add
  `${XDG_STATE_HOME:-$HOME/.local/state}/draugr`. Run-state is not configuration. You can delete it
  freely, never back it up, and it means nothing on a different machine. In the configuration
  directory, it makes `~/.config/draugr` unsafe to copy. The change goes into
  [HACKING.md](HACKING.md#house-rules) in the same commit, as rule 8 requires.

---

## Failure modes, and what each one does

| Situation | What happens |
|---|---|
| A required path does not exist, or is not a git repository | `dr-up` refuses, and names the path and the configuration line that asked for it |
| Its configuration or a hook is not trusted | refuses, and names `dr-trust <file>` |
| Its `dr-up` fails (create fails, `post-up` probe fails) | refuses, and prints the own error of that repository. `--skip-deps` starts only this mound |
| It is exclusive, and somebody else holds it | refuses, and names the holder and since when |
| A cycle: A requires B requires A | refuses, and prints the cycle |
| The host rebooted | the validity rule makes each claim old. The first `dr-up` builds the chain again |
| The warden was killed | the dependency stays up. The next `dr-up` starts a new one |
| The own 30 s timer of sbx stops the mound of a consumer | its claim becomes invalid at the next warden tick. The linger then runs normally |
| Two `dr-up`s race for an exclusive resource | `mkdir` decides. Draugr refuses the loser by name |

The rule behind the table: **the default is a refusal, and each refusal names the command that
fixes it.** That is house rules 2 and 4.

---

## What the forge adds on top

Nothing in core knows about VMs. Thus `dr-forge` keeps exactly the parts that are not mounds:

| Link | Where it lives |
|---|---|
| AppSandbox daemon running (1) | `dr-forge`, as a **test that refuses**, never a start |
| Gateway mound (2) | core: `DRAUGR_REQUIRES=<gateway repo>` in the project |
| Forge VM (3) | `dr-forge`, which claims `vm:<name>` through `dr-dep claim --exclusive` |
| Tunnel (4) and preflight (5) | `dr-forge`, after the forge is online |
| The mound of the agent (6) | `dr-up`, as today |

Thus the part of the forge becomes smaller: test the daemon, claim the forge, start it, hold the
tunnel, probe the guest. `DRAUGR_FORGE_STOP` and `DRAUGR_FORGE_LINGER` become thin wrappers over
the core behavior, with no mechanism of their own.

---

## Order of work

Each phase is useful alone, and testable before the next one starts.

| Phase | What ships | State |
|---|---|---|
| 1 | Claims: the directory, the validity rule, `dr-dep status`, `dr-dep claim/unclaim` | **done** |
| 2 | `dr-dep up` and the `dr-up` integration, with no stop | **done**, with `--skip-deps` |
| 3 | Exclusivity: `DRAUGR_EXCLUSIVE`, the atomic claim, the refusal text | **done** |
| 4 | The warden: keeper, count, `DRAUGR_LINGER`, stop | **done** |
| 5 | `dr-stop`/`dr-rm`/`dr-status`/`dr-doctor` | **done**. `dr-ls` did not change: it lists what sbx knows, and a dependency is a mound as all others are |
| 6 | `dr-forge` moves its forge claim onto `dr-dep claim` | waits for `dr-forge`, which does not exist yet |

**Testing.** All through the existing `sbx` mock
([HACKING.md](HACKING.md#pattern-mocking-sbx-and-ssh)). It needs one addition: a state for each
sandbox, so that "running" and "stopped" can be different for two named mounds in one test. Two
rules of the test strategy apply here, and you must follow them, not work around them. First, a
test that passes for the wrong reason is worse than none. Thus the claim tests assert the *argv*
and the file contents, not a call count. A call count is exactly the hole that hid the
`dr-kit apply` bug. Second, no real sleep. The linger and the poll interval are injectable, and the
tests drive the warden one tick at a time.

---

## Acceptance criteria

| # | Criterion | State |
|---|---|---|
| B1 | One `dr-up` starts a chain | **measured with real `sbx`**: with all stopped, `dr-dep up` in a repo that requires `draugr-gateway` had it running and claimed in 68 s. Also tested through the mock |
| B2 | Idempotent | the own idempotence of `dr-up` covers it, and is older than this. The second run above started nothing |
| B3 | Order | **tested**: the claim exists, and the dependency is up, before Draugr creates the mound of this repo |
| B4 | The dependency owns its readiness | **measured**: the `post-up` of the gateway ran and probed (`gateway answers -> 403`) before `dr-dep up` returned. A hook that fails makes the `dr-up` of the consumer fail |
| B5 | Shared by default | **tested** |
| B6 | Exclusive refuses by name and since when | **tested**, two times: at the helper and through `dr-up` |
| B7 | Re-entrant | **tested** |
| B8 | Repairs itself | **tested**: Draugr takes over a lock whose holder is stopped |
| B9 | Counted stop | **measured with real `sbx`**: with the claim released, a warden tick after the linger killed the keeper, and left the mound `stopped`. Tested tick by tick through the mock |
| B10 | Linger cancels | **tested**: a claim during the window leaves it alone |
| B11 | Reboot recovery | **not measured**. It is A5 of the gateway plan, and needs a real reboot |
| B12 | Not trusted refuses | **measured**: a dependency that was not trusted stopped `dr-dep` before it read anything. `dr-doctor` and `dr-dep status` both report it |

---

## What shipped differently

Places where the build did not agree with the plan. Each one is a decision, not an oversight.

- **The keeper starts from WSL, not through PowerShell.** The plan copied the `post-up` hook of the
  gateway. That hook starts a hidden `sbx.exe exec … sleep infinity` on the Windows side, so that
  the session stays after a WSL restart. Core does not call `powershell.exe` in any place, and that
  dependency for one detail was the larger cost. Thus the warden starts the keeper with `setsid`, and
  owns it. The result is honest and small: `wsl --shutdown` now stops dependencies, and does not
  leave them as orphans. That is closer to the meaning of "shut down WSL".
- **A detached process must close what it got from its parent.** A redirect of stdin, stdout and
  stderr is not sufficient. Under `bats`, the warden got the pipe of the test runner on fd 3, and
  held the full run open after all tests passed. The warden now closes each descriptor above stdio.
  [HACKING.md](HACKING.md#pattern-a-process-that-outlives-the-command-that-started-it) has the
  pattern, because it also applies to the next long-lived helper.
- **The claim records its own key.** Draugr cleans the directory name (`vm:UE5-Test` becomes
  `vm_UE5-Test`), and that cannot be reversed. `dr-doctor` needs the original to tell a mound from
  a resource that is not a mound. It is a field in the claim file, not a second lookup table.
- **A warden that dies early now says so.** In the end-to-end run, the first detached warden died
  before it wrote its pid file. It left an empty log and no evidence. The retry worked, and the
  cause is still not known. Thus the warden writes its pid and a start line *first*, and `dr-dep up`
  makes sure, a second later, that it is really there. A missing warden means no keeper, and sbx
  then stops an idle mound after 30 s.

**Not deviations, but important:** the grace period is five minutes, and the poll interval sixty
seconds. `DR_DEP_GRACE` and `DR_DEP_POLL` override both, so that tests never sleep. The tests drive
the warden one tick at a time with `--once`. That is how the linger is tested with no wall-clock
time.

---

## Rejected alternatives

- **A daemon that owns the dependencies.** It answers each question here cleanly, but it is the
  wrong shape for a tool that is about scripts that you can read. The warden is a loop that can die
  with no damage. A daemon is something to install, supervise and explain.
- **Reference counts inside `sbx`.** That feature does not exist, and `sbx kit`/`sbx settings` are
  already marked as standing risks ([DESIGN.md](DESIGN.md#standing-risks)). A lifecycle on an
  undocumented surface adds a third risk.
- **A direct read of the `.draugr.conf` of the dependency**, to learn its sandbox name. It is shell
  code. To source it is the trust decision. A half parse of it with `grep` is a second, worse
  configuration reader. `dr-config KEY` in that directory already answers, with the own trust test
  of that repository.
- **A claim for each process, not for each repository.** Then the lock is not re-entrant, and a
  second terminal in the same project gets a refusal. Validity also becomes a pid test, which lies
  after a reboot.
- **A wait for an exclusive claim, in place of a refusal.** A queue with no visible position is
  worse than a refusal that names a holder. We can add a wait later. We cannot remove it later.

---

## Open questions

1. **Parallel start.** Links 2 and 3 are independent, and a cold gateway takes 60–90 s
   *(measured)*. Sequential is simpler and predictable. Parallel is faster, and harder to report.
   Measure the real cost before you select one.
2. **A start timeout.** If the `dr-up` of a dependency hangs, the consumer hangs. Today the answer
   is Ctrl-C. Nobody measured whether a timeout is better than a visible "still creating
   draugr-gateway (90 s)".
3. **A different linger for each kind of resource.** A forge that takes three minutes to boot and a
   database that takes two seconds possibly want different defaults, and one key cannot say so.
4. **A claim of its own for `dr-go`.** Then an attached session keeps a dependency alive, also when
   the mound otherwise looks idle. Probably not necessary, because an attached session is a running
   mound. But such problems show up only in use.
5. **Claims between users or between machines.** Out of scope. The state directory is for one user,
   and a second user on the same host does not see the claims of the first. It is named here, so
   that it is a decision, not an oversight.
