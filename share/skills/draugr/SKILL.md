---
name: draugr
description: Where you are when Draugr runs you, and what you cannot change from here. A mound is a sandbox on the machine of the operator, with a copy of their repository, a default-deny network, and none of the tools that change any of that. Use it for "why can I not reach this host", "how does my work get out", "what does a rebuild destroy", "can you open a port for me", "I need a credential for a private repository", and whenever the answer is a command that somebody else must run.
---

# You are inside a mound

## How you know, and the name to use

Your environment has `IS_SANDBOX=1` and `SANDBOX_NAME`. That name is the name of
this mound, and the operator needs it when more than one exists. Measured in a
mound: `SANDBOX_NAME`, `SANDBOX_VM_ID`, `SANDBOX_ID` and `IS_SANDBOX` are all set
for you, and `hostname` is not installed.

A **mound** is a small virtual machine with its own kernel, made by `sbx` (Docker
Sandboxes) on a Windows machine. **Draugr** is a set of `dr-*` commands that the
operator runs on that machine, in WSL, outside this mound. You cannot see them.
They are not installed here, and neither is `sbx`. Do not look for them, do not
try them, and never write out what you think their output is.

That is the whole shape of your situation: you can see everything that is wrong,
and you can change almost none of it. What you can do instead is name the one
command that fixes it, and say what it costs.

## The words the operator uses

| word | what it is |
|---|---|
| mound | this sandbox |
| forge | an optional Windows virtual machine, for work that needs Windows |
| vault | a read-only share that the forge reads |
| operator | the person on the host. They review and they commit |

## Two trees, and the difference matters

```
/c/Code/<project>        your working tree. A CLONE, taken when this mound was made
/run/sandbox/source      the real repository of the operator. LIVE, and read-only
```

Measured: the source mount refuses a write, and the clone has `origin` pointing at
it. Thus:

- What you edit is invisible on the host until the operator fetches it.
- What they commit is invisible to you until they send it in.
- `/run/sandbox/source` is the one place where you can read what they have **now**,
  for example a file that is in their tree and not in your clone.

If `/run/sandbox/source` does not exist, this mound was made with
`DRAUGR_CLONE=false`, and your working tree **is** their tree, read-write. Then
every edit you make is immediate and real. Check before you assume.

## Who can do what

| what you want | who does it | the command they run on the host |
|---|---|---|
| reach a host that the network refuses | operator | `dr-policy --denied`, then `dr-policy --allow <host>` |
| keep that host for every future session | both | you write the kit, they run `dr-kit adopt` |
| get your commits out | operator | `dr-sync`, then `dr-diff` and `dr-merge` |
| get their commits in | operator | `dr-send`. They arrive as `host/<branch>` |
| copy one file out, uncommitted | operator | `dr-cp <path> .` |
| copy a large data file either way | operator | `dr-data` |
| open a port they can look at | operator | `dr-ports 5173` |
| apply a changed kit | operator | `dr-kit apply`, or `dr-up --recreate` |
| keep your memory and this conversation | operator | `dr-mem export`, later `dr-mem import` |
| sign in to a service your work needs | operator | no `dr-*` command. `sbx secret set <service> --sandbox <mound>` |
| see the whole list | operator | `dr` with no arguments |

You own the working tree, your commits, the files in it, and `.draugr/kit/spec.yaml`.
Everything in the table above belongs to the operator.

## Credentials are not yours to hold

`sbx` keeps them on the host, and its proxy authenticates each request for you.
Measured, for the credential of the agent itself: a junk bearer token, no
authorization header at all, and the real sign-in all gave the same answer,
because the proxy rewrites the header whatever you send. The same store holds a
credential for `github` and a dozen other services. Therefore:

- **Never ask for a token to be pasted in here**, written to a file, or put in
  `DRAUGR_ENV`. A credential inside this mound is one you can leak, and it buys
  nothing that the proxy does not already do.
- **You never need a credential to read something.** Whether the repository is
  the operator's or not, the answer is the same: a local copy, mounted read-only
  with `DRAUGR_MOUNTS=<path>:ro`. Their credential was only the route you knew
  about. Ask for the mount, and name the path you need.
- If a login is genuinely the answer, there is no `dr-*` command for it, and this
  is one of the few cases where what you name is a plain `sbx` one:
  `sbx secret set <service> --sandbox <mound>`. Scope it to this mound. A global
  secret is for every mound on the machine, which is not what your task needs.
- **And say what the token costs.** `gh auth token` is the whole account of the
  operator, read and write, on every repository they can reach. It is a password, not
  a key for one door. Ask for the narrowest token that does your job and say
  which repository you need, so they can decide what to issue.
- Whatever you can read, the model provider can read. For source under a license
  that the operator accepted, such as an engine or a partner SDK, that is their
  call to make, not a detail. Ask before you read it, not after.

## How to ask, in four lines

Not "the network seems blocked". Write it so they can act without asking you
anything back:

> The build needs `registry.example.com`. The mound refused it: the proxy answered
> **403** with "Approval required", not a timeout, so the host is blocked and not down.
> On the host: `dr-policy --allow registry.example.com`
> That lasts as long as this mound. To keep it, it goes in the kit, and `dr-kit adopt`
> writes it there. Nothing is lost either way, and I can retry at once.

The four parts are: what you need, the evidence, the exact command, and what it
costs. The last part matters most for anything that destroys state. See the
**draugr-recreate** skill before you suggest a rebuild.

## Normal here, although it looks wrong

- **A blocked host answers 403**, with a body about approval, through the proxy of
  the mound. A dead host and a refused host look alike until you read the body.
- `sudo -n` works, with no password. You are `agent`, uid 1000.
- `localhost` is this mound. The machine of the operator is `host.docker.internal`,
  and only after they add a rule for that port.
- `git push` cannot work. Measured: a push to `origin` is rejected with "unable to
  create temporary object directory", because that remote is the read-only mount,
  and nothing reaches the host. Commit, and let them fetch.
- In a mound for Claude Code there is no `node` and no `npm`: the agent is one
  binary at `~/.local/share/claude/versions/<version>`.
- The shared skills directory can be read-only. A mound built by a newer `sbx`
  mounts it that way, and an older mound keeps it writable.
- The mound stops about 30 seconds after the last session ends. A job that must
  outlive your session needs a session that stays, which the operator arranges.

## The rest of the set

- **draugr-kit**: the network allow list and the install commands of this project.
- **draugr-handoff**: moving work, files and ports across the boundary.
- **draugr-recreate**: what a rebuild destroys, and the order that saves it first.
