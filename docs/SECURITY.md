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
on every `dr-go`. Those three count **hidden** directories too, and that is not a formality: measured
against Claude Code 2.1.221, a store entry named `.hidden-probe` appears in Claude's own list of
available skills exactly like a visible one. What Claude does *not* read is anything a level deeper.
So depth is the limit, not the dot — and a review that skipped dot-directories would have a blind
spot precisely where someone would put one.

There is **one** store, not one per agent. `sbx skills import --help` describes five per-agent host
directories being collapsed into a single store with a single namespace; only the mount path varies
by agent. So a skill left behind in a codex mound is in reach of your claude mounds, and vice versa.

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

## The data channel has no commit to read

Everything above concerns what the agent can *read*. `DRAUGR_DATA` is the other direction:
`dr-data pull` writes agent-authored bytes into your working directory over rsync.

Git content gets reviewed because `dr-merge` makes you look at a commit first. A pull has no commit.
rsync reports `12 files, 4.1 MB` — a receipt, not a review — and then the bytes are on your disk.
Three things follow, and the second one surprised us.

**Pulled files land executable, and `DRAUGR_DATA_CHMOD` does not stop it.** The transfer passes
`--chmod=D755,F644`, which looks like it normalises modes in both directions. It does not. A Draugr
repo must live on a Windows drive, and DrvFs ignores `chmod` — measured, a file rsync'd onto `/mnt/c`
with that flag lands `-rwxrwxrwx`, passes `test -x`, and runs. The key is doing its real job on the
way *in* (host modes are 0777 and should not be carried into the mound); on the way *out* it is
decorative. Nothing here is exploitable on its own — Draugr never executes a data file — but "it
arrives read-only" would have been a false comfort, so it is not claimed.

**So the name is what gets flagged.** Since the mode carries no signal, `dr-data status` and
`dr-data pull` classify incoming files by name and warn about anything shaped like something you or a
build step might run — `.sh`, `.py`, `.ps1`, `.exe`, `.so`, `Makefile`, `Dockerfile` and friends. A
pull with one of those in it asks before transferring. It asks rather than refuses: a project whose
data legitimately contains scripts would otherwise be unable to pull at all, and a guard you cannot
satisfy is a guard people switch off. The list is deliberately narrow — `.bin`, `.ts` and `.dat` are
left out — because a warning that fires on every parquet file is one you learn to scroll past.

**`dr-data diff` is the review step.** It fetches what a pull would write into `.draugr/tmp`, which is
excluded from every transfer, and shows a real unified diff against your copy. Text files up to
[`DRAUGR_DATA_DIFF_MAX`](CONFIG.md#draugr_data_diff_max) (256 KB) are shown in full; larger ones and
binaries are reported by name and size, because a diff of a 4 GB CSV helps nobody. It is a separate
command rather than part of `pull` for the same reason: fetching every changed file to compare it is
real work and real bytes, so you ask for it.

### Paths are checked by Draugr, not only by rsync

Both auto-writes — `dr-mem export` via `sbx cp`, and `dr-data pull` via rsync — copy sandbox-authored
content onto the host, and both rely on the copy tool to be traversal-safe. Modern rsync strips a
leading `/` and refuses `..`; `sbx cp` recreates symlinks rather than dereferencing them, and Windows
blocks the symlink creation without privilege, so the worst observed case is a failed export rather
than an escape.

That residual risk lives in `sbx` and `rsync`, not in Draugr's logic. But "the copy tool probably
handles it" is a dependency, not a guarantee, so `dr-data` checks the names itself before writing:
absolute paths, any `..` component, and control characters are refused, and a pull that sees one
stops entirely rather than prompting. Control characters are in that list for a second reason — a
newline in a filename would truncate the line-per-file listing the review itself is built on, and a
review that silently shows you less than what is arriving is worse than none.

### Nothing rides out on the ssh transport

The `*.sbx` block `dr-setup` installs uses `SendEnv LANG LC_*`, an allowlist. It previously said
`SendEnv *`, which offered every variable in your WSL environment to the sandbox. Measured against
`sbx 0.37.1` that leaked nothing — the proxy honours no `AcceptEnv` at all, so not even `LANG`
crosses — which made the wildcard pure downside: it forwarded nothing while standing ready to forward
your tokens the day a future `sbx` starts accepting them. A test fails if it ever comes back.

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

---

## Opening a host port to the mound

[`DRAUGR_HOST_PORTS`](CONFIG.md#draugr_host_ports) and `dr-hostport` let a mound reach a service on
your own machine. It is the most serious hole Draugr will open for you, and it is worth being clear
about why: everything else here is about what the agent can do *inside* a box. This is a door in the
wall of the box, and on the other side is a process running as you, outside it.

Two things follow.

**The service must be bound to `0.0.0.0`, not `127.0.0.1`.** From inside the mound, `127.0.0.1` is
the *mound*. This is the mistake worth knowing about in advance, because it fails in the same way a
policy denial does — the connection is accepted by the sandbox's interception layer and dropped, with
no error to read. `dr-hostport` warns when it can see it.

**Most local services have no authentication at all**, because they were written for a threat model
in which only you can reach them. That assumption stops being true the moment you open the port. A
local Ollama is the clearest example: the same port that serves inference also serves `POST
/api/pull`, `POST /api/create` — which reads local files — and `DELETE /api/delete`. "Let the agent
use my GPU" and "let the agent delete my models" are one permission.

The answer is not to leave the port shut but to open a narrower one. Put a reverse proxy in front
with a default-deny allowlist, bind the *service* to loopback, and open only the proxy's port:

```
Ollama        127.0.0.1:11434    loopback only - nothing off-host can reach it
proxy         0.0.0.0:11435      the only way in, query-only
the mound     DRAUGR_HOST_PORTS="11435"
```

That is strictly **less** exposed than binding the service itself to `0.0.0.0`, because the
management API ends up with no listener anything outside the host can reach.

[`share/ollama-proxy/`](../share/ollama-proxy/) is a worked example of exactly this, for Ollama — a
private nginx instance that touches nothing under `/etc/nginx` and needs no root. It is optional and
independent of Draugr; read its README before running it. Start it from a `post-up` hook rather than
inventing a config key: that hook already runs on the host at every `dr-up`, and it is trust-checked.

What a proxy cannot do is worth stating too. It cannot stop an application from pinning your GPU with
entirely legitimate requests, it cannot see which model a request asks for without inspecting the
body, and it cannot stop prompt content being used as a channel — anything the application can read,
it can send. Path filtering buys you the difference between *querying* and *administering*, which is
a large difference, and not the same as safety.

## Running the agent on a local model

[`DRAUGR_MODEL`](CONFIG.md#draugr_model) points the agent at a model you host instead of its vendor's
cloud. Two claims get made about that, and only one of them survives contact with this document.

**It is not about the credential.** The agent's token never entered the mound in the first place:
`sbx`'s proxy authenticates each request on the host, on the agent's behalf. Measured from inside a
mound against `api.anthropic.com`: a junk bearer token, the proxy's own sentinel, and *no
authorization header at all* produced the same answer — the one that exists only if a real token
reached Anthropic. The same requests from the host, outside the proxy, came back `Invalid bearer
token` and `x-api-key header is required`. The proxy rewrites the header for `api.anthropic.com`,
`console.anthropic.com`, `claude.ai` and `mcp-proxy.anthropic.com` whatever the mound sent.

That is a stronger property than "the token is not in the mound", and it cuts both ways: **the mound
cannot present a credential of its own to those hosts either.** No environment variable changes it —
not `DRAUGR_ENV`, not the placeholder `ANTHROPIC_AUTH_TOKEN` that `DRAUGR_MODEL` writes. The one
lever is `sbx secret` on the host, where a sandbox-scoped entry beats the global one.

It is also why signing in after a mound was built needs no rebuild, and why an expired token surfaces
as a 401 on every prompt rather than as a login screen. `SBX_CRED_ANTHROPIC_MODE` cannot tell those
apart — it reports `none` for an OAuth login exactly as it does for no credential at all — so do not
key anything off it; [TROUBLESHOOTING.md](TROUBLESHOOTING.md) carries the symptom. Nothing
`DRAUGR_MODEL` does improves on any of this, because there was nothing to improve.

**And it is not, by itself, an egress guarantee.** This is the one worth being blunt about, because
the feature invites exactly the wrong conclusion. What `DRAUGR_MODEL` changes is where the agent
sends your code *by design* — the one channel Draugr builds for it. It changes nothing about what the
mound can *reach*. Every one of `sbx`'s ~190 default allow rules is still in force, and as
[The network policy](#the-network-policy) says, those cover the common code hosts, the package
managers **and the AI service endpoints**. So on a stock policy the mound running a local model can
still open a connection to the very service you switched away from.

> **A local model closes the designed channel, not the network.** "My code does not leave this
> machine" is a claim about the policy, not about `DRAUGR_MODEL`, and setting one without narrowing
> the other buys you a feeling rather than a property.

### Making the claim true, and what it costs

The other half is kit `deny` rules, which beat the machine-wide allows. Read what you would be
closing first — `dr-policy --defaults` lists the rules you did not write, and `dr-policy --check
<host>` answers for one — then deny what the work does not need.

The cost is not small, and it is the reason this is a posture rather than a default. A mound that
cannot reach the package managers cannot install anything, which for most projects means the setup
commands in the kit have to have finished the job at creation, from a cache, once. A mound that
cannot reach `github.com` cannot fetch a dependency the agent decides it wants. Whether that is
tolerable is entirely use-case dependent: for review, refactoring and writing against a tree that is
already complete, it is barely noticeable; for greenfield work in a language with a live dependency
resolver, it is unworkable.

So the honest ordering is: narrow the policy until the work stops, widen it one rule at a time, and
treat `DRAUGR_MODEL` as the thing that lets you close the largest hole rather than as the thing that
closes it.

### The trade runs both ways

Reaching a model on your own machine means opening a host port, which the section above calls the
most serious hole Draugr will open for you. So this buys a narrower egress surface with a new ingress
one. That is usually a good trade, and it is only a good trade if the port you open is narrow.

### Why the default port is 11435

Ollama has no authentication and no read-only mode, so `11434` serves inference and administration
through one door. [`DRAUGR_MODEL_URL`](CONFIG.md#draugr_model_url) therefore defaults to `11435`, the
query-only proxy in [`share/ollama-proxy/`](../share/ollama-proxy/), so the arrangement you get
without reading anything is the safe one:

```
Ollama        127.0.0.1:11434    loopback only - nothing off-host can reach it
proxy         0.0.0.0:11435      the only way in, query-only
the mound     DRAUGR_HOST_PORTS="11435"
```

Measured against that proxy on nginx 1.24.0 and Ollama 0.32.14, with the shipped allowlist unchanged:

```
POST /v1/messages            200      POST /api/pull        403
POST /v1/chat/completions    200      POST /api/create      403
GET  /v1/models              200      DELETE /api/delete    403
GET  /api/version            200      GET  /v1/files        404
```

The first column is what an agent needs and the second is what it must not have. `/v1/messages` is
the endpoint Claude Code speaks, and it was already inside the allowlist — the `/v1/` prefix was
passed through whole because that surface carried no management verbs, and Ollama's Anthropic
compatibility landed inside it.

Because that default assumes the proxy, Draugr checks for it rather than trusting it: a `GET
/healthz` answering `200` is the proxy, a `404` means the agent has been pointed straight at an
Ollama it can also administer, and no answer at all means the session cannot work — `dr-go` refuses
to attach rather than handing you an agent that fails at its first prompt. See
[What checks that the model is really there](CONFIG.md#what-checks-that-the-model-is-really-there).


`DRAUGR_ENV` sets arbitrary variables in the agent's session. That is no more reach than a project
config already has — it is shell, and Draugr runs it — so it is gated by the same `dr-trust`
acceptance rather than by a rule of its own. `PATH` and `HOME` are refused outright, because both
replace rather than extend and a replacement inside the mound breaks the session before it starts.

### What this does not buy

- **Not a reason to relax anything else.** A local model is still an agent running commands in a
  sandbox. Every other boundary in this document applies unchanged.
- **Not privacy from the model's operator**, when `DRAUGR_MODEL_URL` names someone else's endpoint. A
  company LLM gateway is somebody's server with somebody's logs. Only a URL resolving to your own
  machine makes the egress argument above available at all; the key cannot tell the difference and
  does not try.
- **Not protection from what the agent puts in a prompt.** Anything it can read, it can send to
  whatever endpoint it has. Narrowing the endpoint narrows the audience, not the channel.
- **Not the same quality.** A model that fits on one GPU is meaningfully worse at long tool chains
  than the hosted one, and Draugr's loop is nothing but long tool chains. This is a tier for work
  that cannot leave the machine, not a cheaper way to do the same work.

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
| `dr-data pull` with runnable-looking files incoming | confirm at the prompt, after `dr-data diff` |
| `dr-data pull` offering an absolute or `..` path | none — inspect the mound |
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
