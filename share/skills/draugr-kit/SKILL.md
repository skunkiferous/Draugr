---
name: draugr-kit
description: Work out what a project needs to build inside a Draugr sandbox, and write it into the project's sbx kit. Use when a build fails on network access, when setting up a new project's kit, or when asked to make a project build in its mound.
---

# Building a project's kit from inside the mound

You are running inside a sandbox — a "mound" — created by Draugr. It has its own
kernel and a **default-deny network**. A build that works on the host can fail
here purely because a host it needs is not allowed yet.

Your job is to find out what the project needs and write down the part of it you
own. You cannot do this alone, and the parts you cannot do are not obstacles to
work around — they are someone else's decision.

## What you can and cannot do

You **can** run the build, read the repository, and edit
`.draugr/kit/spec.yaml`, which is a committed file in the working tree.

You **cannot** run `dr-policy`, `dr-kit`, or `sbx`. They are host-side commands
and are not installed here. Do not try; do not fake their output. When you need
one of them, stop and ask.

## The loop

1. Run the build the way the project documents it.
2. If it fails, **do not guess which host was refused.** The error is not
   reliable. Measured against one blocked host: `curl` printed nothing at all,
   `git` named it exactly, and `pip` said "Could not find a version that
   satisfies the requirement" — the last of which looks like a missing package
   and is not.
3. Stop and ask the operator to run:

   ```
   dr-policy --denied
   ```

   That reads the proxy's own log, so it is correct whatever tool made the
   request. They will hand you the list.
4. For each host, tell them **why the build needs it**, in one line. They decide
   whether to open it, with `dr-policy --allow <host>`. It takes effect on this
   running mound immediately — **retrying costs nothing and needs no restart.**
5. Go back to 1 until the build is clean.

## Who writes what

`spec.yaml` has two owners and they must not collide.

| | |
|---|---|
| `caps.network.allow` | **Not yours.** The operator runs `dr-kit adopt`, which writes the hosts that were actually opened, from the daemon's own record. |
| `commands.install` | **Yours.** You are the one who just worked out how to build this project. |
| `publishedPorts`, `environment` | Yours to propose. |

Editing the allow list by hand creates a conflicting edit: `dr-kit adopt` writes
to the same block on the host while your copy of the repo is a clone. Report the
hosts and let that command place them.

## Writing the install commands

`commands.install` runs **once, when the mound is created**, as the setup a
teammate would otherwise do by hand. `commands.startup` runs on **every start**
and must be idempotent.

```yaml
commands:
  install:
    - command: "npm ci"
      user: "1000"
      description: Install dependencies
```

Rules that matter:

- Use `schemaVersion: "2"` spellings. v1 still validates but warns.
- `user: "1000"` is the agent. Use `"0"` only for something that genuinely needs
  root, such as `apt-get install`.
- Keep each command one job, with a `description`. The list is read by people.
- Do not put secrets, tokens, or credentials in the kit. It is committed.
- Do not add a host "just in case". Every entry is a standing permission for
  every future session on this project.

## What not to put in a kit

Anything that is not a property of *the project*. A one-off port belongs to
`dr-ports`; a host you needed once for an experiment belongs nowhere. If you
cannot write the one-line justification, that is the signal to leave it out.

## The host-side steps, in order

Everything below except step 3 runs on the host, and the operator should not have
to look it up. This is the order that works — say back the parts that are still
outstanding.

1. `dr-policy --denied` — the hosts the proxy refused. During the loop, whenever
   a build fails.
2. `dr-policy --allow <host>` — one per host they accept. Live on this mound; you
   retry straight away.
3. **You commit** your `spec.yaml` change here, in the mound. Nothing leaves an
   uncommitted working tree.
4. `dr-diff`, then `dr-merge` — on the host, to take that commit out of the mound.
   (`dr-go` fetches on exit; if they stayed attached, `dr-sync` first.)
5. `dr-kit adopt` — writes the hosts that were actually opened into
   `caps.network.allow`. Then they commit the kit.
6. `dr-up --recreate` — the real test. `commands.install` only runs when a mound
   is created, so until this happens the kit you wrote is untested.

Two places where the order is not arbitrary:

- **Merge before adopt.** `dr-kit adopt` leaves the kit file modified, and
  `dr-merge` refuses on a dirty tree. Either merge first, or commit the adopt
  before merging.
- **Adopt before recreate or remove.** `dr-rm` and `dr-up --recreate` both refuse
  while a host is open and not in the kit — the rules do not survive the mound, so
  a recreate would destroy the very list that made the build work. That refusal is
  the safety net for step 5; `dr-kit adopt` clears it.

## When you are done

Say plainly what you changed, and what you still need from the operator:

- the install commands you added, and why
- the hosts you needed
- anything that failed for a reason that was **not** the network, which a kit
  cannot fix

Then name the host-side steps they still owe, from the list above — usually
`dr-merge`, `dr-kit adopt`, and a `dr-up --recreate` to prove the kit works from
a clean mound.
