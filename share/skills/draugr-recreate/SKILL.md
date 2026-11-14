---
name: draugr-recreate
description: What a rebuild of a Draugr mound destroys, and the order that saves each thing first. Use it before you suggest dr-up --recreate or dr-rm, when a kit change has to take effect, when the operator asks whether they will lose anything, when a long job must outlive your session, or when a fresh mound has forgotten the conversation.
---

# A rebuild, and what it costs

`dr-up --recreate` removes this mound and makes a new one. It is the only way to
apply a creation flag: the memory size, the processor count, the clone mode, and a
kit change that cannot be applied in place. It is also destructive, and some of
what it destroys has no copy anywhere else.

**Never suggest it without naming what it costs.** The operator is reading your
line to decide, and they cannot see inside the mound.

## What exists only here

| what | how it is saved first |
|---|---|
| uncommitted work in your tree | you commit it |
| commits the operator never fetched | `dr-sync` on the host |
| what the agent learned, and this conversation | `dr-mem export` on the host |
| hosts opened by hand with `dr-policy --allow` | `dr-kit adopt`, then they commit the kit |
| anything installed by hand in the mound | it belongs in the kit, or it is lost |

Three of those five are guarded: `dr-up --recreate` and `dr-rm` refuse while there
are unfetched commits, while the memory or the conversation was never exported, and
while a host is open that the kit does not hold. `--force` goes ahead anyway. The
other two are not guarded by anything, so they are the two to say out loud.

## The order that works

1. You commit everything in the mound.
2. `dr-sync`, so the commits are on the host. `dr-diff` and `dr-merge` can wait.
3. `dr-mem export`, which copies the memory and the newest transcript out.
4. `dr-kit adopt`, which writes the hosts that were really opened into the kit.
   Then they commit the kit.
5. `dr-up --recreate`.
6. `dr-mem import`, which puts the memory and the conversation into the new mound.

Step 4 comes before step 5 for a reason: the rules die with the mound, so a
rebuild destroys the very list that made the build work.

## Often you do not need one at all

A kit change can sometimes be applied to the running mound:

- `dr-kit validate` first. It checks the shape of the file, and nothing else: it
  cannot tell whether an install command works.
- `dr-kit apply` adds the kit to this mound. Measured on the current `sbx`: that
  also **re-runs the install commands of every kit**, not only of the new one, so
  each install command must be safe to run twice. A kit that declares startup
  commands is accepted now, where an older `sbx` refused it.
- A host for this session only needs no kit and no rebuild at all:
  `dr-policy --allow <host>` applies at once, and you retry immediately.

So the honest line is often "this needs no rebuild", and that is worth saying.

## The memory and the conversation are two things

- The **memory** is what the agent wrote down. It is small.
- The **conversation** is the transcript itself, and it is what `--continue` reads.
  It can be hundreds of megabytes.

`dr-mem export` carries the memory and, by default, the newest transcript. The
configuration key `DRAUGR_MEM_TRANSCRIPTS` decides how much: `off`, `newest` or
`all`. After the rebuild, `dr-mem import` puts both back, and then continuing the
conversation works in the new mound.

An export refuses while the agent runs. If the operator reports that, the answer
is: leave the agent first, then export. A copy of a file that is being
written is not a backup, which is why it refuses rather than warns. The export
also prints where the conversation now sits on their machine and the command that
deletes it again, because it leaves the sandbox when it is exported.

## The mound stops when nobody is attached

Measured on the current sbx: about 30 seconds after the last session ends. An
earlier measurement, not repeated, also found that traffic through a published
port does not count as a session. A build or a server that must outlive
your session needs a session that stays open, which the operator arranges. For a
service that other repositories depend on, `dr-dep` manages that.

If a long job of yours was killed and you do not know why, this is the first thing
to check, before you blame the job.

## What to write

> This needs a rebuild: the kit now adds a package at install time, and
> `dr-kit apply` cannot do that for a running mound.
> Before it: I committed my work, so `dr-sync` is enough for the code.
> `dr-mem export` keeps the memory and this conversation. Without it they are gone.
> `dr-kit adopt` keeps the two hosts we opened by hand.
> Then `dr-up --recreate`, and `dr-mem import` afterwards.
> The one thing with no copy is the `jq` I installed by hand, which the kit now holds.
