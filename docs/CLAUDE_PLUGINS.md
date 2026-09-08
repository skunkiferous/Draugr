# Claude Code plugins

A Claude Code *plugin* is a directory with a `.claude-plugin/plugin.json` manifest, carrying any of
`skills/`, `commands/`, `agents/`, `hooks/`, `.mcp.json`, `.lsp.json` and `bin/`. A *marketplace* is
a repository with a `.claude-plugin/marketplace.json` cataloguing one or more of them. Normal use is
two steps: register the marketplace, then install a plugin from it.

> **Measured**, against sbx 0.37.1 and Claude Code 2.1.246, in a mound whose plugin state was moved
> aside first so the result could not be residue from an earlier experiment. What the seed does and
> does not do is set out under [what a seed actually saves](#what-a-seed-actually-saves), and it is
> less than an earlier draft of this page claimed: it supplies the marketplaces, not the installs.

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

**`add` takes a marketplace, not a plugin**, and registering one is not a separate step. Normal use
is two commands — register the catalogue, then install from it — and `add` is both. Name nothing
after the marketplace and you get everything it lists; name plugins and you get only those:

```bash
dr-plugin add obra/superpowers                     # every plugin it lists
dr-plugin add obra/superpowers superpowers         # only that one
dr-plugin add anthropics/claude-code a b c         # only those three
```

The marketplace's *registered* name is discovered rather than typed, because the repository decides
it: `obra/superpowers` arrives as `superpowers-marketplace`. So the plugin you name may be bare, and
`dr-plugin` completes it with whatever appeared.

`dr-plugin` with no arguments checks the three settings that make the library reachable from a mound
and prints the exact lines when they are missing, so the only one you have to know is the store.

Every plugin operation happens inside a mound created for it and destroyed afterwards. Your host
never runs plugin code; it receives a directory and mounts it back read-only. The library being
edited is always a copy, so a failed build changes nothing and the previous one stays as `seed.old`.

**The rest of this page is what that command does, and why.** It is worth reading if you want to do
it by hand, or when something does not work — every claim below was measured rather than assumed.
The single fact that shapes all of it:

> `sbx cp` extracts a tar, so **directories merge and same-named files are replaced**.

That is why copying a rebuilt library over an existing one adds and never removes, why updates
accumulate versions for ever, and why a manual removal reclaims nothing. `dr-plugin` sidesteps it
entirely by never using `dr-cp`: it works on a host-side copy and swaps.

## Why plugins are a different problem from skills

A skill is instructions. A plugin is **code that runs**: hooks fire on session start and after tool
use, MCP servers are processes, `bin/` lands on the Bash tool's `PATH`, and a plugin with a
`package.json` gets `npm ci --ignore-scripts` run against it at install time.

That is the whole reason this page exists. Draugr's premise is that an agent can be trusted with a
mound because the mound is disposable and cannot reach your machine. Third-party plugin code has
exactly the same status as the agent itself: fine inside a mound, not something to install on your
host so that a mound can borrow it.

So the rule this page follows throughout:

**Your host stores plugin bytes. It never runs them.**

Persistence and safety pull in opposite directions here — a mound is disposable, so anything that
must outlive `dr-rm` has to live on the host — and that sentence is the line that resolves them.
Every option below either keeps the plugin inside the mound entirely, or keeps it on the host as
inert files mounted **read-only**. None of them asks you to run `claude plugin install` on Windows.

## Where a plugin lives inside a mound

Claude Code keeps its plugin library in `~/.claude/plugins/`:

```text
known_marketplaces.json                      the catalogues you have registered
marketplaces/<name>/                         each catalogue, cloned
cache/<marketplace>/<plugin>/<version>/      the plugin itself
data/<plugin-id>/                            per-plugin state, including .credentials.json
```

In a mound that is ordinary rootfs, which puts it in the same class as the agent's login:

| | |
|---|---|
| Survives `dr-stop` and the next `dr-up` | yes |
| Survives `dr-rm` | **no** |
| Shared with your other mounds | no |
| Reachable from the host | no |

Compare `~/.claude/projects` and `~/.claude/sessions`, which are per-sandbox disk images, and
`~/.claude/skills`, which is a bind mount from the host shared by every mound — see
[SECURITY.md](SECURITY.md#trap-2--the-skills-store-is-a-writable-door-out).

So the honest baseline answer to "how do I use a plugin in a mound" is: install it, once, in that
mound, and again in the next one. The five options below are the ways out of that.

## The five options

Ordered by reach. "Host runs the code" is `no` on every row, and that is not a coincidence — it is
the constraint the list was built under.

| | Reach | Survives `dr-rm` | Host stores it | Writable from a mound | Cost per extra plugin |
|---|---|---|---|---|---|
| 1. Install in the mound | one mound | no | nothing | n/a | one command, per mound |
| 2. Kit `commands.install` | every mound of one repo | yes, reinstalls | nothing | no | two lines in the kit |
| 3. `--plugin-dir` | wherever you configure it | yes | inert files | **no** | a clone **and** a flag |
| 4. Seed directory | every mound | the content, yes | inert files | **no** | one command, plus an install per mound |
| 5. Shared skills store | every mound, every agent | yes | inert files | **yes** | a clone |

Option 4 is documented in full below. The rest are sketched here and can be expanded later.

### 1. Install it in the mound

```bash
dr-shell -- claude plugin marketplace add anthropics/claude-code
dr-shell -- claude plugin install commit-commands@claude-code-plugins -y
```

`-y` is required: `claude plugin install` is interactive unless stdin and stdout are not a TTY, or
you pass it. `github.com` is covered by `sbx`'s machine-wide allow rules, so the clone works —
confirm with `dr-policy --check github.com`.

> ### `dr-shell --` takes a command, not a command *line*
>
> Everything after `--` is an argv vector, `printf '%q'`-quoted one argument at a time for the far
> side. Wrapping a whole line in quotes makes it a single word, and that fails in two different
> ways:
>
> ```bash
> dr-shell -- "claude plugin list"          # one word; "command not found"
> dr-shell -- "FOO=/tmp/seed claude plugin list"   # a variable assignment. Exit 0, silence
> ```
>
> The second is the dangerous one. Bash reads `name=value` with no command as an assignment, sets
> the variable to the rest of the line, runs nothing and **succeeds** — no output, no error, exit 0,
> and no plugin installed. Pass the words separately, and use `env` when you need a variable:
>
> ```bash
> dr-shell -- env FOO=/home/agent/seed claude plugin list
> ```
>
> `env` is a real binary, so it needs no shell on the far side. Nothing here expands `~` either, for
> the same reason — mound-side paths in a `dr-shell` command must be absolute.

Nothing touches the host. It dies with `dr-rm`. This is the right way to *try* a plugin, and the
wrong way to *keep* one.

### 2. Bake it into the kit

Put the same two commands in `.draugr/kit/spec.yaml` under `commands.install`, and every mound built
for that repo installs the plugin as it is created:

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

`user: "1000"` so the install writes to the agent's home rather than root's, and an explicit `HOME`
because these do not run in a login shell. It survives `dr-rm` in the sense that matters: the next
mound reinstalls it.

This is the only option a **collaborator gets automatically** — the kit is committed, so cloning the
repo brings the plugin with it. That is also its risk: a kit that installs third-party code is
something a reviewer should see, exactly like any other dependency.

### 3. `--plugin-dir`, off a read-only mount

Claude Code can load a plugin directory directly, with no marketplace and no install step. Clone it
once, mount it read-only, name it in the agent args:

```bash
DRAUGR_MOUNTS="/mnt/c/Code/claude-plugins:ro"
DRAUGR_AGENT_ARGS_CLAUDE="--plugin-dir /c/Code/claude-plugins/commit-commands"
```

A mount lands at the mirrored path, so `C:\Code\claude-plugins` is `/c/Code/claude-plugins` inside —
see [`DRAUGR_MOUNTS`](CONFIG.md#draugr_mounts).

Simple, honest, and read-only. The catch is that `--plugin-dir` takes **one plugin per flag**, so a
library of six plugins is six flags, and adding a seventh means editing your Draugr config. That is
what option 4 fixes.

It composes with option 4 rather than competing with it, and that turns out to work: see
[pointing it straight at the seed](#follow-up---plugin-dir-pointed-straight-at-the-seed).

### 4. A seed directory

One host directory holding every plugin you use, mounted read-only into every mound. Adding a plugin
is one command against the seed and no change to your Draugr configuration. Detailed below.

It supplies the marketplaces rather than the installs, so it pairs with option 2 rather than
replacing it — see [what a seed actually saves](#what-a-seed-actually-saves).

Its settings are machine-wide even where several agents are in play: the seed itself is
agent-neutral, and the one Claude-Code-specific line goes in
[`DRAUGR_AGENT_ARGS_CLAUDE`](CONFIG.md#draugr_agent_args_agent), which applies only to claude
mounds. See [the configuration](#the-configuration).

### 5. The shared skills store

A plugin directory placed in the shared skills store loads as `<name>@skills-dir` with no
marketplace and no install step — the store is mounted at `~/.claude/skills` in every claude mound,
so one copy reaches every mound on the machine and survives `dr-rm`. It is the cheapest option and
it is listed last on purpose.

> The store is the one path by which a sandbox can write to your host, it is shared by every mound,
> and it outlives the mound that wrote it. That is already the reason `dr-skills diff` exists for
> *instructions*. A plugin puts **executables** there instead: hook scripts that every mound runs at
> every session start, in a directory any mound can rewrite. One compromised mound edits the script;
> the next unrelated mound runs the edit.
>
> `dr-skills diff` and `dr-skills accept` are still the mitigation and they still work. But option 4
> gets you the same reach with the directory mounted **read-only**, which removes the amplification
> rather than reviewing it. Prefer it.

Note also that the store is shared across agents, so a plugin left there is in reach of your codex
mounds too, where nothing will load it and it will simply sit on your disk.

---

## Option 4 in detail: a seed directory

Claude Code has a mechanism built for container images: a **plugin seed**. It is a pre-built copy of
the `~/.claude/plugins` library that Claude Code reads at startup — registering the seed's
marketplaces and using its plugin caches in place, without cloning anything and without writing to
the directory.

That is exactly the shape Draugr wants. The seed is built inside a disposable mound, carried out as
inert files, and mounted read-only into every mound afterwards.

### The layout

```text
C:\Code\claude-plugins\
├── seed\                        ← CLAUDE_CODE_PLUGIN_SEED_DIR
│   ├── known_marketplaces.json
│   ├── marketplaces\<name>\…
│   └── cache\<marketplace>\<plugin>\<version>\…
└── settings.json                ← which of them are switched on
```

Those three entries under `seed\` are the whole of what Claude Code consumes. Nothing else in the
directory is read.

### Building it, inside a mound

Point Claude Code's plugin cache at a build path, install what you want, and carry the result out.
Run this from any repository that has a mound; the seed is machine-wide and not a property of the
project you happen to be standing in.

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

Sooner or later a plugin ships a symlink. `superpowers` ships `AGENTS.md` as a link to `CLAUDE.md`,
and without `-L` the copy dies on it:

```text
ERROR: extract to C:\Code\claude-plugins: symlink CLAUDE.md
       …\superpowers\6.3.0\AGENTS.md: A required privilege is not held by the client.
```

That is Windows, not Draugr: creating a symlink on NTFS needs `SeCreateSymbolicLinkPrivilege`,
which an ordinary account does not hold unless Developer Mode is on. **A failure here leaves a
partial tree**, so clear it before retrying — a half-copied seed is not something to mount.

`-L` copies what each link points at instead. Unlike `cp -L` and `docker cp -L`, which follow only a
link named as the source, `sbx` follows links found **anywhere in the tree** — measured against sbx
0.37.1, a seed of three marketplaces came out whole, 2262 files, `AGENTS.md` arriving as a real
8873-byte file with no link left anywhere in it.

Dereferencing is the right answer here rather than a concession. `AGENTS.md` becomes a copy of
`CLAUDE.md` rather than a link to it, which for a plugin is the same thing — and it avoids a
question the symlink route would only raise later, namely what a mound makes of an NTFS symlink
presented back through virtiofs. It stays opt-in on `dr-cp` because for any other copy, silently
turning links into copies would change what came out of the mound.

Everything that executes during the build — the clone, `npm ci` for any plugin with a lockfile, the
plugin's own install-time machinery — happens inside a mound you are about to throw away. The host
receives a directory tree and nothing else.

The `ls` is not ceremony. `claude plugin` prints little on success, so the two commands above look
identical whether they worked or did nothing at all, and the first thing that *notices* is `dr-cp`
failing with `path not found in container` — by which point the interesting error is long gone.
Expect `known_marketplaces.json`, `marketplaces/` and `cache/`; anything less means the install
failed and the copy is not the thing to debug.

**Build in the agent's home, not `/tmp`.** `/home/agent` is the persistent rootfs, and the seed has
to survive between the install and the copy — which is not one moment. A mound can stop in between,
and `dr-cp` will restart it to do the copy.

**And not on a mounted Windows directory either**, which is the obvious way to skip the copy
entirely: mount the store read-write and build straight into it. It half works, which is worse than
failing. Measured, in a mound, on a bind-mounted workspace:

```text
git clone -q https://github.com/… X   →  clone: OK
mv X Y                                →  mv: cannot move 'X' to 'Y': Permission denied
```

A plain directory renames there without complaint, and both succeed in the rootfs — it is renaming a
*git clone* that a Windows-backed mount refuses. `claude plugin marketplace add` clones to a
temporary name and renames it into place, so `add` fails while `uninstall`, which only deletes,
succeeds. This is why `dr-plugin` stages the library into `/home/agent/seed`, works there, and copies
it back afterwards with `cp -a`, which only ever creates.

`sbx cp` follows `docker cp` conventions, so a directory copied into an existing directory lands
*inside* it: the result is `claude-plugins\seed\`, holding `cache\<marketplace>\` and
`marketplaces\<marketplace>\`. Observed.

A freshly built seed also carries `installed_plugins.json` and a `.last_inuse_sweep` stamp beside
the three entries above — observed, and harmless. Claude Code's documented seed loader reads only
`known_marketplaces.json`, `marketplaces/` and `cache/`, so the extra file is not evidence that the
seed carries the enable decision. That is the next section's job. Note what is *not* there: no
`data/`, because nothing has given a plugin anything to keep.

> **Do not build the seed with `cp -r ~/.claude/plugins`.** Claude Code's own documentation offers
> that shortcut and it is the wrong one here: the library also contains `data/<plugin-id>/`, where
> plugins keep private state including `.credentials.json`. Copying that into a directory mounted
> into every mound on the machine hands every mound whatever a plugin has been given. Setting
> `CLAUDE_CODE_PLUGIN_CACHE_DIR` and taking the result avoids the question; if you ever do copy by
> hand, copy the three entries above and nothing else.

The seed is inert on your host for exactly as long as nothing on the host points Claude Code at it.
If you also run Claude Code on Windows, do not set `CLAUDE_CODE_PLUGIN_SEED_DIR` there.

### Available is not enabled

The seed carries marketplaces and plugin content. It does not carry the decision that a plugin is
*on* — that lives in `enabledPlugins`, and the two are designed to compose: when `enabledPlugins`
names a plugin whose marketplace is already in the seed, Claude Code uses the seed copy instead of
cloning.

So the settings file beside the seed is the switchboard:

```json
{
  "enabledPlugins": {
    "commit-commands@claude-code-plugins": true
  }
}
```

Identifiers are `<plugin-name>@<marketplace-name>`. Feed the file in with `--settings`, which takes
a path and layers as an **override on top of** your user and project settings — keys you omit keep
their file values, so it will not flatten anything a repository sets for itself.

This is also where a plugin's other settings go. A plugin that ships an output style, for example,
needs `"outputStyle": "<plugin>:<style>"` somewhere, and the mound's own `~/.claude/settings.json`
dies with `dr-rm`. Putting it here makes it durable and machine-wide alongside the plugin that
provides it.

**`enabledPlugins` enables; it does not install.** Measured from a clean plugin state: a session
with the seed mounted and a settings file naming all three plugins left the mound with its
marketplaces registered and nothing installed at all.

```text
known_marketplaces.json    839 bytes     <- all three, from the seed
installed_plugins.json     {"plugins": {}}
$ claude plugin list
No plugins installed.
```

That is Claude Code behaving as documented rather than a fault: since v2.1.195 a plugin from an
external source that only a settings file enables does not load until it is installed. `enabledPlugins`
is the switch, and something still has to have put the plugin there for the switch to act on.

Install it and the switch works — the same `plugin list`, with the settings file passed, then reports
`✔ enabled` for each.

### What a seed actually saves

Worth stating plainly, because an earlier draft of this page claimed more.

| | |
|---|---|
| Registering the marketplaces | **the seed does this**, at session startup, offline |
| Knowing the marketplace URLs in each mound | not needed — they ride in the seed |
| Installing the plugins | **still one `claude plugin install` per mound** |
| Where an install lands | the mound's own `~/.claude/plugins/cache`, which dies with `dr-rm` |

So the seed removes the `marketplace add` step and the network fetch that comes with it, machine-wide
and read-only. It does not remove the install step. Measured: from a clean state, all three plugins
installed into the mound's own cache — 6.9 MB — even with the seed mounted and pointed at.

**Which makes option 4 and option 2 partners rather than alternatives.** Put the seed in your
machine-wide config, and let the kit run the one install per mound, where it resolves against the
seed rather than the network:

```yaml
commands:
  install:
    - command: "env HOME=/home/agent CLAUDE_CODE_PLUGIN_SEED_DIR=/c/Code/claude-plugins/seed claude plugin install simple-english@simple-english -y"
      user: "1000"
      description: Install from the seed, no marketplace add and no clone
```

### The configuration

Two of these belong in `~/.config/draugr/config`, so they apply to every mound rather than one
repository. Both are agent-neutral: a mount is a mount, and an agent that has never heard of
`CLAUDE_CODE_PLUGIN_SEED_DIR` ignores it.

```bash
DRAUGR_MOUNTS="/mnt/c/Code/claude-plugins:ro"
DRAUGR_ENV="CLAUDE_CODE_PLUGIN_SEED_DIR=/c/Code/claude-plugins/seed"
```

The third belongs in the same file, but not under the generic key. Something has to point Claude
Code at the settings file, and the way to do that is `--settings`, which is **Claude Code's flag** —
so it goes in the per-agent key rather than in `DRAUGR_AGENT_ARGS`:

```bash
DRAUGR_AGENT_ARGS_CLAUDE="--settings /c/Code/claude-plugins/settings.json"
```

`DRAUGR_AGENT_ARGS` carries the agent's own arguments, so a machine-wide value there is handed to
every codex, gemini or copilot mound as well, at every attach.
[`DRAUGR_AGENT_ARGS_<AGENT>`](CONFIG.md#draugr_agent_args_agent) is chosen after the whole cascade
has run, when `DRAUGR_AGENT` is finally known, and applies only to the agent it names. That keeps
all three lines machine-wide, which is what option 4 is for.

> **A possible simplification, unverified.** `claude --help` has no environment variable for
> `--settings`, but the 2.1.246 binary carries `CLAUDE_CODE_MANAGED_SETTINGS_PATH`. That would ride
> in `DRAUGR_ENV` beside the seed path and drop the third line entirely.
>
> It is a lead rather than a recipe. The CLI subcommands read neither the seed nor a settings file,
> so nothing short of a session that starts can test it, and pointing the variable at malformed JSON
> produced no complaint either way. It is also not a like-for-like swap: *managed* settings are the
> highest precedence tier, above a project's own `.claude/settings.json`, where `--settings` sits
> below it. Worth measuring before trusting.

Things worth knowing about the lines above:

- The `:ro` is the point of the whole exercise. Without it a mound can rewrite the hook scripts that
  every other mound runs, and you are back to the objection against option 5.
- **Only the mount is a creation-time setting.** `DRAUGR_ENV` and `DRAUGR_AGENT_ARGS` are applied
  when you attach, so once the mount exists, changing either of the other two costs nothing but the
  next `dr-go`.
- **`DRAUGR_ENV` reaches the agent's session, not `dr-shell`.** Draugr writes those variables into
  the rcfile it builds for the agent at attach time; `dr-shell` runs its command over plain `ssh`
  with no rcfile at all, so nothing you run there inherits the seed path.
- **The seed is read at session startup, and nowhere else.** This is the trap worth knowing about,
  because it makes the obvious check lie. `claude plugin marketplace list` and `claude plugin list`
  do **not** load the seed — measured: with the variable set explicitly and the mount verified, both
  reported nothing at all.

  ```bash
  # both of these say "No marketplaces configured", with everything working
  dr-shell -- claude plugin marketplace list
  dr-shell -- env CLAUDE_CODE_PLUGIN_SEED_DIR=/c/Code/claude-plugins/seed claude plugin marketplace list
  ```

  Start one session and the picture changes: startup registers the seed's marketplaces into the
  mound's own configuration, and from then on the same `dr-shell` command lists all of them, with no
  variable needed. So the authority is a `dr-go` session and `/plugin`; a shell can only tell you
  what a previous session already wrote down.
- `DRAUGR_ENV` splits entries on spaces, so the path must not contain any — and `dr-go` refuses a
  malformed entry rather than letting the agent ignore it silently. See
  [`DRAUGR_ENV`](CONFIG.md#draugr_env).
- **A repo that sets `DRAUGR_ENV` silently takes the seed away.** This is the hole in the
  "one place, every mound" claim, and it is worth knowing before it costs you an afternoon.
  `DRAUGR_ENV` is a single string, and the layers *replace* rather than merge, so a project that
  sets it for its own reasons drops the machine-wide value entirely:

  ```text
  $ dr-config DRAUGR_ENV
  CLAUDE_CODE_DISABLE_1M_CONTEXT=1 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=25
  ```

  Measured, in a repo whose `.draugr.conf` capped the compaction point for a local model:
  `CLAUDE_CODE_PLUGIN_SEED_DIR` was simply gone, and that mound would never have seen the seed
  however correct the mount was. `DRAUGR_MOUNTS` has the same shape but survived, because that
  project happened not to set it.

  The layers are sourced in order, in one shell, so a project config can add to the value instead of
  replacing it — which is what a project that needs its own variables should do:

  ```bash
  DRAUGR_ENV="${DRAUGR_ENV:+$DRAUGR_ENV }CLAUDE_CODE_DISABLE_1M_CONTEXT=1"
  ```

  `dr-config DRAUGR_ENV`, run in the repo you are about to work in, is the check that catches this.
- `DRAUGR_AGENT_ARGS` **replaces** rather than extends. If you already use it, append rather than
  overwrite: `DRAUGR_AGENT_ARGS="--continue --settings /c/Code/claude-plugins/settings.json"`.

Mounts are fixed when a mound is built, so existing mounds need `dr-up --recreate` once. After that
first time they do not: the mount and the environment variable stay, and the seed is re-read at
every start.

> **`--recreate` destroys the mound**, and a mound holds three things that exist nowhere else:
> commits the agent made and you never fetched, the memory it wrote, and any host opened by hand
> with `dr-policy --allow`. It refuses over each of them and names the remedy — `dr-sync`,
> `dr-mem export`, `dr-kit adopt` — so on a mound you have been working in, expect to be stopped
> once and to deal with it. `dr-up --recreate --force` proceeds anyway and throws all three away.
>
> On a mound built for this and nothing else, none of it applies.

### Adding the next plugin

This assumes **the mound you built the seed in, with `/home/agent/seed` still in it**. That is the
easy case, and it is also the one that expires: `/home/agent` is rootfs, so `dr-rm` takes the build
directory with it, and by the time you want a fourth plugin the mound has often been through one.

```bash
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin marketplace add <owner>/<repo>
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin install <plugin>@<marketplace> -y
dr-shell -- ls -la /home/agent/seed
dr-cp -L --raw /home/agent/seed /mnt/c/Code/claude-plugins
```

…then one line in `settings.json`. **No change to your Draugr configuration, and no `--recreate`.**
Every mound picks it up the next time it starts. That is the difference between option 4 and option
3, and it is the whole reason to prefer it.

### Adding one from a fresh mound

Run those same commands in a mound that never held the earlier plugins and the last of them does not
add to your seed. `sbx cp` extracts a tar over the destination, so **directories merge and same-named
files are replaced** — measured, by copying two unrelated trees into one host directory in turn:

| in the seed afterwards | |
|---|---|
| `marketplaces/<new>`, `cache/<new>` | added |
| `marketplaces/<old>`, `cache/<old>` | **kept** — the names differ, so nothing overwrites them |
| `known_marketplaces.json` | **replaced**, naming the new marketplace and nothing else |

Which is the worst of the three possible outcomes. The old plugins' files are all still there, so the
seed looks right and its size says nothing is wrong, and nothing registers them any more: every mound
loses them at its next start, with no error anywhere.

So put the seed back before building on it. `dr-cp --to` lands it at exactly the build path, owned by
the agent, and the plugin CLI then reads it as the library it already is:

```bash
dr-shell -- rm -rf /home/agent/seed
dr-cp --to /mnt/c/Code/claude-plugins/seed /home/agent    # -> /home/agent/seed

# the check that it took: your existing marketplaces, before adding anything
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin marketplace list
```

Then the commands above, unchanged. `marketplace add` merges into whatever library it finds, so
`known_marketplaces.json` comes back out naming all of them — measured, adding a fourth marketplace
to a rehydrated seed of three.

The `rm -rf` is there for the same reason as everything else on this page: a half-built
`/home/agent/seed` left over from an abandoned attempt would survive the copy and end up in the seed.

### Updating a plugin

Nothing updates itself, so this is the same shape as adding: put the seed back into a mound as a
writable build directory, work on it there, and swap the result in.

```bash
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin marketplace update                       # a name updates just that one
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin update <plugin>@<marketplace> -y
```

`marketplace update` refreshes the catalogues, `plugin update` acts on what they now offer, and both
need `github.com`, which sbx allows machine-wide. Measured against a current seed:

```text
Updating marketplaces...✔ Successfully updated 3 marketplaces
Checking for updates for plugin "superpowers@superpowers-marketplace" at user scope…
✔ superpowers is already at the latest version (6.3.0).
```

`-y` is required for the same reason as at install time, and here it accepts something specific: a
marketplace-declared install command that has *changed* since you last agreed to it. Reading what it
says before passing `-y` is the whole of your review.

**Then swap the seed rather than copying over it.** The cache is keyed by version —

```text
cache/superpowers-marketplace/superpowers/6.3.0
```

— so versions are separate directories, and `dr-cp` merges directories. Copy an updated build
directory onto your existing seed and the old version stays beside the new one, once per update, for
ever. That holds however tidy the build directory is: the merge is a property of the copy, not of
what you copied.

Nothing will tell you. Measured, by putting a stale `0.9.0` beside a live `1.0.0` in a build
directory: `claude plugin update`, `claude plugin prune` and `claude plugin list` all left it exactly
where it was, and `list` named only `1.0.0`. So the superseded copy is invisible to every command
that might have mentioned it, and still mounted into every mound.

[Rebuilding the seed](#rebuilding-the-seed-and-the-swap) is the swap.

### Removing a plugin

Three things go, and only the first is obvious.

```bash
# 1. the plugin
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin uninstall <plugin>@<marketplace> -y

# 2. its marketplace, if nothing else came from it
dr-shell -- env CLAUDE_CODE_PLUGIN_CACHE_DIR=/home/agent/seed \
    claude plugin marketplace remove <marketplace>
```

3. The line in `settings.json`. `enabledPlugins` left naming a plugin no mound can find is not fatal,
but it is a switch wired to nothing, and the next person to read the file will believe it.

Measured: `uninstall` deletes the version directory and its entry in `installed_plugins.json`;
`marketplace remove` deletes the marketplace clone and its entry in `known_marketplaces.json`. A seed
of three went from 37 MB to 32 MB. What it leaves is the empty parent chain —
`cache/<marketplace>/<plugin>/`, with no version inside — which costs nothing and is worth knowing,
because a `find` in your seed still names a plugin you removed.

**And then swap, not copy.** This is the one place where a mistake is completely silent. `dr-cp`
merges, so copying a build directory with the plugin *gone* onto a seed that still has it removes
nothing: `known_marketplaces.json` is a top-level file and is replaced, so the marketplace really
does deregister, while every byte of the plugin stays on disk and stays mounted read-only into every
mound. The seed looks smaller in the listing and is not smaller at all.

Inside a mound, `/plugin disable` is the lighter answer. It stops a plugin loading without touching
the seed, and it is the right one when you might want it back.

### Rebuilding the seed, and the swap

Updating, removing and rebuilding from nothing all finish the same way, and it is never a copy onto
the seed you have. Copy the build directory somewhere else, then swap:

```bash
dr-cp -L --raw /home/agent/seed /mnt/c/Code/claude-plugins-new
mv /mnt/c/Code/claude-plugins/seed /mnt/c/Code/claude-plugins/seed.old
mv /mnt/c/Code/claude-plugins-new/seed /mnt/c/Code/claude-plugins/seed
```

Copying straight onto the old seed is the merge in its third form: the previous copy of every plugin
stays underneath the new one, and a plugin you deliberately dropped is still there and still enabled.
The swap also leaves you something to put back when a rebuild goes wrong, which deleting the seed
first does not — and `seed.old` is worth keeping until one session has proved the new one.

A mound reads the seed at startup, so replacing it under a running session is not a problem you have
to solve — only one to be aware of.

### What the seed will not do

- **Auto-update is off**, by design: a `git pull` would fail against a read-only mount. Updating is
  a deliberate act — see [updating a plugin](#updating-a-plugin). That is the right default inside a
  sandbox, where a plugin silently updating itself is a change to executable code that nobody
  reviewed.
- **`/plugin marketplace remove` and `update` fail inside the mound**, with a message pointing at
  the seed. Expected, not broken.
- **Seed entries win.** A marketplace in the seed overwrites a matching entry in the mound's own
  configuration at every startup. To turn one off, `/plugin disable` it rather than trying to remove
  the marketplace.
- **`dr-scan` does not look inside extra mounts.** It scans the repository you are in. The seed is
  yours to keep clean, which is the same deal as any other `DRAUGR_MOUNTS` entry.

### What a plugin still needs from the mound

The seed carries a plugin's code. There are two things it deliberately does not carry, and both show
up the same way: a plugin that installs cleanly, loads without complaint, and does nothing useful.

**State, including credentials.** A plugin's private directory is `plugins/data/<plugin-id>/`, and it
is created in the MOUND rather than in the seed — measured, in a mound that had run two of them:

```text
/home/agent/.claude/plugins/data/simple-english-simple-english
/home/agent/.claude/plugins/data/superpowers-superpowers-marketplace
```

That is rootfs, so it dies with `dr-rm` along with everything else the agent had, and a plugin that
authenticates will authenticate again in the next mound. That is the trade working rather than
failing: `data/` is where a plugin keeps `.credentials.json`, and the
[warning against copying it into the seed](#building-it-inside-a-mound) is the only thing standing
between one mound's token and every other mound on the machine. A plugin that needs a durable secret
should get it from `DRAUGR_ENV` or an `sbx` secret, where it is something you granted rather than
something a copy carried.

**Network, at session time rather than install time.** The machine-wide sbx rules that let the build
reach `github.com` say nothing about wherever a plugin's MCP server or hook phones once it is
running. Default-deny is real, and the refusal does not look like one.

It arrives as **HTTP 403 from the proxy**, not as a connection failure — measured, by reaching for
two hosts from inside a mound:

```text
$ curl -o /dev/null -w '%{http_code}\n' https://httpbin.org/get
403
```

That is the whole reason a blocked plugin wastes an afternoon. A client that gets a 403 reports an
*authentication* problem, and sends you to check credentials that were never wrong. `dr-policy` is
the thing that tells you the truth, and it did:

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

That loop belongs to the repository rather than to the seed, and deliberately so. The seed is
machine-wide and invisible; a hole in a network policy is exactly the kind of decision that should be
committed somewhere a reviewer will see it.

### Layering more than one seed

`CLAUDE_CODE_PLUGIN_SEED_DIR` accepts several paths separated by `:`, searched in order, first match
winning per marketplace. A team seed mounted read-only alongside a personal one is therefore
possible without merging the two:

```bash
DRAUGR_MOUNTS="/mnt/c/Code/claude-plugins:ro /mnt/c/Code/team-plugins:ro"
DRAUGR_ENV="CLAUDE_CODE_PLUGIN_SEED_DIR=/c/Code/claude-plugins/seed:/c/Code/team-plugins/seed"
```

**Check this once** if you rely on it: the separator is `:` on Unix and `;` on Windows, and the
agent inside the mound is on Linux, so `:` is the one that applies — even though you are configuring
it from WSL against paths that started out on a Windows drive.

### Follow-up: `--plugin-dir` pointed straight at the seed

Option 4 still costs one `claude plugin install` per mound, and that install is a *copy*: the plugin
content is already mounted, and installing writes it again into the mound's own library. Option 3's
`--plugin-dir` has neither cost — it loads a plugin from a directory, with no marketplace and no
install step. So the obvious question is whether it can be aimed at the read-only seed instead.

**It can.** Measured, in a session started against the mounted seed with nothing installed for it:

```bash
DRAUGR_AGENT_ARGS_CLAUDE="--plugin-dir /c/Code/claude-plugins/seed/cache/claude-code-plugins/commit-commands/1.0.0"
```

```text
$ claude -p 'List every slash command whose name contains the word commit. Names only.'
- commit-commands:commit-push-pr
- commit-commands:commit
```

The plugin loaded off a mount that refuses writes — `touch` there really does answer `Read-only file
system` — registered its commands under its own name, and nothing complained. No install, nothing
copied into the mound, and it survives `dr-rm` for the same reason the seed does.

**Hooks work too**, which is the part that could easily have gone the other way. Measured with a
throwaway plugin placed in the read-only mount, whose `SessionStart` hook was written to report both
facts about itself:

```text
PROBE_HOOK_FIRED root=/c/Code/claude-plugins/probe-plugin write=READONLY
```

The hook ran, `CLAUDE_PLUGIN_ROOT` resolved to the mount, its `touch` into its own directory was
refused, and the session carried on and used the context the hook injected. Claude Code does not
abort over a plugin that cannot write to itself.

Two things that look like obstacles are not. `superpowers` is safe by inspection — its one
`SessionStart` hook `cat`s a skill file and prints JSON — and its `package.json` is not the problem
it appears to be, because the mound's own *installed* copy carries no `node_modules` either.
Installing creates none, so `--plugin-dir` is skipping nothing.

Why it is a follow-up rather than the recommendation:

- **The path contains the version.** `.../commit-commands/1.0.0` is what you have to write, so every
  update means editing your Draugr configuration — the exact cost option 4 exists to remove.
- **One flag per plugin.** Six plugins is six `--plugin-dir` flags in one string, which is where
  option 3 was already weakest.
- **It is invisible to every command that could confirm it.** `--plugin-dir` is session-only and no
  subcommand takes it — `claude plugin list --plugin-dir …` answers `error: unknown option
  '--plugin-dir'`. `claude plugin list` will never mention it. Starting a session and asking is the
  only check there is, which is the same trap as
  [the seed being read at startup and nowhere else](#the-configuration), one level worse.
- **There is no switch.** It bypasses `enabledPlugins` entirely, so a plugin named this way is on in
  every mound, and `/plugin disable` has nothing to act on.
- **`--bare` turns it off**, along with hooks, `--settings` and `--agents`.
- **A hook that must write where it lives will fail**, quietly, in the same shape as everything else
  on this page. Measured above: the write is refused and nothing says so but the hook itself.

Worth having for a plugin you never update, or for trying one before committing it to the seed. Not
a replacement for option 4.

## Checks worth running once

Most of this page was measured rather than read, and the banner at the top says against what. These
are the checks that catch a seed which is configured correctly and still not working:

| | |
|---|---|
| `/plugin`, inside a `dr-go` session | the real answer: installed **and** enabled, which are two questions |
| `dr-shell -- claude plugin marketplace list` | **after** one session has run — before that it says nothing, whatever is mounted |
| `dr-shell -- ls /c/Code/claude-plugins/seed` | the mount arrived, at the mirrored path |
| `dr-shell -- touch /c/Code/claude-plugins/seed/x` | fails with `Read-only file system` — the `:ro` is real |
| `dr-shell -- grep claude-plugins /proc/mounts` | `virtiofs ro,relatime` — kernel-enforced, not conventional |
| `dr-policy --check github.com` | the build step can reach the marketplace |
| a session with `--plugin-dir` at a seed path | the only way to see one: no subcommand accepts the flag |
| `dr-policy --denied`, after a session | what a plugin tried to reach at RUN time and was refused |
| `dr-shell -- python3 --version` | interpreters the hooks in your plugins need |

That last one bites in a way that looks like nothing at all: a hook whose interpreter is missing
fails on every edit, quietly, and the plugin appears to do nothing.
