# Claude Code plugins

A Claude Code *plugin* is a directory with a `.claude-plugin/plugin.json` manifest. It can hold
`skills/`, `commands/`, `agents/`, `hooks/`, `.mcp.json`, `.lsp.json` and `bin/`. A *marketplace*
is a repository with a `.claude-plugin/marketplace.json`, which lists one or more plugins. Normal
use has two steps: register the marketplace, then install a plugin from it.

> **Measured** with sbx 0.37.1 and Claude Code 2.1.246, in a mound whose old plugin state was moved
> away first. Thus no result came from an earlier test. [What a seed actually
> saves](#what-a-seed-actually-saves) tells what the seed does and does not do. It does less than
> an earlier draft of this page said: it gives the marketplaces, not the installs.

## The short version: `dr-plugin`

```bash
DRAUGR_PLUGIN_STORE="/mnt/c/Code/claude-plugins"     # in ~/.config/draugr/config
```

```bash
dr-plugin                              # what the library holds, and what is missing to use it
dr-plugin add anthropics/claude-code   # register the marketplace, install, enable
dr-plugin update                       # refresh catalogues and plugins
dr-plugin clean                        # drop superseded versions, which nothing else reaps
dr-plugin remove <plugin>@<mkt>        # uninstall, deregister, disable, reclaim the space
dr-plugin rollback                     # swap back to the previous library
```

**`add` takes a marketplace, not a plugin**, and the registration is not a separate step. Normal
use is two commands: register the catalog, then install from it. `add` does both. If you name
nothing after the marketplace, you get all its plugins. If you name plugins, you get only those:

```bash
dr-plugin add obra/superpowers                     # every plugin it lists
dr-plugin add obra/superpowers superpowers         # only that one
dr-plugin add anthropics/claude-code a b c         # only those three
```

`dr-plugin` finds the *registered* name of the marketplace. You do not type it, because the
repository sets it: `obra/superpowers` arrives as `superpowers-marketplace`. Thus the plugin that
you name can be bare, and `dr-plugin` adds the new marketplace name.

**On a second `add` of the same repository, nothing new arrives**, because the marketplace is
already there. Thus the name comes from the registry, which records the source of each marketplace.
That lets a second `add` give an answer. With no plugin named, it reports the registered marketplace
of the source, what is installed from it, and whether it is switched on. Then it points at
`dr-plugin update`.

With no arguments, `dr-plugin` tests the three values that let a mound reach the library. If they
are missing, it prints the exact lines. Thus you only need to know the store.

Each plugin operation happens inside a mound that Draugr creates for it, and later destroys. Your
host never runs plugin code. It gets a directory, and mounts it back read-only. Draugr always edits
a copy of the library. Thus a failed build changes nothing, and the previous library stays as
`seed.old`.

**The rest of this page tells what that command does, and why.** Read it if you want to do it by
hand, or if something does not work. Each claim below was measured. One fact shapes all of it:

> `sbx cp` extracts a tar, so **directories merge and same-named files are replaced**.

Thus a copy of a rebuilt library over an existing one adds and never removes. Updates keep old
versions forever, and a manual removal frees nothing. `dr-plugin` avoids this, because it never
uses `dr-cp`. It works on a copy on the host, and swaps it.

## Why plugins are a different problem from skills

A skill is instructions. A plugin is **code that runs**. Hooks run on session start and after tool
use. MCP servers are processes. `bin/` goes on the `PATH` of the Bash tool. For a plugin with a
`package.json`, the install runs `npm ci --ignore-scripts` on it.

That is the full reason for this page. Draugr trusts an agent in a mound, because the mound is
disposable, and cannot reach your machine. Third-party plugin code has exactly the same status as
the agent. It is safe inside a mound. Do not install it on your host so that a mound can use it.

Thus this page follows one rule:

**Your host stores plugin bytes. It never runs them.**

Here, persistence and safety pull in opposite directions. A mound is disposable, so all that must
stay after `dr-rm` must be on the host. That rule resolves the conflict. Each option below keeps
the plugin fully inside the mound, or keeps it on the host as inert files, mounted **read-only**.
None of them needs `claude plugin install` on Windows.

## Where a plugin lives inside a mound

Claude Code keeps its plugin library in `~/.claude/plugins/`:

```text
known_marketplaces.json                      the catalogues you have registered
marketplaces/<name>/                         each catalogue, cloned
cache/<marketplace>/<plugin>/<version>/      the plugin itself
data/<plugin-id>/                            per-plugin state, including .credentials.json
```

In a mound, that is normal rootfs. Thus it is in the same class as the login of the agent:

| | |
|---|---|
| Stays after `dr-stop` and the next `dr-up` | yes |
| Stays after `dr-rm` | **no** |
| Shared with your other mounds | no |
| Reachable from the host | no |

Compare `~/.claude/projects` and `~/.claude/sessions`, which are disk images for each sandbox. Also
compare `~/.claude/skills`, which is a bind mount from the host, shared by each mound. Refer to
[SECURITY.md](SECURITY.md#trap-2--the-skills-store-is-a-writable-door-out).

Thus the basic answer to "how do I use a plugin in a mound" is: install it once in that mound, and
again in the next one. The five options below avoid that.

## The five options

In order of reach. "Host runs the code" is `no` on each row. That is on purpose: the list was built
with that rule.

| | Reach | Stays after `dr-rm` | Host stores it | Writable from a mound | Cost for each extra plugin |
|---|---|---|---|---|---|
| 1. Install in the mound | one mound | no | nothing | n/a | one command, for each mound |
| 2. Kit `commands.install` | each mound of one repo | yes, installs again | nothing | no | two lines in the kit |
| 3. `--plugin-dir` | where you set it | yes | inert files | **no** | a clone **and** a flag |
| 4. Seed directory | each mound | the content, yes | inert files | **no** | one command, and an install in each mound |
| 5. Shared skills store | each mound, each agent | yes | inert files | **yes** | a clone |

The full documentation of option 4 is below. The others are short here.

### 1. Install it in the mound

```bash
dr-shell -- claude plugin marketplace add anthropics/claude-code
dr-shell -- claude plugin install commit-commands@claude-code-plugins -y
```

`-y` is necessary. `claude plugin install` is interactive unless you pass it, or unless stdin and
stdout are not a TTY. The machine allow rules of `sbx` include `github.com`, so the clone works.
To make sure, run `dr-policy --check github.com`.

> ### `dr-shell --` takes a command, not a command *line*
>
> All after `--` is an argv vector. Draugr quotes each argument with `printf '%q'` for the far
> side. If you put a full line in quotes, it becomes a single word. That fails in two different
> ways:
>
> ```bash
> dr-shell -- "claude plugin list"          # one word; "command not found"
> dr-shell -- "FOO=/tmp/seed claude plugin list"   # a variable assignment. Exit 0, silence
> ```
>
> The second is the dangerous one. Bash reads `name=value` with no command as an assignment. It
> sets the variable to the rest of the line, runs nothing, and **succeeds**. No output, no error,
> exit 0, and no plugin installed. Pass the words separately, and use `env` when you need a
> variable:
>
> ```bash
> dr-shell -- env FOO=/home/agent/seed claude plugin list
> ```
>
> `env` is a real binary, so it needs no shell on the far side. For the same reason, nothing here
> expands `~`. Paths in the mound in a `dr-shell` command must be absolute.

Nothing touches the host, and `dr-rm` removes it. Use this to *try* a plugin, not to *keep* one.

### 2. Bake it into the kit

Put the same two commands in `.draugr/kit/spec.yaml` under `commands.install`. Then each mound
built for that repo installs the plugin when it is created:

```yaml
commands:
  install:
    - command: "env HOME=/home/agent claude plugin marketplace add anthropics/claude-code"
      user: "1000"
      description: Register the demo marketplace
    - command: "env HOME=/home/agent claude plugin install commit-commands@claude-code-plugins -y"
      user: "1000"
      description: Install the commit-commands plugin
```

`user: "1000"` makes the install write to the home of the agent, not of root. The explicit `HOME`
is necessary, because these do not run in a login shell. It stays after `dr-rm` in the important
way: the next mound installs it again.

This is the only option that a **collaborator gets automatically**. The kit is committed, so a clone
of the repo brings the plugin. That is also its risk. A reviewer must see a kit that installs
third-party code, as for all other dependencies.

### 3. `--plugin-dir`, off a read-only mount

Claude Code can load a plugin directory directly, with no marketplace and no install step. Clone it
once, mount it read-only, and name it in the agent arguments:

```bash
DRAUGR_MOUNTS="/mnt/c/Code/claude-plugins:ro"
DRAUGR_AGENT_ARGS_CLAUDE="--plugin-dir /c/Code/claude-plugins/commit-commands"
```

A mount arrives at the mirrored path. Thus `C:\Code\claude-plugins` is `/c/Code/claude-plugins`
inside. Refer to [`DRAUGR_MOUNTS`](CONFIG.md#draugr_mounts).
It is simple, clear, and read-only. But `--plugin-dir` takes **one plugin for each flag**. Thus a
library of six plugins is six flags, and a seventh needs an edit of your Draugr configuration.
Option 4 fixes that.

It works together with option 4. It does not compete with it, and that works. Refer to
[pointing it straight at the seed](#follow-up---plugin-dir-pointed-straight-at-the-seed).

### 4. A seed directory

One host directory holds each plugin that you use, and is mounted read-only into each mound. To
add a plugin, you run one command on the seed, and change nothing in your Draugr configuration.
Details are below.

It gives the marketplaces, not the installs. Thus it works with option 2, and does not replace it.
Refer to [what a seed actually saves](#what-a-seed-actually-saves).

Its values apply to the full machine, also with several agents. The seed itself works for each
agent. The one line for Claude Code goes in
[`DRAUGR_AGENT_ARGS_CLAUDE`](CONFIG.md#draugr_agent_args_agent), which applies only to claude
mounds. Refer to [the configuration](#the-configuration).

### 5. The shared skills store

A plugin directory in the shared skills store loads as `<name>@skills-dir`, with no marketplace and
no install step. The store is mounted at `~/.claude/skills` in each claude mound. Thus one copy
reaches each mound on the machine, and stays after `dr-rm`. It is the cheapest option, and it is
last on purpose.

> The store is the one path by which a sandbox can write to your host. Each mound shares it, and it
> lives longer than the mound that wrote it. That is already the reason for `dr-skills diff`, for
> *instructions*. A plugin puts **executables** there: hook scripts that each mound runs at each
> session start, in a directory that each mound can rewrite. One compromised mound edits the script.
> The next, unrelated mound runs the edit.
>
> `dr-skills diff` and `dr-skills accept` still reduce the risk, and still work. But option 4 gives
> the same reach with the directory mounted **read-only**. That removes the risk, and does not only
> review it. Use option 4.

The store is also shared between agents. Thus a plugin there is also in reach of your codex mounds.
Nothing loads it there, and it only uses disk space.

---

## Option 4 in detail: a seed directory

Claude Code has a mechanism for container images: a **plugin seed**. It is a pre-built copy of the
`~/.claude/plugins` library, which Claude Code reads at startup. It registers the marketplaces of
the seed, and uses its plugin caches in place. It clones nothing, and does not write to the
directory.

That is exactly the shape that Draugr wants. A disposable mound builds the seed. It comes out as
inert files, and is then mounted read-only into each mound.

### The layout

```text
C:\Code\claude-plugins\
├── seed\                        ← CLAUDE_CODE_PLUGIN_SEED_DIR
│   ├── known_marketplaces.json
│   ├── marketplaces\<name>\…
│   └── cache\<marketplace>\<plugin>\<version>\…
└── settings.json                ← which of them are switched on
```

Claude Code uses only those three entries under `seed\`. It reads nothing else in the directory.

### Building it, inside a mound

Point the plugin cache of Claude Code at a build path, install what you want, and copy the result
out. Run this from any repository that has a mound. The seed is for the full machine, not for the
current project.

```bash
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin marketplace add anthropics/claude-code
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin install commit-commands@claude-code-plugins -y

dr-shell -- ls -la /home/agent/seed            # confirm it exists before copying
mkdir -p /mnt/c/Code/claude-plugins
dr-cp -L --raw /home/agent/seed /mnt/c/Code/claude-plugins
```

### Why `-L`

At some time, a plugin has a symlink. `superpowers` has `AGENTS.md` as a link to `CLAUDE.md`.
Without `-L`, the copy fails on it:

```text
ERROR: extract to C:\Code\claude-plugins: symlink CLAUDE.md
       …\superpowers\6.3.0\AGENTS.md: A required privilege is not held by the client.
```

The cause is Windows, not Draugr. A symlink on NTFS needs `SeCreateSymbolicLinkPrivilege`. A
normal account does not have it, unless Developer Mode is on. **A failure here leaves a partial
tree.** Remove it before you try again. Do not mount a half-copied seed.

`-L` copies the target of each link. `cp -L` and `docker cp -L` follow only a link named as the
source. But `sbx` follows links **in all places in the tree**. A test on sbx 0.37.1 showed this. A
seed of three marketplaces came out complete, with 2262 files. `AGENTS.md` arrived as a real
8873-byte file, with no link left in it.

To follow the links is the right answer here, not a compromise. `AGENTS.md` becomes a copy of
`CLAUDE.md`, not a link to it, and for a plugin that is the same. It also avoids a later question:
how does a mound handle an NTFS symlink through virtiofs? It stays an option on `dr-cp`. For all
other copies, a silent change from links to copies changes what comes out of the mound.

All that runs during the build happens inside a mound that you will remove: the clone, `npm ci`
for a plugin with a lockfile, and the install steps of the plugin. The host gets a directory tree,
and nothing else.

The `ls` is necessary. `claude plugin` prints little on success. Thus the two commands above look
the same whether they worked or did nothing. The first step that *notices* is `dr-cp`, which fails
with `path not found in container`. At that time, the important error is long gone. Expect
`known_marketplaces.json`, `marketplaces/` and `cache/`. If one is missing, the install failed, and
the copy is not the problem.

**Build in the home of the agent, not in `/tmp`.** `/home/agent` is the persistent rootfs. The seed
must stay between the install and the copy, which are not at the same time. A mound can stop
between them, and `dr-cp` restarts it for the copy.

**And not on a mounted Windows directory.** That is the clear way to skip the copy: mount the store
read-write, and build directly into it. It half works, which is worse than a failure. Measured in a
mound, on a bind-mounted workspace:

```text
git clone -q https://github.com/… X   →  clone: OK
mv X Y                                →  mv: cannot move 'X' to 'Y': Permission denied
```

A plain directory renames there with no error, and both succeed in the rootfs. A mount on a Windows
drive refuses only the rename of a *git clone*. `claude plugin marketplace add` clones to a
temporary name, then renames it. Thus `add` fails, but `uninstall`, which only deletes, succeeds.
That is why `dr-plugin` puts the library in `/home/agent/seed`, works there, and later copies it
back with `cp -a`, which only creates.

`sbx cp` follows the conventions of `docker cp`. Thus a directory copied into an existing directory
goes *inside* it. The result is `claude-plugins\seed\`, with `cache\<marketplace>\` and
`marketplaces\<marketplace>\`. Observed.

A new seed also has `installed_plugins.json` and a `.last_inuse_sweep` stamp beside the three
entries above. Observed, and harmless. The documented seed loader of Claude Code reads only
`known_marketplaces.json`, `marketplaces/` and `cache/`. Thus the extra file does not show that the
seed carries the enable decision. The next section covers that. Note what is *not* there: no
`data/`, because nothing gave a plugin anything to keep.

> **Do not build the seed with `cp -r ~/.claude/plugins`.** The documentation of Claude Code
> gives that shortcut, but it is wrong here. The library also contains `data/<plugin-id>/`, where
> plugins keep private state, with `.credentials.json`. A copy of that into a directory mounted into
> each mound gives each mound all that a plugin got. If you set `CLAUDE_CODE_PLUGIN_CACHE_DIR` and
> take the result, that problem does not occur. If you copy by hand, copy only the three entries
> above.

The seed is inert on your host while nothing on the host points Claude Code at it. If you also run
Claude Code on Windows, do not set `CLAUDE_CODE_PLUGIN_SEED_DIR` there.

### Available is not enabled

The seed holds marketplaces and plugin content. It does not hold the decision that a plugin is
*on*. That decision is in `enabledPlugins`, and the two work together by design. When
`enabledPlugins` names a plugin whose marketplace is already in the seed, Claude Code uses the seed
copy, and does not clone.

Thus the configuration file beside the seed is the switchboard:

```json
{
  "enabledPlugins": {
    "commit-commands@claude-code-plugins": true
  }
}
```

Identifiers are `<plugin-name>@<marketplace-name>`. Give the file with `--settings`, which takes a
path. It is an **override on top of** your user and project configuration. Keys that you omit keep
their file values. Thus it does not flatten values that a repository sets for itself.

The other values of a plugin also go here. For example, a plugin with an output style needs
`"outputStyle": "<plugin>:<style>"` in some file. The own `~/.claude/settings.json` of the mound is
lost on `dr-rm`. Here it is durable, and applies to the full machine, beside the plugin that gives
it.

**`enabledPlugins` enables. It does not install.** Measured from a clean plugin state: a session
with the seed mounted, and a configuration file that named all three plugins, registered the
marketplaces and installed nothing.

```text
known_marketplaces.json    839 bytes     <- all three, from the seed
installed_plugins.json     {"plugins": {}}
$ claude plugin list
No plugins installed.
```

Claude Code works as documented here. It is not a fault. Since v2.1.195, a plugin from an external
source that only a configuration file enables does not load until it is installed. `enabledPlugins`
is the switch, and something must still put the plugin there.

After the install, the switch works. The same `plugin list`, with the configuration file passed,
then reports `✔ enabled` for each.
### What a seed actually saves

Here it is in plain words, because an earlier draft of this page claimed more.

| | |
|---|---|
| Registration of the marketplaces | **the seed does this**, at session startup, offline |
| The marketplace URLs in each mound | not necessary: they are in the seed |
| Install of the plugins | **still one `claude plugin install` for each mound** |
| Where an install goes | the own `~/.claude/plugins/cache` of the mound, lost on `dr-rm` |

Thus the seed removes the `marketplace add` step and its network fetch, for the full machine, and
read-only. It does not remove the install step. Measured: from a clean state, all three plugins
were installed into the own cache of the mound (6.9 MB), with the seed mounted and in use.

**Thus option 4 and option 2 work together. They are not alternatives.** Put the seed in your
machine configuration. Let the kit run the one install for each mound, which then uses the seed,
not the network:

```yaml
commands:
  install:
    - command: "env HOME=/home/agent CLAUDE_CODE_PLUGIN_SEED_DIR=/c/Code/claude-plugins/seed claude plugin install simple-english@simple-english -y"
      user: "1000"
      description: Install from the seed, no marketplace add and no clone
```

### The configuration

Two of these go in `~/.config/draugr/config`, so that they apply to each mound, not to one
repository. Both work for each agent. A mount is a mount, and an agent that does not know
`CLAUDE_CODE_PLUGIN_SEED_DIR` ignores it.

```bash
DRAUGR_MOUNTS="/mnt/c/Code/claude-plugins:ro"
DRAUGR_ENV="CLAUDE_CODE_PLUGIN_SEED_DIR=/c/Code/claude-plugins/seed"
```

The third goes in the same file, but not under the generic key. Something must point Claude Code at
the configuration file. That is `--settings`, which is **a flag of Claude Code**. Thus it goes in
the key for the agent, not in `DRAUGR_AGENT_ARGS`:

```bash
DRAUGR_AGENT_ARGS_CLAUDE="--settings /c/Code/claude-plugins/settings.json"
```

`DRAUGR_AGENT_ARGS` holds the own arguments of the agent. A machine value there also goes to each
codex, gemini or copilot mound, at each attach.
[`DRAUGR_AGENT_ARGS_<AGENT>`](CONFIG.md#draugr_agent_args_agent) is selected after the full
cascade, when `DRAUGR_AGENT` is known. It applies only to the agent that it names. Thus all three
lines apply to the full machine, which is the purpose of option 4.

> **A possible simplification, not tested.** `claude --help` has no environment variable for
> `--settings`, but the 2.1.246 binary contains `CLAUDE_CODE_MANAGED_SETTINGS_PATH`. That can go in
> `DRAUGR_ENV` beside the seed path, and remove the third line.
>
> It is a lead, not a recipe. The CLI subcommands read neither the seed nor a configuration file.
> Thus only a session that starts can test it. The variable pointed at bad JSON gave no error in
> either case. It is also not an equal swap. *Managed* settings are the highest level, above the
> own `.claude/settings.json` of a project. `--settings` is below it. Measure it before you trust it.

Know these facts about the lines above:

- The `:ro` is the full purpose. Without it, a mound can rewrite the hook scripts that each other
  mound runs. Then you are back at the objection to option 5.
- **Only the mount applies at creation.** `DRAUGR_ENV` and `DRAUGR_AGENT_ARGS` apply when you
  attach. Thus after the mount exists, a change of either of the other two costs only the next
  `dr-go`.
- **`DRAUGR_ENV` reaches the session of the agent, not `dr-shell`.** Draugr writes those variables
  into the rcfile that it builds for the agent at attach. `dr-shell` runs its command over plain
  `ssh`, with no rcfile. Thus nothing that you run there gets the seed path.
- **Claude Code reads the seed only at session startup.** This is an important trap, because it
  makes the clear test lie. `claude plugin marketplace list` and `claude plugin list` do **not**
  load the seed. Measured: with the variable set explicitly and the mount verified, both reported
  nothing.

  ```bash
  # both of these say "No marketplaces configured", with everything working
  dr-shell -- claude plugin marketplace list
  dr-shell -- env CLAUDE_CODE_PLUGIN_SEED_DIR=/c/Code/claude-plugins/seed claude plugin marketplace list
  ```

  After one session starts, this changes. Startup registers the marketplaces of the seed into the
  own configuration of the mound. From then on, the same `dr-shell` command lists all of them, with
  no variable. Thus a `dr-go` session and `/plugin` give the true answer. A shell can only tell you
  what an earlier session wrote down.
- `DRAUGR_ENV` splits entries on spaces, so the path must not contain any. `dr-go` refuses a bad
  entry, and does not let the agent silently ignore it. Refer to [`DRAUGR_ENV`](CONFIG.md#draugr_env).
- **A repo that sets `DRAUGR_ENV` silently removes the seed.** This is the hole in the claim "one
  place, each mound". Know it before it costs you an afternoon. `DRAUGR_ENV` is a single string,
  and the layers *replace*, not merge. Thus a project that sets it for its own reasons removes the
  machine value:

  ```text
  $ dr-config DRAUGR_ENV
  CLAUDE_CODE_DISABLE_1M_CONTEXT=1 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=25
  ```

  Measured in a repo whose `.draugr.conf` set the compaction point for a local model.
  `CLAUDE_CODE_PLUGIN_SEED_DIR` was gone, and that mound never saw the seed, with a correct mount.
  `DRAUGR_MOUNTS` has the same shape, but stayed, because that project did not set it.

  The layers are sourced in order, in one shell. Thus a project configuration can add to the value,
  and not replace it. A project that needs its own variables must do that:

  ```bash
  DRAUGR_ENV="${DRAUGR_ENV:+$DRAUGR_ENV }CLAUDE_CODE_DISABLE_1M_CONTEXT=1"
  ```

  To find this problem, run `dr-config DRAUGR_ENV` in the repo where you will work.
- `DRAUGR_AGENT_ARGS` **replaces**, and does not extend. If you already use it, add to it, and do
  not overwrite it: `DRAUGR_AGENT_ARGS="--continue --settings /c/Code/claude-plugins/settings.json"`.

Mounts become fixed when Draugr builds a mound. Thus existing mounds need `dr-up --recreate` once.
After that, they do not. The mount and the environment variable stay, and each start reads the
seed again.

> **`--recreate` destroys the mound.** A mound holds three things that exist in no other place:
> commits of the agent that you did not fetch, the memory that it wrote, and hosts opened by hand
> with `dr-policy --allow`. It refuses for each of them, and names the fix: `dr-sync`,
> `dr-mem export`, `dr-kit adopt`. Thus on a mound where you worked, expect one stop, and handle
> it. `dr-up --recreate --force` continues anyway, and throws all three away.
>
> On a mound built only for this, none of it applies.

### Adding the next plugin

This is for **the mound where you built the seed, with `/home/agent/seed` still in it**. That is
the easy case, and it is also the case that ends. `/home/agent` is rootfs, so `dr-rm` removes the
build directory. When you want a fourth plugin, the mound often had a `dr-rm` already.

```bash
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin marketplace add <owner>/<repo>
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin install <plugin>@<marketplace> -y
dr-shell -- ls -la /home/agent/seed
dr-cp -L --raw /home/agent/seed /mnt/c/Code/claude-plugins
```

…then one line in `settings.json`. **No change to your Draugr configuration, and no
`--recreate`.** Each mound gets it at its next start. That is the difference between option 4 and
option 3, and the full reason to use option 4.

### Adding one from a fresh mound

If you run those same commands in a mound that never held the earlier plugins, the last one does
not add to your seed. `sbx cp` extracts a tar over the destination, so **directories merge and
same-named files are replaced**. We measured this: we copied two unrelated trees into one host
directory, one after the other:

| in the seed after it | |
|---|---|
| `marketplaces/<new>`, `cache/<new>` | added |
| `marketplaces/<old>`, `cache/<old>` | **kept**: the names are different, so nothing overwrites them |
| `known_marketplaces.json` | **replaced**, and names only the new marketplace |

That is the worst of the three possible results. The files of the old plugins are all still there.
Thus the seed looks right, and its size shows no problem. But nothing registers them now. Each
mound loses them at its next start, with no error.

Thus put the seed back before you build on it. `dr-cp --to` puts it at exactly the build path,
owned by the agent. The plugin CLI then reads it as the library that it already is:

```bash
dr-shell -- rm -rf /home/agent/seed
dr-cp --to /mnt/c/Code/claude-plugins/seed /home/agent    # -> /home/agent/seed

# the check that it took: your existing marketplaces, before adding anything
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin marketplace list
```

Then run the commands above, unchanged. `marketplace add` merges into the library that it finds.
Thus `known_marketplaces.json` comes back with all of them. Measured: a fourth marketplace added to
a restored seed of three.

The `rm -rf` has the same reason as all else on this page. A half-built `/home/agent/seed` from an
abandoned try stays after the copy, and gets into the seed.

### Updating a plugin

Nothing updates itself, so the shape is the same as for an add. Put the seed back into a mound as a
writable build directory, work on it there, and swap the result in.

```bash
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin marketplace update                       # a name updates just that one
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin update <plugin>@<marketplace> -y
```

`marketplace update` refreshes the catalogs, and `plugin update` acts on their new contents. Both
need `github.com`, which sbx allows for the full machine. Measured on a current seed:

```text
Updating marketplaces...✔ Successfully updated 3 marketplaces
Checking for updates for plugin "superpowers@superpowers-marketplace" at user scope…
✔ superpowers is already at the latest version (6.3.0).
```

`-y` is necessary for the same reason as at install. Here it accepts a specific thing: an install
command from the marketplace that *changed* since you last accepted it. Your review is to read it
before you pass `-y`.

**Then swap the seed. Do not copy over it.** The cache key is the version:

```text
cache/superpowers-marketplace/superpowers/6.3.0
```

Thus each version is a separate directory, and `dr-cp` merges directories. If you copy an updated
build directory onto your existing seed, the old version stays beside the new one, once for each
update, forever. That is true for each build directory, also a clean one. The merge comes from the
copy, not from what you copied.
Nothing tells you. We measured this: we put an old `0.9.0` beside a live `1.0.0` in a build
directory. `claude plugin update`, `claude plugin prune` and `claude plugin list` all left it where
it was, and `list` named only `1.0.0`. Thus no command shows the old copy, but it is still mounted
into each mound.

[Rebuilding the seed](#rebuilding-the-seed-and-the-swap) is the swap.

### Removing a plugin

Three things go, and only the first is clear.

```bash
# 1. the plugin
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin uninstall <plugin>@<marketplace> -y

# 2. its marketplace, if nothing else came from it
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin marketplace remove <marketplace>
```

3. The line in `settings.json`. If `enabledPlugins` still names a plugin that no mound can find,
   nothing fails. But it is a switch connected to nothing, and the next reader of the file believes
   it.

Measured: `uninstall` deletes the version directory and its entry in `installed_plugins.json`.
`marketplace remove` deletes the marketplace clone and its entry in `known_marketplaces.json`. A
seed of three went from 37 MB to 32 MB. It leaves the empty parent chain,
`cache/<marketplace>/<plugin>/`, with no version inside. That costs nothing. But know it, because a
`find` in your seed still names a plugin that you removed.

**Then swap, and do not copy.** This is the one place where a mistake is fully silent. `dr-cp`
merges. Thus if you copy a build directory without the plugin onto a seed that still has it,
nothing is removed. `known_marketplaces.json` is a top-level file, and is replaced. Thus the
marketplace really does deregister. But each byte of the plugin stays on disk, and stays mounted
read-only into each mound. The seed looks smaller in the list, but it is not smaller.

Inside a mound, `/plugin disable` is the lighter answer. It stops the load of a plugin, and does not
touch the seed. Use it when you possibly want the plugin back.

### Rebuilding the seed, and the swap

An update, a removal and a rebuild from nothing all end in the same way, and never with a copy onto
your seed. Copy the build directory to a different place, then swap:

```bash
dr-cp -L --raw /home/agent/seed /mnt/c/Code/claude-plugins-new
mv /mnt/c/Code/claude-plugins/seed /mnt/c/Code/claude-plugins/seed.old
mv /mnt/c/Code/claude-plugins-new/seed /mnt/c/Code/claude-plugins/seed
```

A copy directly onto the old seed is the merge in its third form. The previous copy of each plugin
stays under the new one, and a plugin that you removed on purpose is still there, and still enabled.
The swap also leaves you a copy to put back when a rebuild goes wrong. A deletion of the seed first
does not. Keep `seed.old` until one session proves that the new one works.

A mound reads the seed at startup. Thus a replacement under a running session is not a problem to
solve, only a fact to know.

### What the seed will not do

- **Auto-update is off**, by design. A `git pull` fails on a read-only mount. You update on purpose.
  Refer to [updating a plugin](#updating-a-plugin). That is the right default inside a sandbox. A
  plugin that silently updates itself changes executable code that nobody reviewed.
- **`/plugin marketplace remove` and `update` fail inside the mound**, with a message that points at
  the seed. That is expected, not broken.
- **Seed entries win.** At each startup, a marketplace in the seed overwrites a matching entry in the
  own configuration of the mound. To turn one off, use `/plugin disable`. Do not try to remove the
  marketplace.
- **`dr-scan` does not look inside extra mounts.** It scans the current repository. You must keep the
  seed clean, as for each other `DRAUGR_MOUNTS` entry.

### What a plugin still needs from the mound

The seed holds the code of a plugin. On purpose, it does not hold two other things. Both show in the
same way: a plugin that installs cleanly, loads with no error, and does nothing useful.

**State, with credentials.** The private directory of a plugin is `plugins/data/<plugin-id>/`. It
is created in the MOUND, not in the seed. Measured in a mound that ran two of them:

```text
/home/agent/.claude/plugins/data/simple-english-simple-english
/home/agent/.claude/plugins/data/superpowers-superpowers-marketplace
```

That is rootfs, so `dr-rm` removes it with all else of the agent. A plugin that authenticates must
authenticate again in the next mound. That is the trade-off working, not failing. `data/` is where a
plugin keeps `.credentials.json`. The [warning against a copy of it into the
seed](#building-it-inside-a-mound) is the only barrier between the token of one mound and each other
mound on the machine. A plugin that needs a durable secret must get it from `DRAUGR_ENV` or an
`sbx` secret. Then you gave it on purpose, and no copy carried it.

**Network, at session time, not at install time.** The machine sbx rules let the build reach
`github.com`. They say nothing about the hosts that the MCP server or hook of a plugin calls when
it runs. Default-deny is real, and the refusal does not look like a refusal.

It arrives as **HTTP 403 from the proxy**, not as a connection failure. We measured this, with two
hosts from inside a mound:

```text
$ curl -o /dev/null -w '%{http_code}\n' https://httpbin.org/get
403
```

That is why a blocked plugin wastes an afternoon. A client that gets a 403 reports an
*authentication* problem, and sends you to examine credentials that were correct. `dr-policy` tells
you the truth, and it did:

```text
$ dr-policy --denied
5 host(s) refused for draugr-claude
  example.invalid.test
  httpbin.org
  http-intake.logs.us5.datadoghq.com
  ...
```

```bash
dr-policy --denied              # what this mound tried to reach and was refused
dr-policy --allow <host>        # open it on the RUNNING mound, no rebuild
dr-kit adopt                    # write what you accepted into the kit
```

That loop belongs to the repository, not to the seed, on purpose. The seed applies to the full
machine, and is not visible. A hole in a network policy is exactly the decision that you must
commit in a place where a reviewer sees it.

### Install-time network: github over SSH, which a mound cannot do

`claude plugin install` clones a github plugin **source** over SSH. It does not fall back as
`claude plugin marketplace add` does. Measured on `iha2/superlite`, in one `dr-plugin add`:

```text
Adding marketplace…SSH not configured, cloning via HTTPS: https://github.com/iha2/superlite.git
✔ Successfully added marketplace: superlite-dev

Installing plugin "superlite@superlite-dev"...✘ Failed to install plugin:
  Failed to clone repository: Cloning into '/home/agent/seed/cache/temp_github_…'
  Connection closed by 140.82.121.4 port 22
```

The marketplace step found no SSH, and said so. The install step still tried port 22. **Egress was
never the problem.** A blocked host arrives as HTTP 403 from the proxy. This request got through to
GitHub, which closed it, because it had no key for authentication. A mound has no SSH key and must
not get one. Thus an SSH clone can never succeed there.

> **The failing clone was not the plugin that you asked for.** `superlite` declares
> `"source": "./"`, and needs no clone. Its marketplace also lists `claude-agent-map` with
> `{"source": "github", "repo": "iha2/claude-agent-map"}`, and `superlite` depends on it. Thus the
> clone that failed was that of the **dependency**, reported under the name of the parent. That is
> why the error seemed to say that a repository, cloned a moment before, failed to clone.

Thus `dr-plugin` sets the own redirect of git for each plugin command that it runs:

```bash
GIT_CONFIG_COUNT=2
GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf   GIT_CONFIG_VALUE_0=git@github.com:
GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf   GIT_CONFIG_VALUE_1=ssh://git@github.com/
```

Environment, not `git config --global`, because it goes with the env that `build_run` already sets.
Nothing must guess the `HOME` of the CLI. No file is written into the mound. The redirect reaches
each `git` that the CLI starts. `insteadOf` can have many values, so both spellings share one key.
It can only add to what works, because SSH never succeeds there.

With it, the same command installs `superlite` **and** its dependency, and `dr-plugin skills`
reports its eleven skills.

### Layering more than one seed

`CLAUDE_CODE_PLUGIN_SEED_DIR` accepts several paths, separated by `:`. Claude Code searches them in
order, and the first match wins for each marketplace. Thus you can mount a team seed read-only
beside a personal one, with no merge of the two:

```bash
DRAUGR_MOUNTS="/mnt/c/Code/claude-plugins:ro /mnt/c/Code/team-plugins:ro"
DRAUGR_ENV="CLAUDE_CODE_PLUGIN_SEED_DIR=/c/Code/claude-plugins/seed:/c/Code/team-plugins/seed"
```

**If you use this, test it once.** The separator is `:` on Unix and `;` on Windows. The agent inside
the mound is on Linux, so `:` applies. That is true, though you set it up from WSL, with paths that
started on a Windows drive.

### Follow-up: `--plugin-dir` pointed straight at the seed

Option 4 still costs one `claude plugin install` for each mound, and that install is a *copy*. The
plugin content is already mounted, and the install writes it again into the own library of the
mound. The `--plugin-dir` of option 3 has neither cost. It loads a plugin from a directory, with no
marketplace and no install step. Thus the clear question: can it point at the read-only seed?

**It can.** Measured in a session started on the mounted seed, with nothing installed for it:

```bash
DRAUGR_AGENT_ARGS_CLAUDE="--plugin-dir /c/Code/claude-plugins/seed/cache/claude-code-plugins/commit-commands/1.0.0"
```

```text
$ claude -p 'List every slash command whose name contains the word commit. Names only.'
- commit-commands:commit-push-pr
- commit-commands:commit
```

The plugin loaded from a mount that refuses writes. A `touch` there really answers `Read-only file
system`. It registered its commands under its own name, and nothing gave an error. No install,
nothing copied into the mound, and it stays after `dr-rm` for the same reason as the seed.

**Hooks also work**, and that result was not certain. We measured it with a test plugin in the
read-only mount. Its `SessionStart` hook reported two facts about itself:

```text
PROBE_HOOK_FIRED root=/c/Code/claude-plugins/probe-plugin write=READONLY
```

The hook ran, and `CLAUDE_PLUGIN_ROOT` resolved to the mount. Its `touch` into its own directory
was refused. The session continued, and used the context from the hook. Claude Code does not stop
on a plugin that cannot write to itself.

Two things that look like problems are not. `superpowers` is safe by inspection. Its one
`SessionStart` hook runs `cat` on a skill file and prints JSON. Its `package.json` is not a
problem either, because the own *installed* copy of the mound also has no `node_modules`. The
install creates none, so `--plugin-dir` skips nothing.
Why it is a follow-up, not the recommendation:

- **The path contains the version.** You must write `.../commit-commands/1.0.0`. Thus each update
  needs an edit of your Draugr configuration, and option 4 exists to remove exactly that cost.
- **One flag for each plugin.** Six plugins need six `--plugin-dir` flags in one string. Option 3
  was already weakest there.
- **No command can show it.** `--plugin-dir` applies only to a session, and no subcommand takes it.
  `claude plugin list --plugin-dir …` answers `error: unknown option '--plugin-dir'`. `claude plugin
  list` never names it. The only test is to start a session and ask. That is the same trap as
  [the seed being read at startup and nowhere else](#the-configuration), but worse.
- **There is no switch.** It ignores `enabledPlugins`. Thus a plugin named this way is on in each
  mound, and `/plugin disable` has nothing to act on.
- **`--bare` turns it off**, with hooks, `--settings` and `--agents`.
- **A hook that must write in its own directory fails** silently, as all else on this page does.
  Measured above: the write is refused, and only the hook itself says so.

Use it for a plugin that you never update, or to try one before you put it in the seed. It does not
replace option 4.

## Which plugins ship skills, and where they are

The skills of a plugin are **not** in the shared skills store, and never show in `dr-skills list`.
They are inside the plugin, and Claude Code loads them from there at session start. The two are
different directories with different trust properties. That is the full argument of
[option 5](#5-the-shared-skills-store):

| | skills store | plugin library |
|---|---|---|
| Host directory | `…\DockerSandboxes\sandboxes\state\agent-skills` | `$DRAUGR_PLUGIN_STORE` |
| Managed by | `dr-skills` | `dr-plugin` |
| Mounted into a mound | `~/.claude/skills`, **read-write** | read-only, through `DRAUGR_MOUNTS` |
| Contents | only what is copied in | marketplaces and plugin content |

That split is correct, and Draugr keeps it. But it made `dr-skills list` misleading. It reported one
skill on a machine whose plugin library held fifteen, and said nothing about them.

**Discovery is a directory walk, not a query.** `plugin.json` declares hooks, MCP servers and the
rest, and says nothing about skills. Skills follow the convention `skills/<name>/SKILL.md`. Measured
on the three plugins in use here:

| Plugin | Skills |
|---|---|
| `commit-commands` 1.0.0 | none: no `skills/` directory |
| `simple-english` 2.1.1 | 1 |
| `superpowers` 6.3.0 | 14 |

Each `SKILL.md` starts with YAML front matter that holds `name:` and `description:`. Draugr uses
`name:`, not the directory name, because the agent matches on it, and the two can be different.

> **Draugr reads the front matter with `sed`: one scalar, and no YAML parser.** In one of those
> three, `description:` is already a block scalar (`description: |`, six lines). In another, it is
> a quoted single line. Thus a simple read of it is wrong. The dependencies of Draugr are `git`,
> `jq` and `rsync`. `name:` is always a plain scalar, so it is safe. `dr-kit` reads `displayName:`
> in the same simple way. A list is not worth a new dependency.

Thus two commands report it:

```bash
dr-plugin skills      # every skill an installed plugin ships, with the plugin it comes from
dr-skills list        # the store, then the same list under "also shipped by plugins"
```

`dr-skills` gets the section, not the logic. The walk is `dr_plugin_skills` in `lib/common.sh`, and
both commands call it. A call from one command to the other connects two things that now share
nothing. The section is **silent when `DRAUGR_PLUGIN_STORE` is unset**. The plugin feature is off
by default, and an empty heading on a machine with no plugins is worse than no heading.

The text there has a condition, and it is important. These skills are not available as a store
entry is. They arrive only after the install of the plugin **in that mound**. The next section is
about that step. The words "also available" bring back the first confusion, in the other direction.

## `dr-plugin kit`: the per-mound install, generated

`dr-plugin` manages the host library fully: add, update, remove, enable, clean, rollback. But it did
not touch the one step that you must repeat: [the install into each
mound](#what-a-seed-actually-saves). Each new mound, each plugin, by hand.

`dr-plugin kit` writes that install as a kit in your kit library, which you can combine with others:

```bash
dr-plugin kit                                   # one kit per installed plugin
dr-plugin kit simple-english@simple-english     # or only the ones you name
```

It makes `$DRAUGR_KIT_STORE/plugin-<plugin>/spec.yaml`. That is a `kind: mixin` with the single
`commands.install` entry from [the partners section](#what-a-seed-actually-saves), with the seed
path already in its mound spelling. Then it prints the `DRAUGR_KIT` entry to add. This is the same
shape as `dr-forge gateway`: make a directory from the known facts, then say what to do with it.

**One kit for each plugin, not one kit for all of them.** The reason is a limit, not a preference.
From the contract of `dr-kit`:

> Only one change can be applied to a running mound: kits **ADDED** to the end of the list. sbx
> refuses to re-add a kit it already has, and cannot remove one, so an edited or removed kit needs
> `dr-up --recreate`.

You must *edit* a combined `plugins` kit for each new plugin. That forces a recreate of each existing
mound. With separate kits, a new plugin adds a name to the list. That is exactly the one change that
applies in place.

### Why the generated kit pins no version

The install line names `<plugin>@<marketplace>` and nothing more. Thus it resolves against the
contents of the seed at the time a mound is created. That is on purpose. It makes `dr-plugin update`
and this verb independent: **after an update, the same kit installs the new version, with no new
kit.**

A pin does the opposite. With a version in the kit, each `dr-plugin update` edits a kit. An edited
kit cannot apply to a running mound. Thus each plugin update becomes a rebuild of each mound that
uses it. The seed is the one answer to "which version", and the kit follows it.

Two results follow, and neither is a defect of the kit:

- **A mound created before an update keeps the old version.** The install already ran, into the own
  `~/.claude/plugins/cache` of that mound, which is rootfs. It stays the same until you recreate the
  mound, or run the install again inside it.
- **After `dr-plugin remove`, a kit can point at a plugin that the seed does not have.** Thus
  `remove` says so when a generated kit names the plugin that it removes. It does not delete the
  kit. You can edit a kit in your library, and a plugin removal is not consent to delete it.

### Open: does `commands.install` run on apply?

Not known, and it changes only the last message of the command. If `install` runs when a kit is
*applied* to a running mound, then make, add, `dr-kit apply` is the full process. If it runs only at
creation, the kit works from the next mound, and the current mound still needs one `dr-shell`
install.

Until somebody measures it, the last advice of the generated kit says both, because both are true.
A related measurement is bad news. sbx kit **startup** commands stop working after a daemon restart.
Thus do not trust `install` to work as documented either.

## Checks worth running once

We measured most of this page, and did not only read about it. The banner at the top says on which
versions. These tests find a seed whose configuration is correct, but which still does not work:

| | |
|---|---|
| `/plugin`, inside a `dr-go` session | the real answer: installed **and** enabled, which are two questions |
| `dr-shell -- claude plugin marketplace list` | **after** one session: before that, it says nothing, whatever is mounted |
| `dr-shell -- ls /c/Code/claude-plugins/seed` | the mount arrived, at the mirrored path |
| `dr-shell -- touch /c/Code/claude-plugins/seed/x` | fails with `Read-only file system`: the `:ro` is real |
| `dr-shell -- grep claude-plugins /proc/mounts` | `virtiofs ro,relatime`: the kernel enforces it |
| `dr-policy --check github.com` | the build step can reach the marketplace |
| a session with `--plugin-dir` at a seed path | the only way to see one: no subcommand accepts the flag |
| `dr-policy --denied`, after a session | what a plugin tried to reach at RUN time, and was refused |
| `dr-shell -- python3 --version` | interpreters that the hooks in your plugins need |

The last one fails in a way that looks like nothing. A hook whose interpreter is missing fails on
each edit, silently, and the plugin seems to do nothing.
