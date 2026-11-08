# Troubleshooting

Start with `dr-doctor`. It tests each condition, and names the fix for each one. Most of the cases
below are cases that it cannot see from the outside.

Draugr never hides `sbx`. When a command fails, its error names the `sbx` call under it, and
`DRAUGR_DEBUG=1` prints each `sbx` command line before it runs. Usually the fastest way to
understand a problem is to repeat it without Draugr.

The `sbx` blocks below have the `powershell` label on purpose. `sbx` is a Windows binary, and it is
not on the `PATH` of WSL. Run them from a Windows terminal.

---

## Setup

### `dr-sync` fails with `Connection refused`, or `ssh: Could not resolve hostname`

WSL has its own `~/.ssh/config`, separate from that of Windows. `sbx setup ssh` writes only the
Windows one.

```bash
dr-setup            # writes the *.sbx block into WSL's config
dr-setup --print    # see what it would write, first
```

People forget this step more often than any other.

### `cannot find sbx.exe`

`sbx` is a Windows binary, and is not on the `PATH` of WSL by default. Draugr looks for it on
`PATH`, through `%LOCALAPPDATA%`, and in the two usual install locations on each drive. If yours is
in a different place:

```bash
export DRAUGR_SBX=/mnt/c/path/to/sbx.exe
```

### `sbx: command not found`, when you run it yourself

The other half of the same fact. Draugr finds `sbx` for you, but your shell does not. Most of what
you need has a `dr-*` wrapper. But a few things have no reason for one, because they belong to sbx,
not to Draugr: `sbx secret`, `sbx diagnose`, `sbx reset`. You type those yourself.

Run them from a Windows terminal, where `sbx` is already on `PATH`. That is doubly important for
commands that open a browser, such as an OAuth sign-in. To have it in WSL too, use a **function,
not an alias**. The path contains a space, and alias expansion does not quote it. Thus
`sbx secret ls` splits into a command that does not exist.

```bash
export DRAUGR_SBX="$(wslpath "$(cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '
')")/DockerSandboxes/bin/sbx.exe"
sbx() { "$DRAUGR_SBX" "$@"; }
```

Draugr itself reads `DRAUGR_SBX` first, so one line serves both.

### `sbx` commands hang, or say the daemon is unreachable

```powershell
sbx daemon status
sbx diagnose
```

The hypervisor features need a reboot after you enable them, and people easily skip it.
`sbx diagnose` reports host configuration problems that Draugr cannot see.

### `<path> is not on a Windows drive`

`sbx.exe` takes Windows paths. Thus `sbx` cannot mount a repo on the ext4 of WSL. Move the project
under `/mnt/c/`, and work on it there.

A drive letter mapped to a WSL path with `subst` does not help. We tested it end to end, and it
fails at the container, not at Draugr. The full sequence is in
[DESIGN.md](DESIGN.md#repos-on-ext4-via-a-subst-drive).

### `jq: command not found`

```bash
sudo apt install jq
```

Draugr parses `sbx ls --json` with `jq`, not by hand, because a JSON parser by hand in bash is
exactly the fragile trick that this project must not contain.

---

## Sessions

### `dr-go` refuses: uncommitted changes

The sandbox gets a **clone**, and a clone contains only the committed history. Your uncommitted work
is not in it, and the agent silently builds on old code. Commit, stash, or:

```bash
dr-go --dirty
```

Paths that match `DRAUGR_DATA` are already exempt. Thus changed data alone does not cause this.

### `dr-go` refuses: credential-shaped files

`dr-scan` found something that the agent can read through the read-only mount. That mount shows your
*full* working tree, also files in .gitignore. Refer to
[SECURITY.md](SECURITY.md#trap-1--what-the-agent-can-read). Move the file out of the repo. If you
are certain, `DRAUGR_SCAN_FAIL=warn` changes the refusal into a warning.

### `dr-go` needs a terminal

`sbx run` attaches an interactive session. Without a TTY, it gets part of the way in, and dies with
`inspect exec: context deadline exceeded`, which tells you nothing. Draugr tests this first, and
says so. To run one command with no terminal:

```bash
dr-shell -- <command>
```

### Ctrl+Z kills the session with "inspect exec: context deadline exceeded"

You use `DRAUGR_ATTACH=sbx`. To make sure, run `dr-config DRAUGR_ATTACH`. The default is `ssh`,
where Ctrl+Z works correctly.

`sbx run` and `sbx exec` reach the sandbox through `sbx.exe`, a *Windows* binary that WSL runs
through interop. Thus Ctrl+Z suspends the relay, and nothing inside the mound. The keystroke never
arrives, the daemon stops hearing from its client, and a few seconds later the session dies. Nothing
in the mound is lost, because the sandbox never noticed. But the terminal of the agent is gone, and
with it all that the agent did not commit.

With `ssh`, Ctrl+Z suspends the agent, and leaves you in a shell **inside the mound**. `fg` takes
you back, with the session as you left it.

### Codex refuses every prompt: "model is not supported ... with a ChatGPT account"

```text
ERROR: {"detail":"The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT account."}
```

**This is not a login problem**, though it looks like one. `sbx secret ls` shows
`openai (oauth configured)` all the time, and a new sign-in changes nothing. A copy of files from a
Codex that you logged in to under WSL also does not help. `sbx` never reads `~/.codex/auth.json`
from either home. Its proxy authenticates for the agent, with a credential that it holds itself.

The cause is the model. `sbx` writes `model_provider = "sandboxd"` into the `config.toml` of the
mound, and no `model`. Thus Codex uses its own built-in default. On a ChatGPT plan, your account
often does not have that default. Name one that it has:

```bash
DRAUGR_AGENT_ARGS="--model gpt-5.6-terra"      # then: dr-go
```

To see the models of your account, read the model cache that a Codex on the host writes after you
log in:

```bash
jq -r '.. | .id? // empty' ~/.codex/models_cache.json | sort -u
```

No recreate is necessary. Draugr passes `DRAUGR_AGENT_ARGS` at attach, not at creation.

### Every prompt fails with `401 OAuth access token has expired`

Nothing in the mound is wrong, and it is not about `DRAUGR_MODEL`. The credential of the agent is
on the host. The proxy of `sbx` rewrites the authorization header of each request to the hosts of
Anthropic, whatever the mound sent. When the stored token expired, each prompt gets that 401.

`sbx secret ls` does not help. It reports that a secret exists, not that it works. `sbx diagnose`
does not test the expiry either. Repair it from a Windows terminal, with no arguments, for the
interactive scope and service picker:

```powershell
sbx secret set
```

Two things look like fixes, but are not. `ANTHROPIC_API_KEY` in your shell changes nothing. Draugr
sends only `DRAUGR_ENV` and the `DRAUGR_MODEL` variables into the mound, and the ssh proxy of sbx
ignores `AcceptEnv`. `DRAUGR_ENV` cannot reach it either, because the proxy overwrites the header,
whatever the mound sent. The only control is the secret store. It also takes an entry for one
sandbox, which wins over the global one:

```powershell
sbx secret set draugr-<project> anthropic
```

The banner does not warn you. Claude Code prints `API Usage Billing` for each
`ANTHROPIC_AUTH_TOKEN`, also the placeholder that `DRAUGR_MODEL` writes. Thus a mound with no
working credential looks authenticated until the first prompt.
### The agent seems to have forgotten everything

Almost certainly the project-key trap. Memory is filed under a key that comes from the absolute path
of the project, and that path is different on each side of the boundary.

```bash
dr-mem status       # shows all three keys and what is on each side
```

If the mound has a project directory under a key that Draugr did not predict, `dr-mem` says so, and
lists what is really there. Refer to [WORKFLOW.md](WORKFLOW.md#memory).

### The agent can read a memory but cannot write new ones

`sbx cp` writes files as `root:root`, while the agent runs as uid 1000. `dr-mem import` changes the
owner afterwards. If that step failed, you saw a warning. Fix it by hand:

```bash
dr-shell -- sudo -n chown -R agent:agent ~/.claude/projects/<key>/memory
```

---

## Getting work in and out

### `dr-sync` says there is nothing, but the agent definitely committed

Look at the mound, not at the tracking ref:

```bash
dr-status
```

The tracking ref only says what was true at your last `dr-sync`. If the agent committed to a branch
that is not `DRAUGR_BRANCH`, `dr-sync` does not see it.

### `dr-merge` refuses

It does not merge onto a dirty tree. Commit or stash first. It reports "Nothing to merge" as success,
not as an error. A session where the agent committed nothing is a normal result.

### I removed the sandbox and lost work

`sbx rm` copies fetched branches to `refs/sandboxes/<name>/*` on the host, and **those stay after the
removal**. Look there before you assume that it is gone:

```bash
git for-each-ref refs/sandboxes/
```

That is also why `dr-rm` asks the mound directly, and does not trust a local ref, and why it refuses
by default.

### A web server in the sandbox is not reachable from Windows

Ports must be published, and Draugr publishes them to Windows loopback:

```bash
dr-ports 5173          # on a running mound
DRAUGR_PORTS="5173:5173"   # or in config, for every session
```

This is also the reason why `dr-sync` uses `ssh://`, and not the `git://` daemon. The daemon binds
only the Windows loopback, which WSL2 cannot reach across its NAT, and its port changes on each start.

---

## Builds and the network

### Builds fail with network errors

The sandbox denies each host that matches no allow rule. Find what is really in force:

```bash
dr-policy --check registry.example.com
dr-policy --allow registry.example.com     # temporary, on the running mound
```

Then move it into the `caps.network.allow` of the kit, so that it stays after a recreate. Remember
that ~190 machine rules already apply. Thus the domain can be allowed by a rule that you did not
write. `dr-policy --defaults` lists those.

### The kit changed but the sandbox did not

An apply of a kit recreates the container. Thus Draugr does not do it as a side effect. `dr-up` warns
about the drift, and the fix depends on the change:

```bash
dr-kit validate     # before you find out the hard way
dr-kit apply        # kits ADDED to the end of DRAUGR_KIT: added in place, clone kept
dr-up --recreate    # a kit EDITED, removed or reordered: the only thing that applies it
```

`dr-kit apply` tells you which one you need. It cannot do the second, and `sbx` cannot either.
`kit add` refuses a kit that the sandbox already has (`duplicate kit name`). When it adds another, it
leaves the old rules in force *(measured)*. Thus a host that you deleted from a kit stays reachable.
If `sbx` itself gives `duplicate kit name`, that is the same thing.

### `dr-up` fails with `500 Internal Server Error: failed to run sandbox container`

That is all that sbx tells you, and it is not sufficient. Its daemon knows exactly what happened, and
`dr-up` now prints it under `sandboxd recorded:`: the failed command, its exit code and its captured
output. If your `dr-up` is older, or the log moved, read it yourself:

```bash
# $DRAUGR_SBX is the path to sbx.exe - see "sbx: command not found" above
log="$(dirname "$(dirname "$DRAUGR_SBX")")/sandboxes/state/sandboxd/daemon.log"
jq -r 'select(.level == "ERROR") | .error' "$log" | tail -1
```

The most common cause by far is a kit install command that reads a project file.
**`commands.install` runs before your repository is in the workspace.** At that time, the working
directory is empty, and the repo is read-only at `/run/sandbox/source`. We measured this with sbx
0.37.1, in both clone and mount mode. Thus this fails:

```yaml
- command: "uv pip install -r requirements.txt"     # error: File not found
```

and this works:

```yaml
- command: "uv venv /home/agent/.venv"
- command: "uv pip install --python /home/agent/.venv/bin/python -r /run/sandbox/source/requirements.txt"
```

The virtual environment also goes outside the workspace. The agent session fills that directory
later, so all that is left in it is at risk.

> `dr-kit validate` does not catch this. The kit is fully valid, because the schema does not know
> whether a command can find its files.

### `rsync` is missing inside the mound

It is in the `claude` image (`/usr/bin/rsync`), but possibly not in each agent image. If it is
missing, `dr-up` installs it at creation. If that fails, it uses `tar` over ssh. `tar` is always
present, but copies full files, not only changes.

---

## Data transfers

### `dr-data` moved more than I expected

Before a transfer, look at what the patterns really mean:

```bash
dr-data status      # dry run, both directions, with sizes
```

An entry with no slash is **unanchored**, and matches at each depth. Thus `*.sample` also matches
`vendor/x/y.sample`. Draugr always excludes `.git` and `.draugr`, whatever your patterns say.

### `dr-data` deleted something

`DRAUGR_DATA_DELETE` also removes deleted files, and even with it on, each run asks first. If you
lost generated output, a `push` ran after you cleaned that directory on the host. There is no undo.
That is why the default is `false`.

---

## Last resorts

### Sandbox will not start: "block device … used by another process"

A previous VM did not shut down cleanly.

```powershell
sbx stop <name>
sbx ls                 # confirm it is actually stopped
```

If it stays, reboot. This is a host problem, below all that Draugr can reach.

### `sbx rm` fails with "stdin is not a terminal"

`dr-rm` already passes `--force` for this reason. It also removes a sandbox with an old SSH connection
open. If you call `sbx` directly, add `--force` yourself.

### Start over completely

```powershell
sbx reset              # destroys ALL sandboxes and sbx state, including the skills store
```

First export all that you want to keep: `dr-mem export` for each project. Also, `sbx reset` clears
the shared skills store.

---

## Reporting a problem

Include the output of `dr-doctor`, `sbx version`, and the command run again with `DRAUGR_DEBUG=1`.
The last one prints each `sbx` command line that Draugr built. That is usually sufficient to see what
went wrong, with no copy of your machine.
