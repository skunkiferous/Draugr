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
| `dr-rm` | **destroy it.** Refuses unless commits are synced and memory exported |

`dr-stop` is what you want when you just wish it would stop using memory. Starting it again is
seconds and loses nothing.

`dr-rm` throws away the agent's clone permanently. It asks first, and checks the mound rather than
trusting a local tracking ref — which costs a few seconds and starts a stopped sandbox, because the
only way to know whether the agent committed something you never fetched is to ask it.
