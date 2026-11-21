# Safety model

What the agent can and cannot reach, and how we found each claim. The original measurements below
use Docker Sandboxes `v0.37.1` on Windows 11 + WSL2. They are version-specific. On **0.53.0**, a
new mound has a read-only shared skills mount, measured for both a claude and a codex mound. The
source mount remains read-only.
The writable-store claims below describe the older baseline. See [current agent evidence](AGENT-SUPPORT.md#compatibility-and-evidence).

Codex context transfer selects approved state before host staging or upload and refuses a global
host home. It excludes authentication, native configuration, logs, and plugin connection data.
Imports require a quiet target and preserve feature consent. Plugin publications contain inert
package files. Their private runtime data and hook trust remain in each consumer mound. These
controls do not make imported instructions or third-party plugins trustworthy, so review them.

Draugr rests on one idea: the possible damage is so small that "let it run" is the *responsible*
choice. That is worth something only if the boundary is where you think it is. Thus the two places
where it is **not** where people expect are named below as traps.

## The short version

| | |
|---|---|
| The clone of the agent contains committed history | yes |
| The clone of the agent contains your uncommitted changes | **no** |
| Your working tree is readable at `/run/sandbox/source` | **yes** |
| Writing to `/run/sandbox/source` | **blocked**: read-only filesystem |
| Files in `.gitignore` are in the clone | no |
| Files in `.gitignore` are readable through `/run/sandbox/source` | **yes** |
| All outside the workspace: other repos, SSH keys, browser profiles | unreachable |
| Host directories mounted into the mound | **exactly four** |
| …of those, writable from inside | **one**: the shared skills store |

By `/proc/mounts`, the four are: your working tree at `/run/sandbox/source` (ro),
`/etc/resolv.conf` (ro), `/etc/hosts` (ro), and `/home/agent/.claude/skills` (**rw**). `/mnt/c`,
`/c/Users`, your other repositories and your host SSH keys are all absent. We looked for them from
inside.

The kernel enforces the read-only guarantee. It is not a convention. A write to
`/run/sandbox/source` fails with `Read-only file system`, and `/proc/mounts` shows
`virtiofs ro,relatime`.

---

## Trap 1 — what the agent can read

**`.gitignore` hides files from git, not from the filesystem.**

The agent can fully read an untracked `.env`, `secrets.env` or `credentials.json` in your project
folder, through the read-only mount. It is not in the clone of the agent. The agent cannot change
it, but it can read it. Thus it can send it to all hosts that the network policy allows.

Tested directly: we read a `secrets.env` from .gitignore in full from inside the mound, and
`AWS_SECRET_KEY=hunter2` printed in the clear.

That is why `dr-scan` exists, and why `DRAUGR_SCAN_FAIL=block` is the default. It matches
`DRAUGR_SCAN_PATTERNS` against the basename of each file that git does not track, **ignored or
not**. That is the full purpose. Bare `git ls-files --others` is on purpose. `--exclude-standard`
removes the ignored files from the list. `--ignored --exclude-standard` lists only the ignored ones.
In both cases, half the danger is not reported.

Do not keep real credentials in a directory that you give to an agent. `dr-scan` is a backstop, not
a permission.

## Trap 2 — the skills store is a writable door out

`~/.claude/skills` is mounted **read-write** from the host. It is at
`…\DockerSandboxes\sandboxes\state\agent-skills\`, and is shared on purpose, so that skills stay
after `sbx rm`, and each sandbox can use them. Tested: a file written inside the mound showed on
the host at once.

**sbx 0.53 closes this door, but only for a mound that it builds.** A write to the store fails in a
new mound, measured in a claude mound at `~/.claude/skills` and in a codex mound at
`~/.agents/skills`. The mode is fixed when the mound is created, so an upgrade alone changes
nothing: a mound built by an older sbx keeps the writable store, and the rest of this section
describes it. Recreate a mound to close the door for that mound.

That is a useful feature with a real result. It is the one path by which a sandbox can put bytes on
your machine. It is **shared by all your mounds**, and it **lives longer than the sandbox that wrote
it**. Skills are instructions loaded into the context of the agent. Thus a sandbox can leave
something behind, and a later, unrelated sandbox reads and follows it.

Nothing here is broken. `sbx skills` works as designed. But "the sandbox cannot write to the host"
is too strong, and this is the exception. `dr-skills accept` records the contents. `dr-skills diff`
reports all new or changed entries since then. `dr-scan` lists the store on each `dr-go`. All three
also count **hidden** directories, and that is necessary. Measured with Claude Code 2.1.221: a store
entry named `.hidden-probe` shows in the own list of available skills of Claude, exactly as a
visible one does. Claude does *not* read anything one level deeper. Thus the limit is the depth, not
the dot. A review that skips dot-directories does not see exactly the place where somebody can put
one.

There is **one** store, not one for each agent. `sbx skills import --help` describes five host
directories, one for each agent, merged into a single store with a single namespace. Only the mount
path changes by agent. Thus a skill that a codex mound leaves behind is in reach of your claude
mounds, and the reverse.

### The opt-out works, but it is hidden

`sbx skills --help` says to use `--no-share-skills`. But that flag is not on `sbx create` or
`sbx run` until you switch on a feature flag. That feature flag is off by default, and `sbx --help`
does not show it:

```bash
sbx settings set feature.shareSkills true    # now the flag exists
sbx create --no-share-skills claude .        # and this mound has no skills mount
```

We measured all three states. With the feature off, the store is mounted read-write, and no visible
option removes it. With it on, the flag shows, **and it works**. A mound created with it has no
`skills` line in `/proc/mounts`, and no `~/.claude/skills` directory. But it applies **only at
creation**. To close the door on an existing mound, you must recreate it.

`dr-skills list` reports which of the two states your machine is in. Also, a remote source can set
`sbx` feature flags. Here, `feature.ssh` reads as `enabled:true` from the source `remote`. Thus this
statement is true only today.

---

## What the read-only mount actually contains — including `.git`

`/run/sandbox/source` is your **full working directory**, not a filtered view of it. That includes
`.git`. Tested from inside a mound: the directory is there, with `refs/`, `objects/` and the reflog.

Three results, none of them clear:

- **Your full history is readable**, not only the current checkout. A secret that you committed and
  removed later is still in the object store, and still readable.
- **Stashes are readable.** A stash is a normal commit. `git clone` does *not* copy `refs/stash`, so
  stashed work is really absent from the clone of the agent. But the mount is not the clone, and
  `git --git-dir=/run/sandbox/source/.git stash show -p` recovers the full contents. Measured both
  ways.
- **A stash hides a file from `dr-scan`.** The scan lists files that git does not track. A stash
  removes the file from the working tree, so the scan stops its report. But the agent can still read
  it exactly as before.

That last one is important, because a stash is the clear step when `DRAUGR_REQUIRE_CLEAN` refuses a
session. It does not hide something from the agent. `dr-scan` now reports the number of stashes and
says so. It does not go silent, and seem to say that all is clear.

**If you need something fully out of reach, move it out of the repository directory.** No git
operation hides anything inside it from the agent: commit, stash, ignore, or delete before gc.

## Can the agent weaken Draugr's own configuration?

The agent works in a clone. Nothing that it writes reaches your host until you `dr-merge` it, and
`dr-diff` shows what you accept. That is the main defense, and it is a human one.

Behind it, `.draugr.conf` has a second defense: **trust is for the content**. Draugr records the
hash of each project configuration that you accept. Thus a configuration that arrives changed, from
a merge, a pull or anything else, is refused until you run `dr-trust`. Tested: a `.draugr.conf` with
`DRAUGR_SCAN=false` and `DRAUGR_CLONE=false` added is not sourced. Both keys fall back to their
built-in defaults, not to the weaker values.

`.draugr/hooks/*` gets the same test. A hook is a script that runs on the host, as you, with the
merged configuration in its environment. That is more dangerous than the configuration file beside
it. An agent that wrote `.draugr/hooks/pre-up`, and got it merged, ran code on your machine at the
next `dr-up`. That gap was real until we measured and closed it. That is why the test exists.

Two things still rest only on review:

- **The kit** (`.draugr/kit/`) has no trust test. It cannot run anything on your host, because it
  sets up the inside of the mound. But it declares the network allowlist. Thus a merged change can
  widen what the agent can reach. `dr-up` warns when the kit is different from the kit of the build
  of the mound, and an explicit command applies it: `dr-kit apply` for a kit added to the list,
  `dr-up --recreate` for one that changed. The second is important here. `sbx kit add` keeps the old
  rules in force beside the new ones *(measured)*. Thus a kit edit that narrows the allowlist applies
  only on a rebuild. `dr-kit apply` refuses an edited kit for exactly that reason.
- **`.draugr.local.conf`** is in .gitignore, so it cannot travel through a merge. Put there anything
  that you do not want a repository to influence.

The general rule: Draugr does not *run* anything from your repository that you did not accept by
hash. But it cannot tell a good value from a bad one. Read what you merge.

## The data channel has no commit to read

All of the above is about what the agent can *read*. `DRAUGR_DATA` is the other direction.
`dr-data pull` writes bytes from the agent into your working directory over rsync.

Git content gets a review, because `dr-merge` makes you look at a commit first. A pull has no
commit. rsync reports `12 files, 4.1 MB`. That is a receipt, not a review, and then the bytes are on
your disk. Three results follow, and the second one surprised us.

**Pulled files arrive executable, and `DRAUGR_DATA_CHMOD` does not stop it.** The transfer passes
`--chmod=D755,F644`, which seems to set normal modes in both directions. It does not. A Draugr repo
must be on a Windows drive, and DrvFs ignores `chmod`. Measured: a file that rsync copied onto
`/mnt/c` with that flag arrives as `-rwxrwxrwx`, passes `test -x`, and runs. The key does its real
job on the way *in* (host modes are 0777, and must not go into the mound). On the way *out*, it
does nothing. Nothing here is a risk alone, because Draugr never runs a data file. But "it arrives
read-only" is a false comfort, so we do not claim it.

**Thus Draugr flags the name.** The mode gives no signal. Thus `dr-data status` and `dr-data pull`
classify incoming files by name. They warn about each file that looks like something that you or a
build step can run: `.sh`, `.py`, `.ps1`, `.exe`, `.so`, `Makefile`, `Dockerfile` and similar. A
pull with one of those in it asks before the transfer. It asks, and does not refuse. If not, a
project whose data really contains scripts can never pull. People turn off a guard that they cannot
satisfy. The list is narrow on purpose. `.bin`, `.ts` and `.dat` are not in it, because people learn
to ignore a warning that fires on each parquet file.

**`dr-data diff` is the review step.** It fetches what a pull writes into a staging directory that
belongs to the host, outside your checkout (see below), and shows a real unified diff against your
copy. It shows text files up to
[`DRAUGR_DATA_DIFF_MAX`](CONFIG.md#draugr_data_diff_max) (256 KB) in full. It reports larger files
and binaries by name and size, because a diff of a 4 GB CSV helps nobody. It is a separate command,
not part of `pull`, for the same reason. A fetch of each changed file for a comparison is real work
and real bytes, so you ask for it.

### Paths are checked by Draugr, not only by rsync

Both automatic writes copy content from the sandbox onto the host: `dr-mem export` through
`sbx cp`, and `dr-data pull` through rsync. Both depend on the copy tool to block path traversal.
Modern rsync removes a leading `/`, and refuses `..`. `sbx cp` makes symlinks again, and does not
follow them. Windows blocks the creation of a symlink without privilege. Thus the worst case that we
saw is a failed export, not an escape.

That remaining risk is in `sbx` and `rsync`, not in the logic of Draugr. But "the copy tool probably
handles it" is a dependency, not a guarantee. Thus `dr-data` tests the names itself before it
writes. It refuses absolute paths, each `..` component, and control characters. A pull that sees one
stops fully, and does not prompt. Control characters are in that list for a second reason. A newline
in a filename cuts short the list of one line for each file, which the review itself rests on. A
review that silently shows you less than what arrives is worse than none.

**One spelling is not one name.** A security review found, and a measurement confirmed, that the
list above was not enough. The sender is a Linux filesystem, where `.GIT` and `.git` are two
directories. The destination is a Windows drive, which Draugr requires, and there they are one. With
`--exclude=.git` in force, measured with rsync 3.2.7 on a real drive:

| the mound sends | what the host got |
|---|---|
| `.GIT/hooks-marker` | `.git/hooks-marker` |
| `GIT~1/config` | `.git/config`, **overwritten** |

The second one is not a case problem. `GIT~1` is the 8.3 short name of `.git`, which this volume
still generates — `dir /x` lists it — and Win32 resolves the alias, so a write through it is a write
to the long name. `.git/config` decides what git *runs* for you (`core.sshCommand`, `core.fsmonitor`,
every alias), so these two names reach the file the review exists to protect.

So the name check now works on each path component, and refuses the spellings that resolve to
something else: `.git` and `.draugr` **in any case**, their `~1` aliases, a trailing dot or space
(Win32 strips both, so `report.` writes `report`), a backslash (a *separator* on the destination),
and a colon (a drive prefix, or an alternate data stream). It still accepts `.gitignore`,
`my.git/` and every ordinary data name, because a guard that refuses those is a guard people
switch off.

**Draugr transfers bytes, not names that point somewhere.** `dr-data` now passes `--no-links
--no-devices --no-specials`, so a symlink in either direction is skipped rather than recreated. A
symlink is how two findings chained: a sender ships `.draugr/tmp` as a link to anywhere, and the
next host command that writes through it writes there. rsync still exits 0 when it skips one
(measured), so the preview reads the skip from rsync's output instead of trusting the status, and
refuses the pull rather than reporting an incomplete list.

**An empty review is not "nothing to pull".** The preview that `dr-data status`, `diff` and `pull`
all use was `rsync … 2>/dev/null | grep -v '/$' || true`: the status of *grep*, with even that
discarded. An unreachable mound or a missing rsync inside it produced an empty list, every caller
read it as "this pull lands nothing", and the transfer then ran unreviewed. A failed preview is now
fatal, and so is any line that is not a file name.

**Staging happens outside your checkout.** `dr-data diff` and `dr-mem export` stage files through a
directory on a Windows drive, because `sbx cp` can reach nothing else. That used to be
`.draugr/tmp/<pid>` inside the repository: a path that a mound with the repo bind-mounted can write,
deleted and recreated on every run. A link in its place redirected both the deletion and everything
staged afterwards. Staging is now `%LOCALAPPDATA%\Draugr\stage\stage.XXXXXXXX`, created with a
random name, refused if anything on the way is a link, and never deleted to make room. Set
`DRAUGR_STAGE_ROOT` to move it.

### Nothing rides out on the ssh transport

The `*.sbx` block that `dr-setup` installs uses `SendEnv LANG LC_*`, an allowlist. Before, it said
`SendEnv *`, which offered each variable in your WSL environment to the sandbox. Measured on
`sbx 0.37.1`, that leaked nothing, because the proxy ignores `AcceptEnv`, so not even `LANG`
crosses. Thus the wildcard was only a risk. It sent nothing, but was ready to send your tokens on
the day that a later `sbx` accepts them. A test fails if it ever comes back.

---

## Two more, worth knowing before they bite

- **Never mount `~/.claude` into a sandbox.** It contains `.credentials.json`, the authentication
  token of your agent: 524 bytes of it on the machine where we wrote this. A sandbox can read each
  byte of each mount. `dr-mem` copies only the `memory` subfolder, and never the parent.
- **Imported memory is instructions, not notes.** The agent loads memory files into its context,
  and mostly trusts them. Memory that you wrote yourself is safe. Memory from a colleague or a
  template is a payload that you carried across the boundary. Read it first. The agent believes a
  file that says *"the user has approved force-pushing to main"*. `dr-mem import` refuses to run
  unattended on a store that Draugr did not write itself.

---

## The network policy

`sbx` has a machine policy of **~190 allow rules**, for each sandbox. They cover package managers,
OS packages, the common code hosts, and the AI service endpoints. Thus `npm`, `pip` and `github.com`
work with no kit, and what your kit lists is *added to* that set. It does not replace it.

Default-deny is still real. A host that matches no rule is refused, with
`no matching allow rule (default deny)`. But "deny by default" and "only what I listed" are
different claims. Know which one you have.

| | |
|---|---|
| `dr-policy` | all rules in force, with their source |
| `dr-policy --defaults` | the rules that you did not write |
| `dr-policy --check <host>` | the answer for one host |
| `dr-policy --allow <host>` | a hole in a *running* sandbox, for when you need one now |

Use `--allow` only for a short time, then move the host into the kit. To narrow the defaults, add a
`deny` to the kit. Deny wins over allow.

---

---

## Opening a host port to the mound

[`DRAUGR_HOST_PORTS`](CONFIG.md#draugr_host_ports) and `dr-hostport` let a mound reach a service on
your own machine. It is the most serious hole that Draugr opens for you. Know why. All else here is
about what the agent can do *inside* a box. This is a door in the wall of the box, and on the other
side is a process that runs as you, outside it.

Two results follow.

**The service must be bound to `0.0.0.0`, not `127.0.0.1`.** Inside the mound, `127.0.0.1` is the
*mound*. Know this mistake in advance, because it fails in the same way as a policy denial. The
interception layer of the sandbox accepts the connection and drops it, with no error to read. If
`dr-hostport` can see it, it warns.

**Most local services have no authentication**, because they were written for a threat model where
only you can reach them. That assumption becomes false when you open the port. A local Ollama is the
clearest example. The port that serves inference also serves `POST /api/pull`, `POST /api/create`
(which reads local files) and `DELETE /api/delete`. "Let the agent use my GPU" and "let the agent
delete my models" are one permission.

The answer is not to keep the port shut, but to open a narrower one. Put a reverse proxy in front,
with a default-deny allowlist. Bind the *service* to loopback, and open only the port of the proxy:

```
Ollama        127.0.0.1:11434    loopback only - nothing off-host can reach it
proxy         0.0.0.0:11435      the only way in, query-only
the mound     DRAUGR_HOST_PORTS="11435"
```

That is strictly **less** exposed than the service itself on `0.0.0.0`, because the management API
then has no listener that anything outside the host can reach.

[`share/ollama-proxy/`](../share/ollama-proxy/) is a worked example of exactly this, for Ollama. It is
a private nginx instance that touches nothing under `/etc/nginx`, and needs no root. It is optional,
and independent of Draugr. Read its README before you run it. Start it from a `post-up` hook, and do
not make up a configuration key. That hook already runs on the host at each `dr-up`, and has a trust
test.

Also know what a proxy cannot do. It cannot stop an application from using all of your GPU with
fully legitimate requests. It cannot see which model a request asks for without a look at the body.
It cannot stop the use of prompt content as a channel: the application can send all that it can
read. Path filtering gives you the difference between a *query* and *administration*. That is a
large difference, but not the same as safety.

## Running the agent on a local model

[`DRAUGR_MODEL`](CONFIG.md#draugr_model) points the agent at a model that you host, not at the cloud
of its vendor. People make two claims about that, and only one of them survives this document.

**It is not about the credential.** The token of the agent never entered the mound. The proxy of
`sbx` authenticates each request on the host, for the agent. Measured from inside a mound against
`api.anthropic.com`: a junk bearer token, the own sentinel of the proxy, and *no authorization
header* all gave the same answer. That answer exists only if a real token reached Anthropic. The
same requests from the host, outside the proxy, came back `Invalid bearer token` and
`x-api-key header is required`. The proxy rewrites the header for `api.anthropic.com`,
`console.anthropic.com`, `claude.ai` and `mcp-proxy.anthropic.com`, whatever the mound sent.

That property is stronger than "the token is not in the mound", and it works in both directions.
**The mound also cannot give a credential of its own to those hosts.** No environment variable
changes it: not `DRAUGR_ENV`, and not the placeholder `ANTHROPIC_AUTH_TOKEN` that `DRAUGR_MODEL`
writes. The one control is `sbx secret` on the host, where an entry for one sandbox wins over the
global one.

That is also why a sign-in after the build of a mound needs no rebuild. It is also why an expired
token shows as a 401 on each prompt, not as a login screen. `SBX_CRED_ANTHROPIC_MODE` cannot tell
those apart. It reports `none` for an OAuth login exactly as for no credential. Thus do not base
anything on it. [TROUBLESHOOTING.md](TROUBLESHOOTING.md) has the symptom. `DRAUGR_MODEL` improves
none of this, because there was nothing to improve.

**And alone, it does not guarantee anything about egress.** We say this clearly, because the feature
invites exactly the wrong conclusion. `DRAUGR_MODEL` changes where the agent sends your code *by
design*: the one channel that Draugr builds for it. It changes nothing about what the mound can
*reach*. Each of the ~190 default allow rules of `sbx` is still in force. As [The network
policy](#the-network-policy) says, those cover the common code hosts, the package managers **and the
AI service endpoints**. Thus with the default policy, the mound with a local model can still connect
to the very service that you left.

> **A local model closes the designed channel, not the network.** "My code does not leave this
> machine" is a claim about the policy, not about `DRAUGR_MODEL`. If you set one and do not narrow
> the other, you get a feeling, not a property.

### Making the claim true, and what it costs

The other half is kit `deny` rules, which win over the machine allows. First read what you will
close. `dr-policy --defaults` lists the rules that you did not write, and `dr-policy --check <host>`
answers for one host. Then deny what the work does not need.

The cost is not small, and it is why this is a stance, not a default. A mound that cannot reach the
package managers cannot install anything. For most projects, that means that the setup commands in
the kit must finish the job at creation, from a cache, once. A mound that cannot reach `github.com`
cannot fetch a dependency that the agent wants. Whether that is acceptable fully depends on the use.
For review, refactoring, and work on a tree that is already complete, you barely notice it. For new
work in a language with a live dependency resolver, it does not work.

Thus the honest order: narrow the policy until the work stops, widen it one rule at a time, and
treat `DRAUGR_MODEL` as the thing that lets you close the largest hole, not as the thing that closes
it.

### The trade runs both ways

To reach a model on your own machine, you open a host port. The section above calls that the most
serious hole that Draugr opens for you. Thus this gives a narrower egress surface, but a new ingress
surface. That is usually a good trade, but only if the port that you open is narrow.
### Why the default port is 11435

Ollama has no authentication and no read-only mode. Thus `11434` serves inference and administration
through one door. Thus [`DRAUGR_MODEL_URL`](CONFIG.md#draugr_model_url) has the default `11435`, the
query-only proxy in [`share/ollama-proxy/`](../share/ollama-proxy/). Thus the setup that you get
without reading anything is the safe one:

```
Ollama        127.0.0.1:11434    loopback only - nothing off-host can reach it
proxy         0.0.0.0:11435      the only way in, query-only
the mound     DRAUGR_HOST_PORTS="11435"
```

Measured against that proxy on nginx 1.24.0 and Ollama 0.32.14, with the shipped allowlist
unchanged:

```
POST /v1/messages            200      POST /api/pull        403
POST /v1/chat/completions    200      POST /api/create      403
GET  /v1/models              200      DELETE /api/delete    403
GET  /api/version            200      GET  /v1/files        404
```

The first column is what an agent needs, and the second is what it must not have. `/v1/messages` is
the endpoint of Claude Code, and it was already inside the allowlist. The full `/v1/` prefix passed
through, because that surface had no management verbs, and the Anthropic compatibility of Ollama
arrived inside it.

That default assumes the proxy. Thus Draugr tests for it, and does not trust it. A `GET /healthz`
that answers `200` is the proxy. A `404` means that the agent points directly at an Ollama that it
can also administer. No answer means that the session cannot work. Then `dr-go` refuses to attach,
and does not give you an agent that fails at its first prompt. Refer to [What checks that the model
is really there](CONFIG.md#what-checks-that-the-model-is-really-there).


`DRAUGR_ENV` sets any variables in the session of the agent. That gives no more reach than a project
configuration already has, because it is shell, and Draugr runs it. Thus the same `dr-trust`
acceptance controls it, and it has no rule of its own. Draugr fully refuses `PATH` and `HOME`,
because both replace, and do not extend. A replacement inside the mound breaks the session before it
starts.

### What this does not buy

- **Not a reason to relax anything else.** A local model is still an agent that runs commands in a
  sandbox. Each other boundary in this document applies unchanged.
- **Not privacy from the operator of the model**, when `DRAUGR_MODEL_URL` names the endpoint of
  somebody else. A company LLM gateway is the server of somebody, with the logs of somebody. Only a
  URL that resolves to your own machine makes the egress argument above available. The key cannot
  tell the difference, and does not try.
- **Not protection from what the agent puts in a prompt.** It can send all that it can read to the
  endpoint that it has. A narrower endpoint narrows the audience, not the channel.
- **Not the same quality.** A model that fits on one GPU is clearly worse at long tool chains than
  the hosted one, and the loop of Draugr is only long tool chains. Use this level for work that
  cannot leave the machine. It is not a cheaper way to do the same work.

## The forge, if you turn it on

[`DRAUGR_FORGE`](CONFIG.md#draugr_forge) is empty by default, and nothing on this page changes while
it stays empty. All below applies only to projects that name a VM in it. That is a configuration
file that you had to `dr-trust` before Draugr read it.

**The claim of this page about the forge is weaker than its claim about a mound, on purpose.** If
you enable it, the mound still cannot reach your machine. It can now reach *a machine that you own*,
over one port, with no network of its own except through the same policy that controls the mound.

**It is not a mound, and almost none of the guarantees of this page apply.** No read-only source
mount, no four-mounts rule, no credential scan. All that the agent does in the guest, it does as a
Windows user who is an administrator there. An ssh session is elevated, with a full token
(*measured: writes System32, reads HKLM, controls services, never prompted*). The guest keeps no
secrets from it, and neither of the two passwords of the forge is a boundary against it. The agent
can recover both from inside the guest, in cleartext or almost so
([FORGE.md](FORGE.md#the-two-passwords-and-why-they-are-not-one) has the measurements).

**The network protection does apply.** The VM has no adapter, no route and no DNS of its own. All
traffic leaves through the `sbx` policy of the gateway mound, and an administrator in the guest
cannot get out in another way (*measured*). And the bearer token of the daemon, which can create,
start, stop and delete VMs, **never enters the mound**. The agent holds one ssh key to one port.
That split is why a compromised mound cannot destroy the VM that it works in.

### Four things worth knowing before you enable it

**The agent can spend with a store account in the guest.** If you sign the guest in to the launcher
of a vendor, for example the Epic Games Launcher, its session is in the guest, where the agent can
read it. Stores such as Fab sell paid assets. With the Unreal kit, the gateway allows `**.fab.com`
and `**.epicgames.com`. Thus the allowlist does not stop a purchase, and `dr-scan` cannot see inside
a VM. **Use an account with no saved payment method**, ideally one that you use for nothing else.
The cost: the library of that account is separate.

**GPU passthrough makes the attack surface of the *host* wider.** A paravirtualised GPU is a path
from guest code into the real GPU driver and display driver of your machine. `gpuMode=1` makes that
trade, and a VM boundary does not undo it.

**The guest photographs its own desktop.** `dr-forge init` installs a scheduled task with an
**interactive** principal, and `dr-forge pull` brings the image to the host. That makes the forge
usable by an agent, which cannot look at a screen. But it means that all that is visible on the
autologin desktop can reach the host, also what a browser or a signed-in application shows. The task
has no trigger, and runs only on request.

**`DRAUGR_FORGE_NOSCAN` set to `*` declares that the guest runs with real-time protection off**
([`DRAUGR_FORGE_NOSCAN`](CONFIG.md#draugr_forge_noscan)). Draugr does not turn it off, and holds no
command that would: `dr-forge init` reads the state of the guest and reports it, and the change is
yours to make there. The caution stands all the same, because the state is what matters and not who
set it. You are deciding to run a machine that reaches the internet through the gateway with its
protection off, and the forge is already the weaker of the two boundaries in this project.

### One alias, every VM

The ssh alias of each forge VM resolves to the same pinned host port. Thus **the name that you type
does not identify the far end**. The VM that answers is the VM that the tunnel supervisor serves. An
ssh block for one VM that stays after the deletion of its VM thus reaches a *different* guest, and
does not fail. That is how a `push` arrives in the wrong machine. `dr-setup --forge` writes one
wildcard block for exactly this reason, and `dr-forge doctor` tells the two apart.

---

## Things Draugr refuses to do

Each of these is a refusal by default, with an explicit override. A guard that you can silence
forever has no clear purpose.

| Refusal | Override |
|---|---|
| `dr-go` with a dirty tree: the clone contains only committed history | `dr-go --dirty` |
| `dr-go` with files that look like credentials in reach | `DRAUGR_SCAN_FAIL=warn` |
| `dr-rm` with commits that you did not fetch | `dr-rm --force` |
| `dr-rm` with memory that you did not export | `dr-rm --force` |
| `dr-merge` onto a dirty tree | commit or stash first |
| A source of a project configuration that you did not accept | `dr-trust` |
| `dr-data pull` with incoming files that look runnable | accept at the prompt, after `dr-data diff` |
| `dr-data pull` that offers an absolute or `..` path | none: examine the mound |
| A repo that is not on a Windows drive | none: `sbx` cannot mount it |
| A directory that is not a git repository | [`DRAUGR_ON_MISSING_REPO`](CONFIG.md#draugr_on_missing_repo) |
| `dr-forge rm` when the folder of the VM holds a frozen layer, a read-only disk, or another VM | none: move the disk out first |
| `dr-forge base` when a baseline already exists | none: only the first snapshot captures the current state |
| `dr-forge base` when the guest does not shut down gracefully | none: Draugr takes no baseline from a guest whose power was cut |
| `dr-forge rollback` without confirmation | `dr-forge rollback -y` |

`DRAUGR_CLONE=false` is the one with no override in a configuration file. It bind-mounts your real
working tree read-write, which is exactly what this project exists to prevent. Thus `dr-go` asks you
to confirm it each time. If you want no prompt, you are outside the purpose of the product.

---

## What Draugr itself touches

Nothing is written outside three places: the repository, `~/.config/draugr`, and
`$DRAUGR_MEM_STORE`. Inside the repository, it writes only `.draugr.conf`, `.draugr/`, `.gitignore`
entries, and, in the create modes of `DRAUGR_ON_MISSING_REPO`, a `.git`.

`~/.config/draugr/trusted` holds the hashes of the project configurations that you accepted, mode
600. Trust is for the *content*. An edit of a trusted file changes its hash, and silently removes the
trust until you accept it again.

---

## Reporting something

If you find a case where the boundary is not where this page says, that is a security bug in Draugr,
whether or not `sbx` works as documented. The full value here is that the claims are true. Please
include the shape of the repo path, the output of `dr-doctor`, and `sbx version`.
