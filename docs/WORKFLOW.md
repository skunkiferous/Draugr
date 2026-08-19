# Workflow

What a day with Draugr actually looks like, and what each step is protecting you from.

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

`dr-go` is idempotent. It checks the daemon, scans for credentials, creates the sandbox if missing —
applying your kit — imports memory, then attaches. Second run it just attaches.

With `DRAUGR_AUTO_SYNC=true` (the default) the `dr-sync` happens for you when you leave the agent, so
in practice the loop is `dr-go`, then `dr-diff`, then `dr-merge`.

## Ctrl+Z, and the shell you did not have to open

Press **Ctrl+Z** in the agent and it suspends, leaving you at a prompt **inside the mound**, in the
clone, with the agent's own environment:

```bash
agent@draugr-myproject:/c/src/myproject$ ls -la node_modules/.bin
agent@draugr-myproject:/c/src/myproject$ fg      # back into the agent, exactly as you left it
```

`jobs` lists it, `fg` resumes it, and Ctrl+D from the agent leaves as it always did. One window, no
second connection, no restart.

This is the reason Draugr runs in WSL. `sbx run` reaches the sandbox through `sbx.exe`, a *Windows*
binary — Ctrl+Z suspends the relay rather than the agent, and a few seconds later the session dies
with `inspect exec: context deadline exceeded`. Over ssh the far end is a real pty doing its own job
control. That is what [`DRAUGR_ATTACH`](CONFIG.md#draugr_attach) selects, and `ssh` is the default.

`dr-shell` is still there for a genuinely *second* shell — one that runs alongside the agent instead
of pausing it — and for `--root`.

## Three repositories

Everything else follows from this.

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

1. **Only you talk to the remote.** The sandbox has no credentials and no route to it.
2. **The sandbox cannot write to your repository.** Kernel-enforced, not convention.
3. **You pull *from* the sandbox.** It never pushes to you.

Treat the agent like a colleague who hands you a branch: fetch it, review it, merge it, push it
yourself.

---

## Reviewing

`dr-sync` fetches into a remote-tracking branch and stops. Nothing is merged, your branch does not
move, and your working tree is untouched — so running it is never a decision.

| | |
|---|---|
| `dr-log` | what is new that you have not seen |
| `dr-diff` | the changes properly, host tree vs the agent's work |
| `dr-merge` | accept it — a merge, or `--pick <sha>` to take one commit |

`dr-diff` uses three-dot diff, so it shows what the agent *added* rather than also showing your own
newer commits as though the agent had reverted them.

`dr-merge` refuses on a dirty tree. Nothing to merge is reported as success, not an error, because
"the agent did not commit anything" is a normal outcome of a session.

## Sending work the other way

The agent's clone was made when the mound was created. If you commit something on the host that it
needs:

```bash
dr-send
```

This fetches from inside the mound through the read-only mount, so it works without giving the
sandbox any route to your machine.

To retrieve something the agent has *not* committed — a scratch file, a log:

```bash
dr-cp <path-in-mound> <destination>
```

---

## Working with data files

Git is the right channel for source and the wrong one for a half-processed 4 GB parquet file.
`DRAUGR_DATA` gives you a second channel alongside git rather than through it.

```bash
DRAUGR_DATA="tmp/** *.parquet scratch/raw/"
DRAUGR_DATA_PUSH=auto        # dr-up pushes before the agent starts
DRAUGR_DATA_PULL=manual      # you run dr-data pull when you want results back
```

Matching paths move by `rsync` over the same `ssh://` transport `dr-sync` uses, landing at the
**same repo-relative path** on both sides — so a script reading `tmp/raw/2024.parquet` works
unchanged in either place.

| | |
|---|---|
| `dr-data status` | dry run, both directions: what would move, and how much |
| `dr-data diff` | what a pull would **change**, as a real diff where it can |
| `dr-data push` | host → sandbox, the host wins |
| `dr-data pull` | sandbox → host, the sandbox wins |

Four things worth having in mind:

- **They are exempt from `DRAUGR_REQUIRE_CLEAN`.** Data churn will not stop you starting a session.
- **Keep them gitignored.** Then they are ignored in the agent's clone too, and it will not
  accidentally commit 4 GB of scratch.
- **The delta algorithm survives the boundary.** Measured: appending 21 bytes to a 3 MB file put
  375 bytes on the wire on the next push. The first transfer of a large tree is expensive; every one
  after it is close to free.
- **Files land owned by the agent, ready to write.** This is why `rsync`-over-`ssh` is the transport
  rather than `sbx cp`, which writes as `root:root` — readable by the agent but never modifiable, so
  generated output fails in ways that look like a broken script rather than a permissions problem.

> **Direction is explicit, on purpose.** There is no merge algorithm for a parquet file: if both
> sides changed it, any bidirectional sync silently picks a winner and destroys the other version.
> So each transfer declares a source of truth, and `dr-data status` shows a dry run of both before
> you commit to either.
>
> `DRAUGR_DATA_DELETE=false` is the default for the same reason: without it, a `push` after you
> tidied a directory on the host would delete the agent's newly generated output.

**If the agent only ever reads the data, do not use this.** Mount it read-only instead —
`DRAUGR_MOUNTS="/mnt/c/data:ro"` — and it appears with no copy, no transfer time and no chance of
the agent modifying your originals.

---

## A project that depends on the one next door

One repository per mound. So a project that used to reach its neighbour through `..\Sibling` cannot,
because the neighbour is not in there.

There are two ways to put it back, and they are not equivalent:

| | |
|---|---|
| **Mount it read-only** | `DRAUGR_MOUNTS="/mnt/c/Code/Sibling:ro"` — your live working tree, uncommitted edits included |
| **Package it as a kit** | the version you last published, frozen until you publish again |

The mount lands at the **mirrored path**, so the two stay siblings inside the mound and `../Sibling`
resolves with nothing rewritten:

```text
/c/Code/MyProject      ← the clone, writable
/c/Code/Sibling        ← the mount, read-only
```

Use the mount when you are developing both at once — it is the case where a kit would force you to
commit and publish the dependency before the other project could see the change. Use a kit when the
dependency is a released thing with a version, or when the agent needs it *installed* rather than
merely readable.

Two consequences of the mount worth knowing. The agent sees your work in progress, half-finished
refactors included. And **`dr-scan` does not look inside extra mounts** — it scans the repository you
are standing in — so a `.env` in the mounted project is readable and unreported.

Mounts are fixed when the mound is built. `dr-up` warns when the list has changed since, and
`dr-up --recreate` rebuilds.

---

## Memory

The mound's disk survives `dr-stop` and dies with `dr-rm`, so anything the agent learned about your
project dies with it unless it was exported.

| | |
|---|---|
| `dr-mem status` | where memory is on each side, and how much |
| `dr-mem export` | mound → `$DRAUGR_MEM_STORE` |
| `dr-mem import` | store → mound |
| `dr-mem diff` | what each side knows that the other does not |

With `DRAUGR_MEM_SYNC=auto` (the default) the export happens when you leave the agent and the import
on `dr-up`, so you should never have to think about it. The import only ever fills a mound that has
*no* memory: the store is by definition the older copy and must not overwrite what the agent has
learned since.

`dr-rm` refuses to destroy unexported memory, the same way it refuses to destroy unfetched commits.

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
> Copy the folder across untranslated and you get a directory the agent silently never reads — no
> error, no warning, just an agent that has forgotten everything. `dr-mem` translates, and fixes
> ownership afterwards, because `sbx cp` lands files as `root:root` while the agent runs as uid 1000
> and could not write new memories.

**Moving your existing host memory in.** If you have been running the agent on the host and want the
mound to start with what it knew:

```bash
dr-mem import --from-host
```

**Imported memory is instructions, not notes.** Memory files are loaded into the agent's context and
largely trusted. Your own is fine; a colleague's or a template's is a payload you carried across the
boundary yourself. `dr-mem import` refuses to run unattended against a store Draugr did not write.

---

## Skills

The shared skills store is mounted read-write into every mound and survives `sbx rm`. It is the one
path by which a sandbox can leave something behind for a later one to read, and skills are
instructions.

| | |
|---|---|
| `dr-skills list` | what is in the store, and whether the mount can be declined on this machine |
| `dr-skills diff` | what has appeared or changed since you last accepted |
| `dr-skills accept` | record the current contents as reviewed |
| `dr-skills import` | seed the store from your own host skill directories |

`dr-scan` lists the store on every `dr-go`, so anything that appears without your putting it there
is visible. See [SECURITY.md](SECURITY.md#trap-2--the-skills-store-is-a-writable-door-out).

---

## Ending a session

| | |
|---|---|
| `dr-stop` | shut the mound down. Filesystem, login and memory all survive |
| `dr-stop --all` | stop **every** running sandbox on the machine, after listing them |
| `dr-rm` | **destroy it.** Refuses unless commits are synced and memory exported |

`dr-stop` is what you want when you just wish it would stop using memory. Starting it again is
seconds and loses nothing.

`dr-rm` throws away the agent's clone permanently. It asks first, and checks the mound rather than
trusting a local tracking ref — which costs a few seconds and starts a stopped sandbox, because the
only way to know whether the agent committed something you never fetched is to ask it. It checks
**every** branch, not just the one you track.

---

## What is durable, and what is not

**The mound's clone is disposable. Your repository is the durable copy.** That is the whole design,
and it is worth saying out loud because the consequences are not obvious.

`DRAUGR_AUTO_SYNC` defaults to `true`, so leaving the agent runs `dr-sync` for you, and `dr-sync`
fetches with the refspec `+refs/heads/*` — **every branch**, not only the one you track. By the time
your shell prompt comes back, everything the agent committed is on your disk. That is what makes the
mound safe to lose.

And it can be lost. Measured: a host reboot with a mound still running left five zero-length objects
in the sandbox's `.git`, enough that `git status` inside it printed
`error: object file … is empty`. The microVM had the writes in page cache and the reboot took them.
Nothing was lost, because auto-sync had already pulled every branch out — but the clone itself was
unrecoverable.

Two things follow:

- **Do not set `DRAUGR_AUTO_SYNC=false` unless you run `dr-sync` yourself.** It is the mechanism, not
  a convenience. Without it the mound is the only copy of the agent's work.
- **The exposed window is between the agent's last commit and your next sync.** A crash there costs
  that session. `dr-stop` when you are done with a mound rather than leaving it running is the cheap
  way to shrink it, and `dr-stop --all` sweeps the machine before you shut it down.
  [`DRAUGR_STOP_ON_EXIT=true`](CONFIG.md#draugr_stop_on_exit) makes `dr-go` do it for you, after the
  sync. It is off by default: an idle mound holds ~1.4 GB, but stopping costs four seconds on the way
  back in and kills anything the kit serves through `publishedPorts`.

### Why there is no WSL shutdown hook

The obvious idea is to hang `dr-stop --all` off WSL shutting down. It would not work, and it is worth
knowing why before you build it.

`sandboxd` is a **Windows** process — `sbx.exe daemon start`, on the named pipe
`\\.\pipe\docker_kaname_sandboxd`, with the mounds as Hyper-V microVMs under `vmcompute`. WSL is only
a client that shells out to `sbx.exe`. Shutting WSL down therefore stops nothing: every mound keeps
running, and a hook there would fire at the one moment it cannot help.

The exposure is a *Windows* shutdown, so any automatic sweep has to live on the Windows side — a
shutdown script or a scheduled task calling `sbx stop`. That is outside a WSL bash project, and
worth weighing against the fact that it buys little: `dr-go` has already synced every branch to your
repository by the time you get your prompt back. Stopping is hygiene, not durability.

`dr-sync --no-fetch` reports on what you have already fetched and needs no sandbox at all, so
"what did I keep?" is answerable after `dr-rm`.

### Agents invent branch names

An agent will frequently commit to a branch of its own — `sbx-kit-lua-deps`, `feature/x` — rather
than the one you started on. Those branches are fetched like any other, but `dr-log`, `dr-diff` and
`dr-merge` all work against `draugr/$DRAUGR_BRANCH`, so they will not show you work that landed
elsewhere.

`dr-sync` and `dr-status` now name any branch carrying commits you have not merged. To review one,
override the branch for a single command — `DRAUGR_BRANCH` is an ordinary config key:

```bash
DRAUGR_BRANCH=sbx-kit-lua-deps dr-diff
DRAUGR_BRANCH=sbx-kit-lua-deps dr-merge
```
