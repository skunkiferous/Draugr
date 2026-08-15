# Troubleshooting

Start with `dr-doctor`. It checks every precondition and names the fix for each, and most of what
follows is a case it cannot detect from the outside.

Draugr never hides `sbx`: when a command fails, its error names the underlying `sbx` invocation, and
`DRAUGR_DEBUG=1` prints every `sbx` command line before it runs. Reproducing a problem without
Draugr in the way is usually the fastest route to understanding it.

---

## Setup

### `dr-sync` fails with `Connection refused`, or `ssh: Could not resolve hostname`

WSL has its own `~/.ssh/config`, separate from Windows'. `sbx setup ssh` writes only the Windows one.

```bash
dr-setup            # writes the *.sbx block into WSL's config
dr-setup --print    # see what it would write, first
```

This is the single most commonly missed step.

### `cannot find sbx.exe`

`sbx` is a Windows binary and is not on WSL's `PATH` by default. Draugr looks for it on `PATH`, via
`%LOCALAPPDATA%`, and in the two usual install locations across every drive. If yours is elsewhere:

```bash
export DRAUGR_SBX=/mnt/c/path/to/sbx.exe
```

### `sbx` commands hang, or say the daemon is unreachable

```powershell
sbx daemon status
sbx diagnose
```

A reboot after enabling the hypervisor features is required and is easy to skip; `sbx diagnose`
reports host configuration problems Draugr cannot see.

### `<path> is not on a Windows drive`

`sbx.exe` takes Windows paths, so a repo on WSL's ext4 has nothing `sbx` can mount. Move the project
under `/mnt/c/` and work on it from there.

Mapping a drive letter to a WSL path with `subst` does not help — it was tested end to end and fails
at the container, not at Draugr. The full sequence is in [DESIGN.md](DESIGN.md#repos-on-ext4-via-a-subst-drive).

### `jq: command not found`

```bash
sudo apt install jq
```

Draugr parses `sbx ls --json` with `jq` rather than by hand, because hand-parsing JSON in bash is
exactly the kind of fragile cleverness this project should not contain.

---

## Sessions

### `dr-go` refuses: uncommitted changes

The sandbox gets a **clone**, and a clone contains committed history only — your uncommitted work
simply is not in it, and the agent would quietly build on stale code. Commit, stash, or:

```bash
dr-go --dirty
```

Paths matching `DRAUGR_DATA` are already exempt, so data churn alone will not trigger this.

### `dr-go` refuses: credential-shaped files

`dr-scan` found something readable through the read-only mount. That mount shows your *whole* working
tree, gitignored files included — see [SECURITY.md](SECURITY.md#trap-1--what-the-agent-can-read).
Move the file out of the repo. `DRAUGR_SCAN_FAIL=warn` downgrades the refusal if you are certain.

### `dr-go` needs a terminal

`sbx run` attaches an interactive session, and without a TTY it gets partway in and dies with
`inspect exec: context deadline exceeded`, which tells you nothing. Draugr checks first and says so.
To run one command non-interactively:

```bash
dr-shell -- <command>
```

### Ctrl+Z suspends the agent and the terminal misbehaves

Job control across the sandbox boundary does not work the way it does locally. Use Ctrl+D to leave
the agent; `dr-stop` afterwards if you want the mound shut down.

### The agent seems to have forgotten everything

Almost certainly the project-key trap: memory is filed under a key derived from the project's
absolute path, which differs on every side of the boundary.

```bash
dr-mem status       # shows all three keys and what is on each side
```

If the mound has a project directory under a key Draugr did not predict, `dr-mem` says so and lists
what is actually there. See [WORKFLOW.md](WORKFLOW.md#memory).

### The agent can read a memory but cannot write new ones

`sbx cp` lands files as `root:root` while the agent runs as uid 1000. `dr-mem import` chowns
afterwards; if that step failed you will have seen a warning. Fix it by hand:

```bash
dr-shell -- sudo -n chown -R agent:agent ~/.claude/projects/<key>/memory
```

---

## Getting work in and out

### `dr-sync` says there is nothing, but the agent definitely committed

Check the mound rather than the tracking ref:

```bash
dr-status
```

The tracking ref only says what was true at your last `dr-sync`. If the agent committed to a
different branch than `DRAUGR_BRANCH`, `dr-sync` will not see it.

### `dr-merge` refuses

It will not merge onto a dirty tree. Commit or stash first. "Nothing to merge" is reported as
success rather than an error — a session where the agent committed nothing is a normal outcome.

### I removed the sandbox and lost work

`sbx rm` mirrors fetched branches to `refs/sandboxes/<name>/*` on the host, and **those survive
removal**. Look there before assuming it is gone:

```bash
git for-each-ref refs/sandboxes/
```

This is also why `dr-rm` asks the mound directly rather than trusting a local ref, and why it
refuses by default.

### A web server in the sandbox is not reachable from Windows

Ports must be published, and they are published to Windows loopback:

```bash
dr-ports 5173          # on a running mound
DRAUGR_PORTS="5173:5173"   # or in config, for every session
```

Note this is the reason `dr-sync` uses `ssh://` rather than the `git://` daemon: the daemon binds
Windows loopback only, which WSL2 cannot reach across its NAT, and its port is randomised on every
start.

---

## Builds and the network

### Builds fail with network errors

The sandbox denies anything matching no allow rule. Find out what is actually in force:

```bash
dr-policy --check registry.example.com
dr-policy --allow registry.example.com     # temporary, on the running mound
```

Then graduate it into the kit's `caps.network.allow` so it survives a recreate. Remember that ~190
machine-wide rules already apply, so the domain may be allowed for a reason you did not write —
`dr-policy --defaults` lists those.

### The kit changed but the sandbox did not

Applying a kit recreates the container, so Draugr will not do it as a side effect. `dr-up` warns
about the drift; `dr-kit apply` performs it.

```bash
dr-kit validate     # before you find out the hard way
dr-kit show
```

### `rsync` is missing inside the mound

It is present in the `claude` image (`/usr/bin/rsync`), but that is not guaranteed across every agent
image. `dr-up` installs it at creation if missing, and falls back to `tar` over ssh — always present,
but whole-file rather than incremental.

---

## Data transfers

### `dr-data` moved more than I expected

Check what the patterns actually mean before transferring:

```bash
dr-data status      # dry run, both directions, with sizes
```

A slashless entry is **unanchored** and matches at every depth, so `*.sample` matches
`vendor/x/y.sample` too. `.git` and `.draugr` are always excluded regardless of your patterns.

### `dr-data` deleted something

`DRAUGR_DATA_DELETE` propagates deletions, and even with it enabled each run asks first. If you lost
generated output, it is because a `push` ran after you tidied that directory on the host. There is no
undo; this is why the default is `false`.

---

## Last resorts

### Sandbox will not start: "block device … used by another process"

A previous VM did not shut down cleanly.

```powershell
sbx stop <name>
sbx ls                 # confirm it is actually stopped
```

If it persists, reboot. This is a host-level problem below anything Draugr can reach.

### `sbx rm` fails with "stdin is not a terminal"

`dr-rm` already passes `--force` for this reason — it also removes a sandbox with a stale SSH
connection open. If you are calling `sbx` directly, add `--force` yourself.

### Start over completely

```powershell
sbx reset              # destroys ALL sandboxes and sbx state, including the skills store
```

Export anything you want to keep first — `dr-mem export` for each project, and note that `sbx reset`
clears the shared skills store as well.

---

## Reporting a problem

Include `dr-doctor` output, `sbx version`, and the command re-run with `DRAUGR_DEBUG=1`. The last one
prints every `sbx` command line Draugr built, which is usually enough to see what went wrong without
reproducing your machine.
