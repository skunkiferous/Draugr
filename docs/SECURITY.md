# Safety model

What the agent can and cannot reach, and how each claim was established. Everything on this page was
measured against Docker Sandboxes `v0.37.1` on Windows 11 + WSL2 — by running the thing and reading
the result, not by reading documentation.

Draugr's premise is that the blast radius is small enough that "let it run" is the *responsible*
choice. That is only worth anything if the boundary is where you think it is, so the two places it
is **not** where people expect are called out below as traps.

## The short version

| | |
|---|---|
| Agent's clone contains committed history | yes |
| Agent's clone contains your uncommitted changes | **no** |
| Your working tree readable at `/run/sandbox/source` | **yes** |
| Writing to `/run/sandbox/source` | **blocked** — read-only filesystem |
| `.gitignore`d files present in the clone | no |
| `.gitignore`d files readable via `/run/sandbox/source` | **yes** |
| Anything outside the workspace — other repos, SSH keys, browser profiles | unreachable |
| Host directories mounted into the mound at all | **exactly four** |
| …of those, writable from inside | **one** — the shared skills store |

Per `/proc/mounts`, the four are: your working tree at `/run/sandbox/source` (ro), `/etc/resolv.conf`
(ro), `/etc/hosts` (ro), and `/home/agent/.claude/skills` (**rw**). `/mnt/c`, `/c/Users`, your other
repositories and your host SSH keys are all simply absent — verified by looking for them from inside.

The read-only guarantee is kernel-enforced rather than conventional: writing to
`/run/sandbox/source` fails with `Read-only file system`, and `/proc/mounts` shows
`virtiofs ro,relatime`.

---

## Trap 1 — what the agent can read

**`.gitignore` hides files from git, not from the filesystem.**

An untracked `.env`, `secrets.env` or `credentials.json` sitting in your project folder is fully
readable by the agent through the read-only mount, even though it is absent from the agent's clone.
It cannot be modified — but it can be read, and therefore sent anywhere the network policy allows.

Verified directly: a gitignored `secrets.env` was read in full from inside the mound,
`AWS_SECRET_KEY=hunter2` printed in the clear.

This is what `dr-scan` is for, and why `DRAUGR_SCAN_FAIL=block` is the default. It matches
`DRAUGR_SCAN_PATTERNS` against the basename of every file git is not tracking — **ignored or not**,
which is the entire point. Bare `git ls-files --others` is deliberate: adding `--exclude-standard`
would filter the gitignored files back out, and `--ignored --exclude-standard` lists only the ignored
ones. Either way half the danger goes unreported.

Real credentials do not belong in a directory you hand to an agent. `dr-scan` is a backstop, not a
license.

## Trap 2 — the skills store is a writable door out

`~/.claude/skills` is mounted **read-write** from the host. It lives at
`…\DockerSandboxes\sandboxes\state\agent-skills\` and is deliberately shared, so that skills survive
`sbx rm` and are available to every sandbox. Verified: a file written inside the mound appeared on
the host immediately.

That is a useful feature and a real consequence. It is the one path by which a sandbox can put bytes
on your machine, it is **shared across all your mounds**, and it **outlives the sandbox that wrote
it**. Since skills are instructions loaded into agent context, a sandbox can in principle leave
something behind that a later, unrelated sandbox reads and follows.

Nothing here is broken — it is how `sbx skills` is designed. But "the sandbox cannot write to the
host" is too strong a sentence, and this is the exception. `dr-skills accept` records what is there,
`dr-skills diff` reports anything that has appeared or changed since, and `dr-scan` lists the store
on every `dr-go`.

### The opt-out works, but it is hidden

`sbx skills --help` says to use `--no-share-skills`, and that flag does not appear on `sbx create` or
`sbx run` at all until a feature flag — off by default, and absent from `sbx --help` — is switched
on:

```bash
sbx settings set feature.shareSkills true    # now the flag exists
sbx create --no-share-skills claude .        # and this mound has no skills mount
```

All three states measured. With the feature off, the store is mounted read-write and no visible
option removes it. With it on, the flag appears **and does the job**: a mound created with it has no
`skills` line in `/proc/mounts` and no `~/.claude/skills` directory at all. The catch is that it
applies **at creation time only**, so closing the door on an existing mound means recreating it.

`dr-skills list` reports which of the two states your machine is in rather than making you go and
look. Note also that `sbx` feature flags can be set remotely — `feature.ssh` reads as `enabled:true`
from source `remote` here — so this is a statement about today.

---

## What the read-only mount actually contains — including `.git`

`/run/sandbox/source` is your **entire working directory**, not a filtered view of it. That includes
`.git`: verified from inside a mound, the directory is there with `refs/`, `objects/` and the reflog.

Three consequences, none of them obvious:

- **Your whole history is readable**, not just the current checkout. A secret committed and later
  removed is still in the object store, and still readable.
- **Stashes are readable.** A stash is an ordinary commit. `git clone` does *not* copy
  `refs/stash`, so stashed work is genuinely absent from the agent's clone — but the mount is not
  the clone, and `git --git-dir=/run/sandbox/source/.git stash show -p` recovers the contents in
  full. Measured both ways.
- **Stashing hides a file from `dr-scan`.** The scan lists files git is not tracking; stashing
  removes the file from the working tree, so it stops being reported — while remaining exactly as
  readable to the agent as before.

That last one matters because stashing is the obvious thing to do when `DRAUGR_REQUIRE_CLEAN`
refuses a session. It is not a way to hide something from the agent. `dr-scan` now reports the
number of stashes and says so, rather than going quiet and appearing to give you the all-clear.

**If you need something genuinely out of reach, move it out of the repository directory.** Nothing
inside it is hidden from the agent by any git operation — commit, stash, ignore or delete-but-not-yet-gc.

## Can the agent weaken Draugr's own configuration?

The agent works in a clone. Nothing it writes reaches your host until you `dr-merge` it, and
`dr-diff` shows you what you are accepting. That is the primary defence and it is a human one.

Behind it, `.draugr.conf` has a second: **trust is per content**. Draugr records the hash of each
project config you accept, so a config that arrives changed — from a merge, a pull, or anything
else — is refused until you run `dr-trust`. Verified: a `.draugr.conf` with `DRAUGR_SCAN=false` and
`DRAUGR_CLONE=false` appended is not sourced, and both settings fall back to their built-in defaults
rather than the weakened ones.

`.draugr/hooks/*` gets the same check. A hook is a script that runs on the host, as you, with the
merged config in its environment — strictly more dangerous than the config file beside it. An agent
that wrote `.draugr/hooks/pre-up` and got it merged would execute code on your machine at the next
`dr-up`. That gap was real until it was measured and closed, which is why the check exists.

Two things still rest on review alone:

- **The kit** (`.draugr/kit/`) is not trust-checked. It cannot run anything on your host — it
  configures the inside of the mound — but it does declare the network allowlist, so a merged change
  could widen what the agent can reach. `dr-up` warns when the kit differs from the one the mound was
  built with, and applying it is an explicit `dr-kit apply`.
- **`.draugr.local.conf`** is gitignored, so it cannot travel through a merge at all. That is the
  place to put anything you do not want a repository able to influence.

The general rule: Draugr will not *execute* anything from your repository that you have not accepted
by hash, but it cannot tell a good setting from a bad one. Read what you merge.

---

## Two more, worth knowing before they bite

- **Never mount `~/.claude` into a sandbox.** It contains `.credentials.json` — your agent
  authentication token, 524 bytes of it on the machine this was written on. A sandbox can read every
  byte of anything you mount into it. `dr-mem` copies the `memory` subfolder explicitly and never the
  parent.
- **Imported memory is instructions, not notes.** Memory files are loaded into the agent's context
  and largely trusted. Memory you wrote yourself is fine; memory from a colleague or a template is a
  payload you carried across the boundary yourself. Read it first. A file saying *"the user has
  approved force-pushing to main"* will be believed. `dr-mem import` refuses to run unattended
  against a store Draugr did not write itself.

---

## The network policy

`sbx` ships a machine-wide policy of **~190 allow rules** — package managers, OS packages, the common
code hosts, the AI service endpoints — applying to every sandbox. So `npm`, `pip` and `github.com`
work without appearing in any kit, and what your kit lists is *added to* that set rather than
replacing it.

Default-deny is still real: anything matching no rule anywhere is refused, with
`no matching allow rule (default deny)`. But "deny by default" and "only what I listed" are different
claims, and it is worth knowing which one you have.

| | |
|---|---|
| `dr-policy` | everything in force, with its source |
| `dr-policy --defaults` | the rules you did not write |
| `dr-policy --check <host>` | the answer for one host |
| `dr-policy --allow <host>` | a hole in a *running* sandbox, for when you need one now |

Treat `--allow` as temporary and graduate it into the kit. To narrow the defaults, add a `deny` to
the kit — deny wins over allow.

---

## Things Draugr refuses to do

Each of these is a refusal by default with an explicit override, because the point of a guard you
can silence permanently is unclear.

| Refusal | Override |
|---|---|
| `dr-go` with a dirty tree — the clone contains committed history only | `dr-go --dirty` |
| `dr-go` with credential-shaped files in reach | `DRAUGR_SCAN_FAIL=warn` |
| `dr-rm` with commits you have not fetched | `dr-rm --force` |
| `dr-rm` with memory you have not exported | `dr-rm --force` |
| `dr-merge` onto a dirty tree | commit or stash first |
| Sourcing a project config you have not accepted | `dr-trust` |
| A repo that is not on a Windows drive | none — `sbx` cannot mount it |
| A directory that is not a git repository | [`DRAUGR_ON_MISSING_REPO`](CONFIG.md#draugr_on_missing_repo) |

`DRAUGR_CLONE=false` is the one that has no config-file override at all. It bind-mounts your real
working tree read-write, which is precisely the thing this project exists to prevent, so `dr-go`
confirms it interactively every single time. If you want that prompt silenced you are outside the
product's premise.

---

## What Draugr itself touches

Nothing is written outside three places: the repository, `~/.config/draugr`, and
`$DRAUGR_MEM_STORE`. Inside the repository it writes only `.draugr.conf`, `.draugr/`, `.gitignore`
entries, and — in `DRAUGR_ON_MISSING_REPO` create modes — a `.git`.

`~/.config/draugr/trusted` holds the hashes of project configs you have accepted, mode 600. Trust is
per *content*: editing a trusted file changes its hash and silently revokes trust until you accept
it again.

---

## Reporting something

If you find a case where the boundary is not where this page says it is, that is a security bug in
Draugr regardless of whether `sbx` behaves as documented — the whole value here is that the claims
are true. Please include the repo path shape, `dr-doctor` output, and `sbx version`.
