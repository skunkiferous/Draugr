---
name: draugr-handoff
description: Move work out of a Draugr mound, take work in, and let the operator see a port or a file. Use it when you finished something and it has to reach the person outside, when you need a file that only they have, when they ask why they cannot see your changes, when a port you started is not reachable for them, or before you say that anything is "done".
---

# Across the boundary

Nothing you do leaves this mound by itself. The operator fetches it, reviews it,
and commits it. Plan for that: it is a review boundary, not a transport failure.
See the **draugr** skill for why you cannot push.

## Rule one: commit, and commit often

An uncommitted working tree is work that cannot leave. Inside a mound you commit
freely and without asking: that is what the mound is for, and the review happens
at the boundary, not at each commit. Write the message for a reader who was not
here.

```
git add -A && git commit -m "..."
```

Measured: `git push` is rejected. The only remote is the read-only source mount,
and a push to it fails with "unable to create temporary object directory" while
nothing reaches the host. Do not try it, and do not report it as a problem.

## Your work, outwards

On the host, your commits appear as `draugr/<branch>`:

1. `dr-sync` fetches them. (`dr-go` also fetches when the operator leaves the
   agent, so after a normal session this is already done.)
2. `dr-diff` shows the change, as `HEAD...draugr/<branch>`, so their own commits
   do not appear inverted in it.
3. `dr-merge` accepts it as an ordinary merge. After that it is theirs: amend,
   rebase or push, as they like.

So when you report that something is finished, say it this way: finished and
committed in the mound, ready for `dr-sync` and `dr-diff`. Do not say "pushed".

## Their work, inwards

`dr-send` fetches their branch into this mound. It arrives as
`refs/remotes/host/<branch>`, and **it does not move your branch**. You decide
when to take it:

```
git merge host/<branch>
```

If you need something that is in their tree right now and not in your clone, read
it at `/run/sandbox/source/<path>`. It is live and read-only.

## One file, without git

- Out of the mound: they run `dr-cp <path> .`
- Into the mound: they run `dr-cp --to <hostfile> <path>`
- A big data file either way: `dr-data`, which uses rsync and keeps the same path
  on both sides.

**Do not ask for a tree that holds a symlink.** Measured on the current `sbx`: a
copy stops at the first link in the walk, drops everything after it, and still
exits 0. A tree whose first entry was a link arrived empty, and the command
reported success. Name the real files, or ask them to copy the target.

## A port they can open

A port you bind is yours alone. Published ports land on the **Windows** loopback
of their machine, not on yours:

- `dr-ports 5173` publishes it, with a host port that `sbx` picks.
- `dr-ports 8080:80` names the host port as well.
- `dr-ports` with no argument lists what is published now.
- No rebuild is needed for any of that.

Two traps. The host port that `sbx` picks **changes at every rebuild**, so a URL
in a bookmark goes stale; a port that must stay the same belongs in the
configuration of the project, which the operator keeps. And a kit cannot name the
host port at all: measured, `sbx create` refuses the capability that would do it.

The other direction: `localhost` inside the mound is the mound. A service on the
machine of the operator is `host.docker.internal:<port>`, and it answers only
after they allow `localhost:<port>` for this mound. Measured: without the rule the
proxy answers 403, with it the real service answers 200.

## What to say when you are done

- what you changed, in one line
- that it is committed here, and the two commands they need: `dr-sync`, `dr-diff`
- anything that is still open, and who owns it
- any file you could not move, and why

Never report work as delivered while it sits in an uncommitted tree inside a
sandbox that a rebuild can erase. See the **draugr-recreate** skill.
