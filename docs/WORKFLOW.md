# Workflow

What a day with Draugr looks like, and what each step protects you from.

## The loop

```bash
cd /mnt/c/src/myproject

dr-go                    # preflight, mound, agent
                         # ... the agent works and commits inside the sandbox ...
                         # Ctrl+D when you are done

dr-sync                  # fetch its commits onto draugr/main
dr-diff                  # review what it actually did
dr-merge                 # accept it
git push                 # publish, exactly as you always did
```

`dr-go` is idempotent. It makes sure that the daemon runs, and scans for credentials. If the
sandbox is missing, it creates it, with your kit. Then it imports memory, and attaches. On a second
run, it only attaches.

With `DRAUGR_AUTO_SYNC=true` (the default), `dr-sync` happens for you when you leave the agent.
Thus in practice, the loop is `dr-go`, then `dr-diff`, then `dr-merge`.

## Ctrl+Z, and the shell you did not have to open

Press **Ctrl+Z** in the agent, and it suspends. You get a prompt **inside the mound**, in the clone,
with the own environment of the agent:

```bash
agent@draugr-myproject:/c/src/myproject$ ls -la node_modules/.bin
agent@draugr-myproject:/c/src/myproject$ fg      # back into the agent, exactly as you left it
```

`jobs` lists it, `fg` resumes it, and Ctrl+D from the agent leaves as before. One window, no second
connection, no restart.

This is the reason why Draugr runs in WSL. `sbx run` reaches the sandbox through `sbx.exe`, a
*Windows* binary. Ctrl+Z suspends the relay, not the agent, and a few seconds later the session
dies with `inspect exec: context deadline exceeded`. Over ssh, the far end is a real pty that does
its own job control. [`DRAUGR_ATTACH`](CONFIG.md#draugr_attach) selects that, and `ssh` is the
default.

`dr-shell` still exists for a real *second* shell, one that runs beside the agent and does not
pause it, and for `--root`.

## Three repositories

All else follows from this.

```
      YOUR REMOTE  (origin)
           ▲  │
      push │  │ pull                    ← unchanged, exactly as you always did it
           │  ▼
      HOST REPO  ◄────── dr-sync ──────  SANDBOX CLONE
   /mnt/c/src/myproject                 (inside the microVM)
           │
           └──── mounted READ-ONLY ────►  visible at /run/sandbox/source
```

1. **Only you talk to the remote.** The sandbox has no credentials, and no route to it.
2. **The sandbox cannot write to your repository.** The kernel enforces that. It is not a
   convention.
3. **You pull *from* the sandbox.** It never pushes to you.

Treat the agent as a colleague who gives you a branch. Fetch it, review it, merge it, and push it
yourself.

---

## Reviewing

`dr-sync` fetches into a remote-tracking branch, and stops. Nothing is merged, your branch does not
move, and your working tree does not change. Thus a run of it is never a decision.

| | |
|---|---|
| `dr-log` | what is new, that you did not see |
| `dr-diff` | the full changes: host tree against the work of the agent |
| `dr-merge` | accept it: a merge, or `--pick <sha>` to take one commit |

`dr-diff` uses a three-dot diff. Thus it shows what the agent *added*. It does not show your own
newer commits as if the agent reverted them.

`dr-merge` refuses on a dirty tree. It reports "nothing to merge" as success, not as an error,
because "the agent committed nothing" is a normal result of a session.

## Sending work the other way

Draugr made the clone of the agent when it created the mound. If you commit something on the host
that the agent needs:

```bash
dr-send
```

This fetches from inside the mound, through the read-only mount. Thus it works, and the sandbox gets
no route to your machine.

**It delivers, but it does not merge.** Your commits go to `host/<branch>` *inside* the clone, and
the branch of the agent does not move. The agent can be in the middle of an edit, and a branch that
moves under it causes a tangle that nobody asked for. Thus after a good `dr-send`, `draugr/<branch>`
is still behind you. That is correct, not a failure:

| | |
|---|---|
| `N commit(s) not in draugr/main. Use dr-send.` | the mound never saw them |
| `N commit(s) delivered, not merged. Use dr-send --merge.` | they are in there, but nobody took them |

The other half is `git merge host/main` inside the mound, which you can leave to the agent.
`dr-send --merge` does it for you, and refuses on a dirty clone.

To get something that the agent did *not* commit, such as a scratch file or a log:

```bash
dr-cp <path-in-mound> <destination>
```

---

## Working with data files

Git is the right channel for source, and the wrong one for a half-processed 4 GB parquet file.
`DRAUGR_DATA` gives you a second channel beside git, not through it.

```bash
DRAUGR_DATA="tmp/** *.parquet scratch/raw/"
DRAUGR_DATA_PUSH=auto        # dr-up pushes before the agent starts
DRAUGR_DATA_PULL=manual      # you run dr-data pull when you want results back
```

`rsync` moves the matching paths over the same `ssh://` transport as `dr-sync`. They arrive at the
**same path in the repo** on both sides. Thus a script that reads `tmp/raw/2024.parquet` works
unchanged in both places.

| | |
|---|---|
| `dr-data status` | dry run, both directions: what moves, and how much |
| `dr-data diff` | what a pull **changes**, as a real diff where possible |
| `dr-data push` | host → sandbox, the host wins |
| `dr-data pull` | sandbox → host, the sandbox wins |

Know these facts:

- **They are exempt from `DRAUGR_REQUIRE_CLEAN`.** Changed data does not stop the start of a
  session.
- **If they are scratch, put them in .gitignore.** Then the clone of the agent also ignores them, and
  it does not commit 4 GB of intermediate output by accident. `DRAUGR_DATA` was designed for this
  case.
- **They need not be in .gitignore, and tracked files can also match.** In a project whose *content*
  is data, for example a few hundred versioned `.tsv` files, `DRAUGR_DATA="*.tsv"` does something
  different, but still useful. The clone holds only the committed history. Thus without a push, an
  uncommitted edit does not reach the agent. Here git is the review channel, and rsync is the
  transport. The two do not conflict, if you know which is which. The cost is the clean-tree guard.
  Those files no longer block `dr-go`. That is safe exactly *because* `DRAUGR_DATA_PUSH=auto` carries
  them. If you turn off the push, `dr-go` says so.
- **The delta algorithm works across the boundary.** Measured: 21 bytes added to a 3 MB file sent
  375 bytes on the next push. The first transfer of a large tree is slow. Each later one is almost
  free.
- **A pull lands in `%LOCALAPPDATA%\Draugr\stage` first, and is reviewed from there.** A dry run
  would describe a mound that keeps working afterwards; the staged tree is the files themselves, so
  the names and types that are judged are the ones that get published. Nothing is refused by halves:
  one bad name stops the whole pull and publishes none of it. It is as fast as a direct transfer
  because both legs hard-link instead of copying — which needs the staging root and the repository
  on one volume. `DRAUGR_STAGE_ROOT` moves it.
- **Files arrive owned by the agent, ready to write.** That is why the transport is `rsync` over
  `ssh`, and not `sbx cp`. `sbx cp` writes as `root:root`. The agent can read such files, but never
  change them. Generated output then fails in a way that looks like a broken script, not a
  permissions problem.

> **The direction is explicit, on purpose.** There is no merge algorithm for a parquet file. If both
> sides changed it, a sync in both directions silently selects one version, and destroys the other.
> Thus each transfer declares a source of truth. `dr-data status` shows a dry run of both before you
> select one.
>
> `DRAUGR_DATA_DELETE=false` is the default for the same reason. Without it, a `push` after a
> clean-up on the host deletes the new output of the agent.

**If the agent only reads the data, do not use this.** Mount it read-only:
`DRAUGR_MOUNTS="/mnt/c/data:ro"`. It shows with no copy and no transfer time, and the agent cannot
change your originals.

---

## A project that depends on the one next door

One repository for each mound. Thus a project that reached its neighbor through `..\Sibling` cannot
do that now, because the neighbor is not in there.

There are two ways to put it back, and they are not the same:

| | |
|---|---|
| **Mount it read-only** | `DRAUGR_MOUNTS="/mnt/c/Code/Sibling:ro"`: your live working tree, with uncommitted edits |
| **Package it as a kit** | the version that you last published, fixed until you publish again |

The mount arrives at the **mirrored path**. Thus the two stay siblings inside the mound, and
`../Sibling` resolves with no rewrite:

```text
/c/Code/MyProject      ← the clone, writable
/c/Code/Sibling        ← the mount, read-only
```

Use the mount when you develop both at the same time. With a kit in that case, you must commit and
publish the dependency before the other project can see the change. Use a kit when the dependency is
a released thing with a version, or when the agent needs it *installed*, not only readable.

Know two results of the mount. The agent sees your work in progress, also half-finished refactors.
And **`dr-scan` does not look inside extra mounts**, because it scans only the current repository.
Thus the agent can read a `.env` in the mounted project, and nothing reports it.

Mounts become fixed when Draugr builds the mound. If the list changed after that, `dr-up` warns, and
`dr-up --recreate` rebuilds.

---

## Memory

The disk of the mound stays after `dr-stop`, and is lost on `dr-rm`. Thus all that the agent learned
about your project is lost with it, unless it was exported.

| | |
|---|---|
| `dr-mem status` | where memory is on each side, and how much |
| `dr-mem export` | mound → `$DRAUGR_MEM_STORE` |
| `dr-mem import` | store → mound |
| `dr-mem diff` | what each side knows that the other does not |

With `DRAUGR_MEM_SYNC=auto` (the default), the export happens when you leave the agent, and the
import on `dr-up`. Thus you never need to think about it. The import only fills a mound that has
*no* memory. The store is always the older copy, and must not overwrite what the agent learned after
it.

`dr-rm` refuses to destroy unexported memory, as it refuses to destroy unfetched commits. So does
`dr-up --recreate`. With a transcript in the mound, that refusal covers the conversation too, and
`--force` still proceeds.

**The memory and the conversation are two things.** The memory is what the agent learned, and it is
small. The transcript is what was said, and `--continue` reads the newest one. A mound that gets
only the memory back has forgotten the conversation. Thus `dr-mem` carries the newest transcript as
well, and [`DRAUGR_MEM_TRANSCRIPTS`](CONFIG.md#draugr_mem_transcripts) chooses the amount: `off`,
`newest` (the default) or `all`. They differ in size by three orders of magnitude, so each export
says how much it moved, where the conversation now is on your host, and the command that deletes it
again.

**An export needs a quiet agent.** Both agents write their conversation continuously, and a copy of
a growing file is not a backup. `dr-mem export` refuses while the agent runs in the mound, and also
while anything else holds the conversation open. Between two turns the agent holds nothing open and
is still about to write, which is why the first of those two questions is the important one. It
compares hashes around the copy as well, for a writer that pauses between two probes. A refused
export leaves the store exactly as it was. Leave the agent, then export.
> ### The project-key trap, handled
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
> warning, only an agent that forgot everything. `dr-mem` translates, and fixes the owner after the
> copy. `sbx cp` writes files as `root:root`, but the agent runs as uid 1000, and cannot write new
> memories without the fix.

**To move your existing host memory in.** If you ran the agent on the host, and want the mound to
start with what it knew:

```bash
dr-mem import --from-host
```

**Imported memory is instructions, not notes.** The agent loads memory files into its context, and
mostly trusts them. Your own memory is safe. That of a colleague or a template is a payload that you
carried across the boundary. `dr-mem import` refuses to run unattended on a store that Draugr did
not write.

### The same commands, a different shape: Codex

`dr-mem` uses a native Codex recovery set. See [agent support](AGENT-SUPPORT.md#codex-context-recovery)
for the allowlist, version baseline, and limits.

**Memory is not for each project.** Codex keeps all under `$CODEX_HOME` (`/home/agent/.codex` in the
mound), with no directory named after the workspace. There is no key, and nothing to translate.
Draugr can still treat it as the memory of *this project* only because one mound holds one
repository.

**Sessions and generated memory are separate.** Draugr carries memory directories, transcript
files on older images, selected indexes, and the metadata and transcript databases. On codex-cli
0.167.2 the real conversation used `thread_history_1.sqlite` with `state_5.sqlite`. A native test
exported a real thread and resumed it in a fresh mound after import.

Leave Codex and its background server before import or export. An active or unknown writer fails
the whole transfer and preserves the last complete export. Codex can keep a process running after
you leave it. A stop of the mound ends that process, and the export then works:
`dr-stop && dr-mem export`. With [`DRAUGR_STOP_ON_EXIT`](CONFIG.md#draugr_stop_on_exit), `dr-go`
exports again after its own stop. Hash comparisons also catch changes during export. Do not attach
while a transfer runs.

**Import preserves feature choices.** Restoring a conversation does not enable memory generation.
`dr-mem status` reports its native feature state when the mound runs. Enable generation separately
if desired:

```bash
dr-shell -- codex features enable memories    # or turn it on yourself
```

Codex `--from-host` is refused because a host home can span unrelated projects. Use a dedicated,
reviewed `--source` export instead. Credentials and config must never enter staging. Separate
SQLite homes are currently unsupported and fail clearly.

### `AGENTS.md` and `CLAUDE.md` are not memory

Both agents also read an instruction file from the repository: `AGENTS.md` for Codex, `CLAUDE.md`
for Claude Code. Those are normal committed files, so they need nothing from Draugr. They arrive in
the clone with all else. When the agent edits one, it comes back through `dr-sync`, and you read it
in `dr-diff`, as each other change.

Thus they are the better place for all that must always apply. Memory is a recall layer that the
agent keeps for itself, and `dr-mem` carries it between mounds. `AGENTS.md` is what you decided, in
version control, reviewed. Use it for project rules, and use memory only as memory.

---

## Skills

The shared skills store stays after `sbx rm`. sbx 0.53 mounts it read-only by default. The older
read-write behavior described in the measurements below applies to sbx 0.37.1.

**The mount mode is fixed when the mound is created, not when you upgrade.** A test showed both
sides of this: in a mound that 0.53 created, `~/.agents/skills` refuses a write, and in a mound
that an older sbx created, the same store stays writable after the upgrade. Thus an upgrade alone
does not close that channel. Recreate a mound to get the read-only store, and until then treat its
shared skills as writable by the agent. Skills are instructions, and host-side changes still reach
later mounds either way.

It is one host directory, bind-mounted into each mound at a path that `sbx` selects:
`~/.claude/skills` in a Claude mound, `~/.agents/skills` in a Codex one. Draugr does not select that
path, and does not need to. Each agent reads the path that it gets.

> ### One store, two mount paths, both of them read
>
> `sbx` keeps a single store, and changes only where it shows: `~/.claude/skills` in a claude mound,
> `~/.agents/skills` in a codex one. Each agent reads its path. We measured this in the same way on
> each side: we asked the agent itself to list its skills, with shell use forbidden:
>
> ```text
> claude:  draugr-probe · dataviz · update-config · simplify · claude-api · …
> codex:   imagegen · openai-docs · plugin-creator · skill-creator · skill-installer · draugr-probe
> ```
>
> In both cases, `draugr-probe` was a marker skill, only in the shared store. A second marker, added
> to the store *after* the build of the codex mound, showed at once, with no restart. Thus
> `sbx skills import --help` tells the truth when it lists Claude and Codex as supported. A skill
> that you put in the store is in reach of each mound on the machine.
>
> That works in both directions, and it is why `dr-skills` exists. There is one namespace, with no
> partition for each agent. Thus your claude mounds read next what a codex mound leaves behind.

On the older writable mount, a sandbox can change the store whether or not the agent reads it.
That is why the store gets a review. `dr-skills` also counts hidden
directories, because Claude loads a store entry named `.something` as each other skill. Measured: a
`.hidden-probe` in the store shows in the own list of available skills of Claude.

| | |
|---|---|
| `dr-skills list` | what is in the store, and whether you can decline the mount on this machine |
| `dr-skills diff` | what is new or changed since your last accept |
| `dr-skills accept` | record the current contents as reviewed |
| `dr-skills import` | fill the store from your own host skill directories |
| `dr-skills install` | put the skills of Draugr into the store |

### What Draugr ships, and why

An agent inside a mound cannot see Draugr. The `dr-*` commands run on the host, `sbx` is not
installed in the mound either, and the agent has no way to learn any of this from the code. Thus it
guesses: it reads a 403 from the proxy as a dead service, it calls work finished while the work sits
in an uncommitted tree that a rebuild erases, or it asks you for something in words that do not name
a command. These skills exist so that it knows the shape of its own situation, and can hand you the
exact line to run.

| skill | what it teaches |
|---|---|
| `draugr` | where the agent is, what only you can change, and how to ask for it in four lines |
| `draugr-kit` | the network allow list and the install commands of the project, in either kit format |
| `draugr-handoff` | moving work, files and ports across the boundary, and why a push cannot work |
| `draugr-recreate` | what a rebuild destroys, and the order that saves each thing first |

`dr-skills install` puts all of them in the store, after it lists them and asks. They are
instructions in reach of every mound on the machine, so they get the same review as any other
entry: `dr-skills diff` reports a change to them as it reports any other.

`dr-doctor` reports both halves of that, because the store belongs to the machine and not to a
project:

```text
  ! skills store                       2 entr(ies), a change is not reviewed
  · draugr skills                      1 of 4 in the store
```

The first is a **warning**: every mound reads the store, so a change nobody looked at is worth
one. The second is a **note**, which counts toward nothing and disappears under `--quiet`.
Draugr never installs these skills on its own, so a machine that does not have them is not a
machine with a problem.

### Letting the agent build the kit

The kit of a new project is the one thing that you cannot write in advance. You do not know what a
build needs until it fails. The `draugr-kit` skill teaches the agent to find that out, and
`dr-skills install` puts it where each mound can read it.

The loop rests on one measured fact: **a host opened with `dr-policy --allow` applies at once on the
running mound.** Thus you fix the build by repeated tries inside one session, not by a recreate for
each host.

```bash
dr-skills install            # once per machine
dr-go                        # the agent builds; it fails; it stops and asks
dr-policy --denied           # the proxy's list — correct whatever the toolchain
dr-policy --allow <host>     # per host you accept; the agent retries immediately
   # … until the build is clean …
dr-diff                      # review the install commands the agent wrote
dr-merge                     # take them out of the mound
dr-kit adopt                 # write the hosts into the kit, from the daemon's own record
dr-kit validate              # schema check, before a recreate destroys a working mound
dr-up --recreate             # the real test: commands.install only runs at create
```

**Merge before you adopt.** `dr-kit adopt` leaves the kit file changed, and `dr-merge` refuses on a
dirty tree. Thus in the other order, the commit of the agent stays stuck until you commit the adopt.

**The recreate is where install commands run for the first time.** The agent cannot test them,
because it cannot create a mound. It also cannot see the repository from where they run, and that is
the usual trap. If the recreate fails, `dr-up` prints what sandboxd recorded under the own `500` of
sbx. Refer to [TROUBLESHOOTING.md](TROUBLESHOOTING.md#dr-up-fails-with-500-internal-server-error-failed-to-run-sandbox-container).

`dr-policy --denied` is important, because you cannot trust build output for this. Measured with
one blocked host: `curl` printed nothing, `git` named it exactly, and `pip` reported
`Could not find a version that satisfies the requirement`, which looks like a missing package. The
proxy logged all three in the same way.

**The agent never grants anything.** It reports what it needs and why, and you decide. That is the
review gate, and it is not automated, on purpose.

**You need to remember nothing.** `dr-kit adopt` reads back the hosts that were really opened, skips
the hosts that the kit already declares, and writes the rest into `caps.network.allow`. A second run
does nothing.

> **The rules do not live longer than the mound.** They apply to the sandbox. After `sbx rm`, a
> look-up of one by id gives `policy or rule not found`. Thus a recreate destroys the very list that
> made the build work. Thus `dr-rm` and `dr-up --recreate` refuse while anything is not adopted, as
> `dr-rm` already refuses over unfetched commits. `dr-kit adopt` clears it.

`dr-scan` lists the store on each `dr-go`. Thus all that shows up without you is visible. Refer to
[SECURITY.md](SECURITY.md#trap-2--the-skills-store-is-a-writable-door-out).

---

## Ending a session

| | |
|---|---|
| `dr-stop` | shut down the mound. Filesystem, login and memory all stay |
| `dr-stop --all` | stop **each** running sandbox on the machine, after a list of them |
| `dr-rm` | **destroy it.** Refuses until commits are synced and memory is exported |

Use `dr-stop` when you only want the mound to stop using memory. A new start takes seconds, and
loses nothing.

`dr-rm` throws away the clone of the agent forever. It asks first. It asks the mound, and does not
trust a local tracking ref. That costs a few seconds, and starts a stopped sandbox. But the only way
to know whether the agent committed something that you did not fetch is to ask it. It tests **each**
branch, not only the one that you track.

---

## What is durable, and what is not

**The clone of the mound is disposable. Your repository is the durable copy.** That is the full
design. We say it clearly, because the results are not clear.

`DRAUGR_AUTO_SYNC` has the default `true`. Thus when you leave the agent, `dr-sync` runs for you, and
`dr-sync` fetches with the refspec `+refs/heads/*`: **each branch**, not only the one that you track.
When your shell prompt comes back, all that the agent committed is on your disk. That makes the
mound safe to lose.

And you can lose it. Measured: a host reboot while a mound ran left five empty objects in the `.git`
of the sandbox. Thus `git status` inside it printed `error: object file … is empty`. The microVM had
the writes in page cache, and the reboot took them. Nothing was lost, because auto-sync had already
pulled each branch out. But nothing was able to recover the clone itself.

Two results follow:

- **Do not set `DRAUGR_AUTO_SYNC=false` unless you run `dr-sync` yourself.** It is the mechanism,
  not a convenience. Without it, the mound holds the only copy of the work of the agent.
- **The risk window is between the last commit of the agent and your next sync.** A crash there costs
  that session. A `dr-stop` when you finish with a mound, in place of a mound that stays running, is
  the cheap way to make the window smaller. `dr-stop --all` stops all on the machine before you shut
  it down. [`DRAUGR_STOP_ON_EXIT=true`](CONFIG.md#draugr_stop_on_exit) makes `dr-go` do it for you,
  after the sync. It is off by default. An idle mound holds ~1.4 GB, but a stop costs four seconds on
  the next start, and kills all that the kit serves through `publishedPorts`.

### Why there is no WSL shutdown hook

The clear idea is to run `dr-stop --all` when WSL shuts down. It does not work. Know why before you
build it.

`sandboxd` is a **Windows** process: `sbx.exe daemon start`, on the named pipe
`\\.\pipe\docker_kaname_sandboxd`, with the mounds as Hyper-V microVMs under `vmcompute`. WSL is
only a client that calls `sbx.exe`. Thus a shutdown of WSL stops nothing. Each mound continues to
run, and a hook there fires at the one time when it cannot help.

The risk is a *Windows* shutdown. Thus an automatic sweep must be on the Windows side: a shutdown
script or a scheduled task that calls `sbx stop`. That is outside a WSL bash project. It also gives
little: `dr-go` already synced each branch to your repository when you get your prompt back. A stop
is clean-up, not protection.

`dr-sync --no-fetch` reports on what you already fetched, and needs no sandbox. Thus you can answer
"what did I keep?" after `dr-rm`.

### Agents invent branch names

An agent often commits to a branch of its own, such as `sbx-kit-lua-deps` or `feature/x`, not to
the one where you started. Those branches are fetched as all others. But `dr-log`, `dr-diff` and
`dr-merge` all work on `draugr/$DRAUGR_BRANCH`. Thus they do not show you work on other branches.

`dr-sync` and `dr-status` now name each branch with commits that you did not merge. To review one,
override the branch for one command. `DRAUGR_BRANCH` is a normal configuration key:

```bash
DRAUGR_BRANCH=sbx-kit-lua-deps dr-diff
DRAUGR_BRANCH=sbx-kit-lua-deps dr-merge
```
