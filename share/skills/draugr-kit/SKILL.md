---
name: draugr-kit
description: Find what a project needs to build in a Draugr sandbox, and write it into the sbx kit of the project. Use it for a build that fails on network access, for the kit of a new project, or for a request to make a project build in its mound.
---

# Build the kit of a project from inside the mound

You run in a sandbox, a "mound", that Draugr created. It has its own kernel and a
**default-deny network**. A build that works on the host can fail here only
because a host that it needs is not allowed yet.

Your job: find what the project needs, and write down the part that you own. You
cannot do this alone. The parts that you cannot do are not obstacles to go
around. Somebody else decides them.

## What you can and cannot do

You **can** run the build, read the repository, and edit
`.draugr/kit/spec.yaml`, a committed file in the working tree.

You **cannot** run `dr-policy`, `dr-kit`, or `sbx`. They are host-side commands,
and they are not installed here. Do not try them. Do not fake their output. When
you need one of them, stop and ask.

## The loop

1. Run the build as the project documents it.
2. If it fails, **do not guess which host was refused.** The error is not
   reliable. A test with one blocked host gave three results. `curl` printed
   nothing. `git` named the host exactly. `pip` said "Could not find a version
   that satisfies the requirement". That last one looks like a missing package,
   but it is not.
3. Stop, and ask the operator to run:

   ```
   dr-policy --denied
   ```

   That reads the own log of the proxy, so it is correct for each tool that made
   the request. The operator gives you the list.
4. For each host, tell them **why the build needs it**, in one line. They decide
   whether to open it, with `dr-policy --allow <host>`. It applies to this running
   mound immediately. **A retry costs nothing, and needs no restart.**
5. Go back to step 1 until the build is clean.

## Who writes what

`spec.yaml` has two owners, and they must not collide.

| | |
|---|---|
| `caps.network.allow` | **Not yours.** The operator runs `dr-kit adopt`. It writes the hosts that were really opened, from the own record of the daemon. |
| `commands.install` | **Yours.** You just found how to build this project. |
| `publishedPorts`, `environment` | You can propose them. |

If you edit the allow list by hand, the edits conflict. `dr-kit adopt` writes to
the same block on the host, and your copy of the repo is a clone. Report the
hosts, and let that command put them in place.

## Write the install commands

`commands.install` runs **once, when the mound is created**. It is the setup
that a teammate otherwise does by hand. `commands.startup` runs at **each
start**, and must be idempotent (safe to run twice).

```yaml
commands:
  install:
    - command: "npm ci"
      user: "1000"
      description: Install dependencies
```

**Install commands cannot see your repository.** They run *before* it is in the
workspace. At that moment, the working directory is empty, and the repo is
read-only at `/run/sandbox/source`. Tests on sbx 0.37.1 showed this, in clone
mode and in mount mode. Thus this fails, but it looks correct:

```yaml
- command: "uv pip install -r requirements.txt"     # error: File not found
```

This works:

```yaml
- command: "uv venv /home/agent/.venv"
- command: "uv pip install --python /home/agent/.venv/bin/python -r /run/sandbox/source/requirements.txt"
```

The venv is also outside the workspace. The agent session fills that directory
later, so nothing that you leave in it is safe.

**You cannot test any of this.** Install commands run only when a mound is
created, and you cannot create one. All that you write here stays untested until
the operator runs `dr-up --recreate`. A failure there shows as a bare
`500 ... failed to run sandbox container`, unless their Draugr is new enough to
read the log of the daemon. Say clearly that these commands are untested.

**A `PATH` in `environment.variables` can lock the operator out of the mound.**
The value REPLACES the value of the image, and does not extend it. Thus a PATH
that looks like a correct, standard Linux one silently drops all that the image
added. That includes the directory of the agent binary itself.

A test showed this. A kit wrote this, to put a virtualenv before the system
interpreter:

```yaml
environment:
  variables:
    PATH: "/home/agent/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

The next `dr-go` ended in `bash: codex: command not found` before the agent
started. codex is at `/usr/local/share/npm-global/bin/codex`, and nothing under
`/etc` puts that directory on `PATH`. The image does. The kit removed the agent
from its own sandbox.

Do not use `PATH` to make a program find an interpreter. Make the program find
it. `.venv/bin/python3` in the script is better than `python3` with a mound-wide
`PATH`. It needs no kit entry, and it also works outside a mound. If you really
must set `PATH`, keep each directory of the image, and add yours at the front.
Then say in your report that you did something that can stop the mound from
opening.

Important rules:

- Use `schemaVersion: "2"` spellings. v1 still validates, but warns.
- `commands.install` takes `command` as a string. `commands.startup` requires the
  list form, `["sh", "-c", "…"]`, and refuses a string.
- `user: "1000"` is the agent. Use `"0"` only for something that really needs
  root, such as `apt-get install`.
- Give each command one job, with a `description`. People read the list.
- Do not put secrets, tokens, or credentials in the kit. It is committed.
- Do not add a host "just in case". Each entry is a permanent permission for each
  future session on this project.

## What not to put in a kit

All that does not belong to *the project*. A temporary port belongs to
`dr-ports`. A host that you needed once for an experiment belongs nowhere. If you
cannot write the one-line reason, leave it out.

## The host-side steps, in order

All steps below, except step 3, run on the host. The operator must not have to
look them up. This order works. Tell them the parts that are still open.

1. `dr-policy --denied`: the hosts that the proxy refused. During the loop, at
   each failed build.
2. `dr-policy --allow <host>`: one for each host that they accept. It applies to
   this mound immediately, and you retry at once.
3. **You commit** your `spec.yaml` change here, in the mound. Nothing leaves an
   uncommitted working tree.
4. `dr-diff`, then `dr-merge`, on the host, to take that commit out of the mound.
   (`dr-go` fetches on exit. If they stayed attached, run `dr-sync` first.)
5. `dr-kit adopt`: writes the hosts that were really opened into
   `caps.network.allow`. Then they commit the kit.
6. `dr-kit validate`: catches a malformed kit before a recreate replaces a working
   mound with one that does not build. It tests only the schema. It cannot tell
   whether your install commands work.
7. `dr-up --recreate`: the real test, and the first run of your install commands.

In two places, the order is important:

- **Merge before adopt.** `dr-kit adopt` leaves the kit file modified, and
  `dr-merge` refuses on a dirty tree. Merge first, or commit the adopt before the
  merge.
- **Adopt before a recreate or a remove.** `dr-rm` and `dr-up --recreate` both
  refuse while a host is open and not in the kit. The rules do not stay after the
  mound. Thus a recreate destroys the list that made the build work. That refusal
  is the safety net for step 5. `dr-kit adopt` clears it.

## When you are done

Say clearly what you changed, and what you still need from the operator:

- the install commands that you added, and why
- the hosts that you needed
- each failure that was **not** caused by the network. A kit cannot fix those.

Then name the host-side steps that they must still do, from the list above.
Usually that is `dr-merge`, `dr-kit adopt`, `dr-kit validate`, and a
`dr-up --recreate` to prove that the kit works from a clean mound.
