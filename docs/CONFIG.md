# Configuration reference

Each `DRAUGR_*` key, what it does, and what happens if you get it wrong.

If a key exists in `lib/common.sh` but not in this file, `tests/docs.bats` fails. Thus this list
cannot silently fall behind the code. But its *accuracy* can fall behind. If a statement here does
not agree with a command, the command is right, and this file has a bug. Please report it.

## Where settings come from

Four files, all plain shell (`KEY=value`, `#` comments), sourced in order:

| File | Scope | Commit it? |
|---|---|---|
| `~/.config/draugr/config` | each project on this machine | n/a |
| `<repo>/.draugr.conf` | this project, shared with the team | **yes** |
| `<repo>/.draugr.local.conf` | this project, only you | no: `dr-init` adds it to .gitignore |

The order, from lowest to highest:

```
built-in defaults → user config → project config → project-local → DRAUGR_* env → flags
```

`dr-config` prints the merged result, with the origin of each value. `dr-config --changed` shows
only the values that are different from the defaults. Use it before you trust that a statement on
this page applies to you.

> **Draugr executes a project configuration. It does not parse it.** To source a file from a cloned
> repository runs its code. When you first accept a project configuration, Draugr records its hash.
> It refuses to source a configuration that it does not know. If you edit your own, it asks once
> again. Run `dr-trust` to accept.

**A refused configuration is the failure that looks like nothing happened.** Trust is for the
*content*. Thus an edit of a file that you accepted removes the trust. From then on, the table
shows built-in defaults, and that looks the same as a file that set nothing. Thus `dr-config` says
so two times: once at the line, and again in red at the bottom, which is the part that you read.

```
DRAUGR_STOP_ON_EXIT        false                              built-in default

dr-config: 1 configuration file was NOT sourced, because it is not trusted:
  /mnt/c/src/myproject/.draugr.conf
  The table above shows no value from these files. If a setting is
  not what you wrote, that is why. Read it, then run:  dr-trust
```

It is loud, but not fatal. Nothing failed, so the exit status stays `0`. `dr-config --files` gives
the same answer as a table. `dr-trust` with no arguments offers each configuration and hook that
you did not accept, all at once.

---

## The agent and the mound

### `DRAUGR_AGENT`
Default `claude`. One of `claude`, `codex`, `copilot`, `cursor`, `docker-agent`, `droid`, `gemini`,
`kiro`, `opencode`, `shell`. Draugr passes it to `sbx create` as the agent name.

All except **memory** works the same for each agent: attach, Ctrl+Z, the clone, kits, `dr-sync`,
`dr-send`, `dr-data`. Each agent has its own private memory layout. Thus Draugr keeps one file for
each agent in `lib/agents/`, and only claims to know the agents that it measured:

| | memory | `dr-mem` |
|---|---|---|
| `claude` | `~/.claude/projects/<PATH-KEY>/memory/`, for each project | full |
| `codex` | `$CODEX_HOME/memories/` and its SQLite state, **not** for each project, **off by default** | full |
| other agents | not measured | refuses, and says so |

An agent with no Draugr module still works. `dr-mem` refuses, and does not copy a directory into a
place that the agent never reads. To turn off the automatic half, set `DRAUGR_MEM_SYNC=off`.

If you change this on an existing repository, `dr-up` reports creation drift. The agent is fixed in
the sandbox spec, so the change needs `dr-up --recreate`. One mound holds one agent. For a Claude
mound and a Codex mound on the same project at the same time, give them separate names and
separate remotes in `.draugr.local.conf`:

```bash
DRAUGR_SANDBOX=draugr-myproject-codex
DRAUGR_REMOTE=draugr-codex
```

`sbx` holds the credentials on the host, not inside the mound. Its proxy authenticates for the
agent. Thus nothing is fixed at creation, and a later sign-in needs no rebuild. Use
`sbx secret set -g anthropic --oauth` for Claude, and `sbx secret set -g openai --oauth` for Codex.
`dr-doctor` reports a missing one.

### `DRAUGR_AGENT_ARGS`
Default empty. Arguments that Draugr gives to the agent after `--` on each `dr-go`. Use it for the
flags that you otherwise type in each session:

```bash
DRAUGR_AGENT_ARGS="--continue"        # dr-go resumes by default
```

The command line **replaces** these, and does not add to them. That follows the same order as all
other values. It is also the only way to drop a configured argument for one run:

| | |
|---|---|
| `dr-go --bare` | pass the agent nothing |
| `dr-go -- --model opus` | pass these instead |

These are the own flags of the agent, passed with no interpretation. Thus the agent sets the
spelling, not Draugr. "Continue from last time" is `--continue` for Claude Code, and
`resume --last` for Codex. The Codex form is a subcommand, not a flag, but it works here too:

```bash
DRAUGR_AGENT_ARGS="resume --last"     # dr-go resumes the last Codex thread
```

Neither means anything to `shell`.

> ### Codex on a ChatGPT plan usually needs a model named here
>
> `sbx` writes only `model_provider = "sandboxd"` into the `config.toml` of the mound, and no
> `model`. Thus the Codex of the image uses its own built-in default. On a ChatGPT-plan account,
> your plan often does not include that default, and **each prompt fails** with:
>
> ```text
> ERROR: {"detail":"The 'gpt-5.6-sol' model is not supported when using Codex with a ChatGPT account."}
> ```
>
> That is not a credentials problem, and a sign-in does not fix it. `sbx secret ls` shows
> `openai (oauth configured)` all the time. Name a model that your account has:
>
> ```bash
> DRAUGR_AGENT_ARGS="--model gpt-5.6-terra"
> ```
>
> Both `codex` and `codex exec` accept `-m/--model`. We tested this on the 0.146.0 in the image of
> `sbx`. To see the models of your account, look at the model cache of a Codex that you logged in
> to on the host:
>
> ```bash
> jq -r '.. | .id? // empty' ~/.codex/models_cache.json | sort -u
> ```

### `DRAUGR_AGENT_ARGS_<AGENT>`
Default **unset**. These are the only keys with no built-in value, on purpose. There is one for
each agent. When that agent is the configured one, it wins over `DRAUGR_AGENT_ARGS`:

| | |
|---|---|
| `DRAUGR_AGENT_ARGS_CLAUDE` | `DRAUGR_AGENT_ARGS_CODEX` |
| `DRAUGR_AGENT_ARGS_COPILOT` | `DRAUGR_AGENT_ARGS_CURSOR` |
| `DRAUGR_AGENT_ARGS_DROID` | `DRAUGR_AGENT_ARGS_GEMINI` |
| `DRAUGR_AGENT_ARGS_KIRO` | `DRAUGR_AGENT_ARGS_OPENCODE` |
| `DRAUGR_AGENT_ARGS_SHELL` | `DRAUGR_AGENT_ARGS_DOCKER_AGENT` |

The name is the agent in uppercase, with `-` changed to `_`. `docker-agent` is a legal agent name,
but a hyphen is not legal in a variable name.

These exist because `DRAUGR_AGENT_ARGS` holds the flags of the *agent*. Thus a machine value is
wrong when you run a second agent. `--settings` is the spelling of Claude Code, and a codex mound
that gets it fails at each attach. Thus put the generic key in a project, and this one in
`~/.config/draugr/config`:

```bash
DRAUGR_AGENT_ARGS_CLAUDE="--continue"
DRAUGR_AGENT_ARGS_CODEX="resume --last"
```

**A shell conditional cannot do this job.** That is why these are keys, and not advice. Draugr
sources `~/.config/draugr/config` *before* the project configuration, and the project usually sets
`DRAUGR_AGENT`. Thus while the machine layer runs, `$DRAUGR_AGENT` still holds the default, whatever
the project sets later.

It **replaces** the generic key, and does not add to it. `.draugr/kit.<agent>/` follows the same
rule against `.draugr/kit/`. And unset is not the same as empty. If you leave one out, Draugr uses
`DRAUGR_AGENT_ARGS`. If you set it to `""`, that means "nothing for this agent", and wins over a
generic value. `dr-config` shows which one won:

```text
DRAUGR_AGENT_ARGS   --continue   ~/.config/draugr/config (via DRAUGR_AGENT_ARGS_CLAUDE)
```
### `DRAUGR_ATTACH`
Default `ssh`. How `dr-go` and `dr-shell` get a terminal inside the mound. The other value is `sbx`.

**Ctrl+Z works only with `ssh`**, and that is the full reason for this key.

| | |
|---|---|
| `ssh` | Ctrl+Z suspends the agent, and gives you a shell **in the mound**. `fg` goes back |
| `sbx` | Ctrl+Z kills the session with `ERROR: inspect exec: context deadline exceeded` |

`sbx run` and `sbx exec` reach the sandbox through `sbx.exe`, a *Windows* binary that WSL runs
through interop. Your terminal belongs to WSL, but the process that reads it does not. Thus Ctrl+Z
suspends the relay, and nothing inside the sandbox. The keystroke never arrives, the daemon stops
hearing from its client, and a few seconds later the full session dies. Measured with
`sbx 0.37.1`, in both modes.

ssh has no such gap. It is a native Linux client, with a real pty at the far end, and job control
happens inside the sandbox, where it belongs. `dr-sync` and `dr-data` already use it as their
transport. Thus the `*.sbx` block that `dr-setup` writes is the only setup that either mode needs.

Over ssh, the agent runs as a job of an interactive bash, started from `PROMPT_COMMAND`. Draugr
writes the **rcfile** of that shell. That is the startup script named by `bash --rcfile`, in the
place of the usual `~/.bashrc`. Draugr sends it into the mound at attach. It also carries all else
that the agent needs in its environment. A start of the agent from the body of that file **hangs**,
because job control is not on while bash runs its startup files. When the agent exits normally,
the session ends, and `dr-go` returns its status, exactly as `sbx run` did. Only Ctrl+Z is
different, by design:

```text
Ctrl+Z   →  $? is 148 (128 + SIGTSTP)  →  stay, and you have the mound's shell
exit     →  the agent's own status      →  leave
```

Set `DRAUGR_ATTACH=sbx` if a later `sbx` changes its ssh proxy, or to compare behavior. You lose
Ctrl+Z, and `dr-shell --root` uses `-u root` again, not `sudo`.

### `DRAUGR_SANDBOX`
Default `draugr-<repo folder name>`. `sbx` rejects underscores and most punctuation. Thus Draugr
keeps only letters, digits, `.`, `+` and `-`: `my_project` becomes `draugr-my-project`.

Set it explicitly to connect Draugr to a sandbox that you created by hand.

### `DRAUGR_MEMORY`
Default empty, which means the default of `sbx`: 50% of host RAM, with a limit of 32 GiB. Binary
units: `8g`, `1024m`.

### `DRAUGR_CPUS`
Default empty, which means all host CPUs.

### `DRAUGR_CLONE`
Default `true`. The agent works on a private clone inside the mound. Your working tree is mounted
**read-only** at `/run/sandbox/source`.

`false` bind-mounts your real working tree read-write, and Draugr exists to prevent that. Each
time, `dr-go` asks you to confirm, and no configuration key can stop that prompt. Refer to
[SECURITY.md](SECURITY.md).

### `DRAUGR_TEMPLATE`
Default empty. A container image to use in place of the default of the agent.

---

## What the agent may reach

### `DRAUGR_KIT`
Default `.draugr/kit`. A **list, separated by spaces**, of directories, ZIPs, git refs or OCI
images that hold [`sbx` kits](https://docs.docker.com/ai/sandboxes/customize/kits/).

**Network rules and setup commands are not Draugr keys.** They belong to the kit. That is a
declarative format from Docker, which already does the job, and also works with plain
`sbx run --kit`. `dr-init` writes a starter `spec.yaml`. Commit it.

It is a list, because `sbx` **merges** the kits, and does not select one. A test showed that two
mixins on one sandbox gave both their install commands and both their network rules. Thus a shared
kit *adds* to the kit of the project:

```bash
DRAUGR_KIT=".draugr/kit lua"     # this project's kit, plus the library's "lua"
```

Each entry resolves in this order: an absolute path, a directory in the repo, a named kit in
`DRAUGR_KIT_STORE`, and then an entry with `:` or `@`, passed through as an OCI or git reference.
Draugr searches the repo before the library, so a local directory of the same name always wins.

Draugr tries each of those two times: first with `.<agent>` added, then plain. Thus with
`DRAUGR_AGENT=codex`, `.draugr/kit.codex` wins over `.draugr/kit`, and a library kit `lua.codex`
wins over `lua`. Most kits do not need this. Network rules, install commands and ports belong to
the project, not to the agent that runs in it. An OCI or git reference gets no suffix. Draugr must
not make up a tag in the registry of another party.

A kit **can** pin itself with `requires: agent: claude`. `sbx` then refuses to combine it with
other agents:

```text
ERROR: request failed: 400 Bad Request: kit_artifacts: compose:
kit "myproject" requires base agent "claude" but was composed with "codex"
```

`sbx kit validate` accepts such a kit, because the mismatch exists only at creation. Thus Draugr
reads the field itself, and refuses first, in `dr-up`, `dr-kit validate` and `dr-doctor`. `dr-init`
does not write the field. With the agent of today fixed in a committed file, a try of a different
agent needs an edit, not a configuration value.

When the list changed after the build of the mound, `dr-up` warns, because an apply recreates the
container. That must be a decision, not a side effect. The **method** depends on the change,
because `sbx` can only add a kit to a running mound *(measured)*. `dr-kit apply` adds kits at the
end of the list in place, and keeps the clone. A kit that you edited, removed or moved needs
`dr-up --recreate`. The reason is not caution. `sbx kit add` refuses a kit that the sandbox already
has. When it adds a new one, the old rules stay in force beside the new ones. Thus an edit that
narrows, applied that way, narrows nothing. `dr-kit apply` finds your case, and says so. A remote
reference gives only its *name* to that comparison. Draugr cannot see a tag that moved, and
`dr-kit drift` says so, and does not claim that all is clean.

### `DRAUGR_KIT_STORE`
Default `~/.config/draugr/kits`. Your library of named kits, shared between repositories. "The Lua
toolchain" is a fact about you, not about one repo.

| | |
|---|---|
| `dr-kit save <name>` | copy the own kit of this project into the library |
| `dr-kit list` | the contents, with each `displayName` |
| `dr-kit adopt` | write hosts opened with `dr-policy --allow` into the kit of this project |

`adopt` is the end of the loop to build your own kit, in
[WORKFLOW.md](WORKFLOW.md#letting-the-agent-build-the-kit). It reads back the hosts that were
opened for the mound. It skips the hosts that the kit already declares, and writes the rest into
`caps.network.allow`. Thus you need to remember nothing while the loop runs. It edits only that one
block. If it does not know the shape of a kit, it reports it, and does not change it.

`save` copies, and does not make a symlink, so an edit on one side never silently changes the
other. But an edit of the library copy puts each repo that uses it into drift, until
`dr-up --recreate` rebuilds it. That is the purpose of drift detection, not a fault in it. To share
between *machines*, `sbx kit pack` and `sbx kit push` already work, and an OCI reference is a valid
`DRAUGR_KIT` entry.

### `DRAUGR_PORTS`
Default empty. `HOST:SANDBOX` pairs, separated by spaces, published to Windows loopback:

```bash
DRAUGR_PORTS="5173:5173 8080:8080"
```

A kit can also declare `publishedPorts`, but it **cannot name the host port**. `spec.PublishedPort`
has no such field. Thus `sbx` selects a random port, which changes on each recreate. Set each port
that you want at a fixed URL here, for example a dev server in a browser tab. `dr-ports` does the
same during a session, with no rebuild.

They are on the **Windows** loopback, not that of WSL. Thus open them in a Windows browser. `curl`
from inside WSL reaches the own loopback of the WSL VM, and does not connect.

### `DRAUGR_HOST_PORTS`
Default empty. **Port numbers** on this machine, separated by spaces, that the mound can reach:

```bash
DRAUGR_HOST_PORTS="11434"        # a local Ollama on the host's GPU, say
```

This is the opposite of `DRAUGR_PORTS`. That key publishes a port *out* of the mound, so that a
Windows browser can reach in. This key opens a port *into* your machine, so that the agent can call
out. `dr-up` applies it on each start, and `dr-hostport` does the same during a session. That is
the same pair as `DRAUGR_PORTS` and `dr-ports`.

You name only the port. Draugr resolves the address at each apply, because WSL gets a new address at
each boot, and you cannot set it. WSL 2.6.1 has no `natNetwork` value. A rule with a literal IP is
correct until the next reboot. Then it fails **closed and silently**: the interception layer of the
sandbox accepts the connection, and drops it, with no error to read. Draugr removes the rules for
old addresses of this machine when it finds them.

`dr-up` also writes the address into the mound, at `~/.draugr/host.env`:

```
DRAUGR_HOST_ADDR=172.19.192.26
DRAUGR_HOST_PORTS="11435"
```

The mound cannot find it by itself. There is no `ip` command in the image, and
`host.docker.internal` resolves to the own gateway of the mound, not to your machine. **Nothing
sources that file for you.** Draugr does not touch the files of the agent inside the mound. Thus a
project that needs the value reads it, in its own run script or a kit startup command:

```sh
. "$HOME/.draugr/host.env"
OLLAMA_URL="http://$DRAUGR_HOST_ADDR:11435"
```

That is the full reason for the file, in place of a committed value. The address changes after
each reboot. Thus each place where you write it down becomes wrong.

The service must listen on `0.0.0.0`, not `127.0.0.1`. Inside the mound, `127.0.0.1` is the mound.
If `dr-hostport` can see that mistake, it warns.

> This is a hole from the sandbox to your machine, and the more serious of the two directions. On
> the other side is a process outside the mound. The agent can use all that it can reach there. In
> the `.draugr.conf` of a project, it applies only after you accept that file with `dr-trust`. That
> is where you give consent.
### `DRAUGR_MOUNTS`
Default empty. Extra host directories, separated by spaces, each `PATH[:ro]`:

```bash
DRAUGR_MOUNTS="/mnt/c/Docs/api:ro"
```

Draugr translates the paths to the Windows spelling that `sbx` needs. They must be on a Windows
drive. **A sandbox can read each byte of each mount.** Never mount `~/.claude`, which holds your
agent credentials.

**A mount arrives at the mirrored path**, by the same rule as the repo itself. `C:\Code\TabuLua`
shows at `/c/Code/TabuLua`. Thus a sibling project stays a sibling, and a relative path between the
two works unchanged:

```bash
# in C:\Code\MyGame/.draugr.conf
DRAUGR_MOUNTS="/mnt/c/Code/TabuLua:ro"
```

```text
/c/Code/MyGame                ← the clone, writable
/c/Code/TabuLua               ← the mount, read-only
```

`../TabuLua` resolves from inside the clone, with no rewrite. Measured: the agent reads it,
`echo >>` and `touch` both fail with `:ro`, and the clone stays writable.

**The mount is your live working tree, not a clone.** The mound sees uncommitted edits on the host
at once: no commit, no push, no `dr-sync`. That is the difference from a dependency in a kit, which
stays at the version that you last published.

Two results follow. The agent sees your work in progress, also a half-finished refactor. And
`dr-scan` does **not** look inside extra mounts, because it scans only the current repository. Thus
the agent can read a file that looks like a credential in a mounted directory, and nothing reports
it.

> **Mounts become fixed when Draugr builds the mound.** A new one in `.draugr.conf` has no effect
> on an existing sandbox. `dr-up` says so, and names the key. `dr-up --recreate` rebuilds.

---

## Running the agent on a local model

### `DRAUGR_MODEL`
Default empty. The name of a model for **the agent itself**, in place of the cloud of its vendor:

```bash
DRAUGR_MODEL="qwen3.8:27b"
```

Empty, the default, means that the agent reaches its own service as before, and nothing else in
this section applies.

This is not the same feature as [`DRAUGR_HOST_PORTS`](#draugr_host_ports). They are easy to mix up,
because they use the same port. That key lets **the code that you work on** call a local service.
This key changes what **the agent** is. A project that uses an LLM, and an agent that runs on one,
are different things. It is normal to want both at the same time.

Draugr does not make sure that the name exists. The endpoint gets it at the first prompt, and an
unknown name fails there. Read the spelling from `ollama list`. For Ollama, `qwen3.8:27b` and
`qwen3.8` are different names, and only the first is installed.

> **Alone, this does not keep your code here.** By design, it changes where the agent sends your
> code. It does not change what the mound can reach. The default policy of `sbx` allows the AI
> service endpoints, with ~190 other hosts. To close that, you also need kit `deny` rules.
> [SECURITY.md](SECURITY.md#running-the-agent-on-a-local-model) gives the benefit and the cost.

### `DRAUGR_MODEL_URL`
Default `11435`. Where that model is served, in one of two spellings:

| Value | Meaning |
|---|---|
| `11435` | a port on **this machine**, whose address Draugr resolves at each attach |
| `https://llm.corp.example` | a fixed endpoint, used exactly as written |

A bare port number is the local case. It gets the same treatment as `DRAUGR_HOST_PORTS`. Draugr
never writes down the address, because WSL gets a new address at each boot. A rule with a literal IP
is correct until the next reboot. Then it fails **closed and silently**.

**A bare port must also be in `DRAUGR_HOST_PORTS`. If it is not, `dr-go` refuses to start.** The two
keys are both necessary. This one says where the model is. That one is where you consent to a hole
into your machine. Draugr does not make the consent from the address. It is a refusal, not a
warning, because the combination cannot work. Without the rule, the interception layer of the
sandbox accepts the connection of the mound, and drops it. The agent then fails at its first prompt,
with a timeout that names nothing. The message names the one line that fixes it:

```
dr-go: DRAUGR_MODEL_URL is port 11435, which is not in DRAUGR_HOST_PORTS
  The mound cannot connect to it, and the agent will fail at its first prompt.
  Add it:  DRAUGR_HOST_PORTS="11435"
```

A URL with a scheme is exempt. It is the address of another party, under the normal network policy,
and `DRAUGR_HOST_PORTS` does not apply to it. Test that one with `dr-policy --check`.

The default is `11435`, not the `11434` of Ollama, on purpose. Ollama has no authentication and no
read-only mode. Thus the inference port also serves `POST /api/pull`, `POST /api/create` (which
reads local files) and `DELETE /api/delete`. `11435` is the query-only proxy in
[`share/ollama-proxy/`](../share/ollama-proxy/). With it as the default, you get the safe setup
without this paragraph.

Draugr takes a value with a scheme literally, and never resolves it: a model on a different
machine, or a company endpoint in front of several. It must speak the API that the configured agent
expects. For `claude`, that is the Messages API of Anthropic at `/v1/messages`.

**The own API of the vendor is a legal value, and there Draugr does nothing for the
authentication.** The proxy of `sbx` rewrites the authorization header for the hosts of Anthropic,
whatever the mound sent. Measured: a request from inside a mound with no credential gets an answer.
Thus the placeholder token from Draugr is inert, not wrong. In that case, the key gives the model
pinning below: three tiers fixed to names that you selected, not the defaults of the account. It
cannot give a different credential. That is `sbx secret`, and
[SECURITY.md](SECURITY.md#running-the-agent-on-a-local-model) says why.

### `DRAUGR_MODEL_FAST`
Default: the value of `DRAUGR_MODEL`. The model for the cheap background calls of the agent. That is
the Haiku tier of Claude Code, which it uses for summaries and titles, not for your work:

```bash
DRAUGR_MODEL="qwen3.8:27b"
DRAUGR_MODEL_FAST="qwen3:8b"      # only if both fit in VRAM at once
```

The default is the main model, not a smaller one. That is the careful choice, and the reason is
memory, not quality. Two models are faster only if both stay loaded. With the KV cache, a 17 GB
model and a 5 GB model do not both fit on a 24 GB card. Thus the second one removes the first, and
each background call pays a reload, and the next foreground call pays it again. One loaded model is
better than two that take turns. Set this only after you make sure that `ollama ps` still reports
`100% GPU` with both loaded.

### How it reaches the agent

We write this down, because two of the three clear routes do not work.

**Not over ssh.** The ssh proxy of `sbx` ignores `AcceptEnv`. We measured this on 0.37.1. That is
why [`share/ssh-config.snippet`](../share/ssh-config.snippet) sends only `LANG` and `LC_*`. Nothing
crosses that way today. Thus `SendEnv ANTHROPIC_BASE_URL` is a value that silently does nothing.

**Not in the kit.** The `environment.variables` of a kit are static and committed, but the local
address changes at each boot. For the same reason, `DRAUGR_HOST_PORTS` names a port, not an address.

**Thus in the attach rcfile.** That is the startup script in [`DRAUGR_ATTACH`](#draugr_attach),
which Draugr makes on the host and sends into the mound at each attach. Draugr builds it when the
address is known, and that is exactly the necessary shape. The variables are exported there. You
can attach a mound started for one model to a different model, with no rebuild.

That is why these keys are **not** in `dr_create_facts`, and never show as drift. As for
`DRAUGR_AGENT_ARGS`, they apply at attach, not at creation. A change costs a `Ctrl+D` and another
`dr-go`, not a recreate.

The agent decides which variables to export, not Draugr. Thus this is part of the module interface
in [`lib/agents/`](../lib/agents/), beside the memory functions:

| | |
|---|---|
| `dr_agent_model_supported` | `0` when this agent can point at a different endpoint |
| `dr_agent_model_env <url> <model> <fast>` | the `KEY=value` lines to export |

For `claude`, that is `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` (necessary, but Ollama ignores
it) and the three `ANTHROPIC_DEFAULT_*_MODEL` tiers. For `codex`, it is a fully different set. That
is why this is a function of the module, and not a table in `common.sh`. If the module of an agent
returns failure for `dr_agent_model_supported`, `DRAUGR_MODEL` is an error, not a value that
silently does nothing.

### What checks that the model is really there

One probe, `dr_model_probe`, serves each caller. The test that refuses to start a session and the
test that explains why must be the same test. If not, `dr-doctor` approves what `dr-go` then
rejects. It answers with a word, not a status:

| | |
|---|---|
| `proxy` | the query-only front door, with a model server behind it |
| `stalled` | the proxy answers, but nothing is behind it |
| `bare` | a model server with no proxy: the agent can also administer it |
| `alive` | it answers, and is neither of those: the endpoint of another party |
| `dead` | nothing listens |
| `unknown` | no `curl` here, so the probe cannot run |

`alive` is why this is not a boolean. A company endpoint does not know `/healthz`, answers 404, and
works well. Thus "not the proxy" must not mean "not working". If it does, Draugr refuses the one
case that a full URL is for.

**`dr-go` refuses on `dead` and `stalled`**, after `dr-up` and before the agent starts. Neither can
give a partial session. Each prompt fails with a dial error that names an address and nothing else.
To continue, start the service, or run `DRAUGR_MODEL= dr-go` to use the cloud once. `bare` is a
warning, not a refusal, because it works. It is only more exposed than the default setup.

It runs after `dr-up`, because the proxy documents `post-up` as the hook to start itself. It runs
before the terminal test, so that a scripted `dr-go` fails on the real problem, and not on the
missing tty.
`dr-doctor` reports all six. When `DRAUGR_MODEL` is set, `dr-status` shows the model and whether it
answers. If not, a model that does not answer looks the same as one that does, until the first
prompt.

### What `dr-doctor` has to stop saying

`dr-doctor` reports a missing agent credential: *"no 'anthropic' secret. The agent starts signed
out."* With `DRAUGR_MODEL` set, that advice is wrong. You do not need that secret, on purpose, and
the advice signs you in to a service that the agent does not call. While `DRAUGR_MODEL` is set,
`dr_agent_secret` returns failure. That already means "this agent has no secret to name", so no new
mechanism is necessary.

This gets one case wrong. `DRAUGR_MODEL_URL` can point at the own API of the vendor. Then the
secret is necessary again. The proxy of `sbx` still gives it, and an expired one fails each prompt
with a 401. `dr-doctor` is silent exactly when its advice is right. A small change can limit the
silence to a URL that is not the own host of the vendor. Nobody made that change yet.

---

## Environment for the agent

### `DRAUGR_ENV`
Default empty. `NAME=value` pairs, separated by spaces, exported into the session of the agent:

```bash
DRAUGR_ENV="CLAUDE_CODE_DISABLE_1M_CONTEXT=1 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=25"
```

The way out, for all that has no Draugr key of its own. On a local model, the most important value
is the point where Claude Code compacts. It must come down from the advertised window of the model
to what your card really holds. Its variable is **not in the documentation of Claude Code**, and it
showed up between two point releases. A typed `DRAUGR_MODEL_CONTEXT` fixes that name in code. This
key leaves the decision to you.

**Values cannot contain spaces**, because spaces separate entries. All other list keys here have
the same limit, for the same reason. A configuration file is shell. Nobody remembers a quoting
scheme inside a quoted string correctly.

Draugr **makes sure that the entries are valid, and does not pass them through as they are**. `dr-go` refuses an
entry with no `=`, or a name that is not a shell identifier, before it builds the mound. That is
necessary. The agent *ignores* an environment variable that it does not know, and does not reject
it. Thus a typo gives a session that looks fully correct, and acts as if you never set the value.
This key exists to prevent exactly that failure. Draugr refuses `PATH` and `HOME` fully. Both
replace, and do not extend. A replacement inside the mound ends the next `dr-go` in
`command not found`, before the agent starts.

It applies in the **attach rcfile** in [`DRAUGR_ATTACH`](#draugr_attach), as the model variables
do, for the same reasons. Thus it is not a `dr_create_facts` entry, and never shows as drift. A
change costs `Ctrl+D` and another `dr-go`, not a recreate.

Draugr exports it **after** the values from [`DRAUGR_MODEL`](#draugr_model), so an explicit value
wins. A way out that the tool can silently overrule is not a way out. Draugr reports a collision,
and is not silent about it. With two values and a hidden winner, you lose an afternoon.

```
dr-go: DRAUGR_ENV sets ANTHROPIC_BASE_URL, and that replaces the value from DRAUGR_MODEL
```

It reaches **only the session of the agent**, not `dr-shell`. A shell in the mound is to look
around, and it starts with no rcfile.

> The `.draugr.conf` of a project can set any variable in the environment of the agent this way.
> That gives no more reach than the rest of that file has. It is shell, and Draugr runs it. The
> same `dr-trust` acceptance controls it.

---

## Moving code

### `DRAUGR_BRANCH`
Default empty, which means the current branch. Sets the branch that `dr-sync` fetches.

### `DRAUGR_REMOTE`
Default `draugr`. The name of the git remote that points at the mound. Draugr never touches your
`origin`.

### `DRAUGR_REQUIRE_CLEAN`
Default `true`. Refuses `dr-go` when the working tree is dirty. A clone contains *only the committed
history*. Uncommitted work is not in it, and the agent silently builds on old code. `dr-go --dirty`
overrides this for one run.

Paths that match `DRAUGR_DATA` are exempt. A different mechanism moves them, and you never commit
them.

**The exemption is all or nothing.** One dirty file that is *not* data still stops the session. The
purpose of the test is to stop an agent that works from old code, and one old file is sufficient.
The refusal names only the files that blocked, and counts the rest:

```text
dr-go: your working tree has uncommitted changes
?? skills.txt
?? skills/
dr-go: 15 more match DRAUGR_DATA and are exempt. These are not.
```

**`.gitignore` is the circular case, and it is not exempt.** You add a pattern to it, so that other
files do not block. That edit then blocks by itself. An exemption is worse than the problem. The
mound gets a clone, and a clone contains only commits. Thus **the clone of the agent does not have
an uncommitted ignore rule**. Under such a rule, `DRAUGR_DATA` files that rsync moved in look
untracked to the agent. That is how a scratch directory that you thought was ignored gets committed.
Commit the `.gitignore`. That step makes the rule true on both sides.

For a rule for *this* checkout only, use **`.git/info/exclude`**. It is untracked, so it never
reaches this test, and you never commit it. The same limit applies in reverse. `git clone` does not
copy it, so the clone of the agent also ignores it. The difference: there you selected the
difference on purpose.

### `DRAUGR_STOP_ON_EXIT`
Default `false`. When true, `dr-go` stops the mound after you leave the agent. That is the last step,
after the sync, the memory export and the data pull, because each of those needs a running mound.

Off by default, and the difference is smaller than it looks. sandboxd stops a mound by itself a
short time after its last session disconnects, and leaving the agent **is** that disconnect. So this
key decides whether the mound goes down *now* or *shortly*, and not whether it goes down at all.
`dr-go` says so when it leaves one running.

What the key really changes is the grace period. A stop at once kills all that the kit starts
through `publishedPorts` or `startup` commands, and it gives up the window in which a second
`dr-go` attaches instead of cold-starting. Inside that window an attach costs 0.36 s and a cold
start 4.2 s; after it, you pay the cold start whether the key is set or not.

| measured on one machine | |
|---|---|
| RAM that a running mound holds | ~1.4 GB, all of it freed on stop |
| cold start (`stopped → running`) | 4.2 s |
| attach to a running mound | 0.36 s |
| grace period before sandboxd stops an idle mound | 30 s on sbx 0.37.1 |

The grace period is sbx's, not Draugr's. It is recorded here because it decides what this key is
worth, not as something to rely on: re-measure it after an sbx upgrade.

Turn it on for each project that serves nothing, or in `~/.config/draugr/config` if the four seconds
are acceptable to you. It does **not** protect your work. The `dr-sync` that already ran protects
the work of the agent. Refer to [the durability model](WORKFLOW.md#what-is-durable-and-what-is-not).

### `DRAUGR_AUTO_SYNC`
Default `true`. Runs `dr-sync` when you leave the agent. It only fetches. Nothing is merged, and your
branch does not move. Thus the worst case is a few seconds, and a remote-tracking branch that you
ignore.

### `DRAUGR_ON_MISSING_REPO`
Default `fail`. What to do when you point Draugr at a directory that is not a git repository.

| Value | |
|---|---|
| `fail` | Refuse, and name the alternatives. Clone mode needs a repository, and clone mode keeps your files read-only for the agent. |
| `create-add-all` | `git init`, and commit all files. For *"this is a code project, and I forgot `git init`"*. Names that look like credentials, and `DRAUGR_DATA` patterns, go into .gitignore **first**, and are never committed. |
| `create-data-only` | `git init` with a `.gitignore` of `*`. Thus git tracks nothing, and `git status` is always empty. Files travel by `DRAUGR_DATA`, which Draugr sets to `*` for you. For folders of documents or data. |

Only `dr-init` and `dr-up` ever create a repository. `dr-status`, `dr-scan` and the others still
refuse. A command that shows the state must not change the state.

`create-data-only` loses `dr-diff` and `dr-merge`, because there are no commits to compare. For
review, `dr-data status` reports which files are different, but not what changed inside them.

---

## Moving data

Large or half-processed files travel beside git, not through it. Refer to
[WORKFLOW.md](WORKFLOW.md#working-with-data-files).

### `DRAUGR_DATA`
Default empty. Patterns relative to the repo, separated by spaces. There are three shapes, and the
shape sets the meaning:

| Entry | Means |
|---|---|
| `scratch/raw/` | trailing slash: that directory and all under it |
| `tmp/**` | contains a slash: a path pattern, anchored at the repo root |
| `*.parquet` | no slash: a bare name or extension, matched at **any** depth |

Draugr always excludes `.git` and `.draugr`, whatever you write here. Without that,
`DRAUGR_DATA="*"` pushes your `.git` over that of the clone in the mound, and even `*.sample`
reaches into `.git/hooks/`.

### `DRAUGR_DATA_PUSH`
Default `auto`. Host → sandbox, before the agent starts. `auto`, `manual` or `off`.

The first transfer of a large tree is a real wait. It happens inside `dr-up`, when you expect a
prompt. That is why `dr-data status` and `manual` exist.

### `DRAUGR_DATA_PULL`
Default `manual`. Sandbox → host, when you detach. A pull overwrites host files, so you must turn
it on.

### `DRAUGR_DATA_DELETE`
Default `false`. Whether a transfer also removes deleted files (`rsync --delete`). Even when `true`,
each run asks. The destructive case: you cleaned one side, and forgot that the other side holds your
only copy.

### `DRAUGR_DATA_CHMOD`
Default `D755,F644`. Files on `/mnt/c` are mode 777 under WSL, and a plain transfer takes that into
the mound. This sets normal modes on the way **in**.

It does nothing on the way **out**. Know why: DrvFs ignores `chmod`. Thus a file pulled onto
`/mnt/c` arrives as `-rwxrwxrwx`, whatever the value of this key. Measured: the pulled file passes
`test -x`, and runs. This key does not stop the sandbox from putting an executable on your host.
[`dr-data diff`](SECURITY.md#the-data-channel-has-no-commit-to-read) is that guard.

### `DRAUGR_DATA_DIFF_MAX`
Default `262144` (256 KB). The size limit for each file in `dr-data diff`. Text files at or under it
show as a real unified diff. A larger file shows only by name and size, because a diff of a 4 GB CSV
helps nobody. Binary files never show, whatever their size. Increase it for a large generated file
that you really need to read.

---

## Memory

### `DRAUGR_MEM_SYNC`
Default `auto`.

| Value | |
|---|---|
| `auto` | Import on `dr-up`, export when you leave the agent. The import only fills a mound with **no** memory, because the store is always the older copy. |
| `manual` | No automatic transfers. But `dr-rm` still refuses to destroy unexported memory, and `dr-status` still reports it. |
| `off` | You keep no agent memory: no transfers, no refusal, no memory section. |

### `DRAUGR_MEM_STORE`
Default `~/.local/share/draugr/memory`. Where `dr-mem export` writes: by the host form of the
project key, then by agent.
```text
~/.local/share/draugr/memory/
└── c--Code-TabuLua/          the project, host-keyed so it never starts with "-"
    ├── claude/
    │   ├── .draugr-export    what was exported, from where, when
    │   ├── memory/           the exported copy
    │   └── memory.previous/  the one it replaced — one `mv` from getting it back
    └── codex/
        └── memory/           memories/*.md, and the SQLite session state
```

The memories of two agents for one project are different things, with different shapes. Thus each
gets its own corner. The project comes first, so that all about it stays in one place. A store
from before 0.2.0 had `memory/` directly in the corner of the project. After the upgrade, the first
`dr-mem` or `dr-status` moves it under `claude/`, and says so.

It can be in any place, also on the filesystem of WSL. Draugr moves the files through the repo,
because `sbx cp` is a Windows binary that cannot write to a WSL path.

---

## Plugins

### `DRAUGR_PLUGIN_STORE`
Empty by default, and the feature is off until you set it. It names the directory that `dr-plugin`
manages. That is the plugin library that each mound reads, on your host as inert files, and mounted
**read-only**.

```text
/mnt/c/Code/claude-plugins/
├── seed/           the library the mounds read
├── seed.old/       the one it replaced — `dr-plugin rollback` swaps them
└── settings.json   which plugins are switched on
```

This one **must be on a Windows drive**, not as [`DRAUGR_MEM_STORE`](#draugr_mem_store). A mound
must point at it, and sbx workspaces are Windows paths. Thus a store on the filesystem of WSL can
never be mounted. `dr-plugin` refuses such a store.

With it set, `dr-plugin` works. But the plugins do **not** reach your mounds yet. That needs three
more values. `dr-plugin` with no arguments tests them, and prints the exact lines if they are
missing. Refer to [docs/CLAUDE_PLUGINS.md](CLAUDE_PLUGINS.md).

---

## Run-state dependencies

One `dr-up` starts the mounds that the mound of this repository needs, if they are not already
running, then the mound itself. Empty by default, so this does not exist until a project asks for
it. [docs/DEPENDENCIES.md](DEPENDENCIES.md) has the full design, with what a claim is, and why an
old claim is harmless.

### `DRAUGR_REQUIRES`
Empty by default. **Repository paths**, separated by spaces, whose mounds must run before this one
is of any use. It was written for the gateway, which gives a forge VM its only way out.

```bash
DRAUGR_REQUIRES="$HOME/code/draugr-gateway"
```

Each entry is a repository, not a sandbox name, because `dr-up` starts a mound. Absolute paths,
paths relative to `~/`, and paths relative to the repo all work. To start one, Draugr runs the own
`dr-up` of that repository. That is idempotent, and it runs the `post-up` hook of that repository.
The readiness test of a dependency is already in that hook. "Ready" means that its `dr-up` returned
0.

> **To require a repository is to run its code.** Its `.draugr.conf` is shell, and its hooks run on
> your machine, as you. Draugr refuses a dependency whose configuration you did not accept with
> `dr-trust`. It does not continue with default values. Without its configuration, `DRAUGR_SANDBOX`
> is `draugr-<leaf>`, and a start of the wrong mound is worse than a stop.

`dr-up --skip-deps` starts only this mound. `dr-dep` shows what is required, what runs, and who else
uses it.

### `DRAUGR_EXCLUSIVE`
Default `false`. Draugr reads it from the configuration of the **dependency**, never from that of
the consumer, because exclusivity belongs to the resource. A gateway in front of one Windows desktop
is exclusive. A database that queues its callers is not.

With `true`, Draugr refuses the second project that wants it, by name:

```text
dr-up: gwmound is exclusive, and /home/you/code/TabuLua uses it since 14:02
```

The dependency declares it, not the projects that use it. If each consumer decides, one careless
repository defeats it. If the holder of a lock is gone, Draugr takes the lock over, and does not
wait. The first terminal in a project never locks out a second terminal in the same project.

### `DRAUGR_LINGER`
Default `10m`. Draugr also reads it from the configuration of the dependency. It sets how long a
mound that is up **as a dependency** stays up after its last user leaves. `off` keeps it up until
somebody stops it.

The delay is the purpose. A `dr-up --recreate`, a crash and a retry, or a terminal closed and
another opened, all drop the count for a few seconds. A forge VM that takes minutes to boot must not
fail because of that. A new user inside the window cancels the stop. Write `30s`, `10m`, `1h` or
`off`. Draugr refuses all other values, and does not guess.

This never touches a mound that you started yourself, only a mound that the `dr-up` of a different
repository started.

---

## Safety rails

### `DRAUGR_SCAN`
Default `true`. Runs `dr-scan` before the mound exists, and that is the purpose. Draugr must find a
credential before anything can read it.

### `DRAUGR_SCAN_PATTERNS`
Default `.env *.pem *.key id_rsa id_ed25519 credentials.json secrets.*`. Globs matched against the
**basename** of each file that git does not track, ignored or not. That is the full purpose.

### `DRAUGR_SCAN_FAIL`
Default `block`. `block` makes a finding a refusal. `warn` reports and continues.

Keep `block`. `.gitignore` hides files from git, not from the filesystem. The agent can read an
untracked `.env` through the read-only mount, though it is not in the clone of the agent.

### `DRAUGR_FORGE`
Default empty, which means that **there is no forge**. That is the right answer, unless you need
work done inside a Windows VM. Set it to the name of the VM, and `dr-forge` starts to work. If you
leave it empty, `dr-forge` refuses each action. Thus nobody gets the feature by accident.

It names a **VM**, not a path, because the VM exists on both sides of the boundary. AppSandbox
knows it by name, and so does the tunnel supervisor. All else follows from that name: which disk,
which engine, where the layers are. Refer to [FORGE.md](FORGE.md).

**It is the only key that the forge needs**, and `dr-forge up` keeps it that way. `up` needs the
gateway mound to run, and gets it from [`DRAUGR_REQUIRES`](#draugr_requires). That key already
means "this repo needs the mound of that one". `dr-dep up` starts all mounds named there, so
nothing must find which one is the gateway. Thus a game project that uses the forge names it as any
other mound that it depends on, and its configuration has nothing special for the forge.

From inside the own directory of the gateway, `dr-forge up` starts the own mound of that
repository. It knows it by its `DRAUGR_PORTS`, which publish `127.0.0.1:18888`. The only way out of
the VM arrives on that port. Each other part that `up` needs comes with Draugr, also the tunnel
supervisor. Thus no other repository must be present, or have a specific layout.

### `DRAUGR_FORGE_NOSCAN`
Default empty. Guest paths that `dr-forge init` excludes from Microsoft Defender, separated by
**semicolons**. A Windows path can contain spaces, but not semicolons. That is why Windows itself
separates paths that way.

```bash
DRAUGR_FORGE_NOSCAN="C:\UE_4.27;D:\work\MyGame;D:\work\MyGame\DerivedDataCache"
```

**Why this is a key, and not a built-in list.** Real-time protection reads each file that a build
writes, and each file that it reads back. In a forge VM, a differencing disk handles that write
pattern worst ([FORGE.md](FORGE.md#what-is-a-layer-not-the-base)). But `init` is generic. It cannot
know which trees are build output that you can make again, and which hold something to scan. Thus
Draugr gives the mechanism, and your project gives the paths.

**It only adds.** It leaves alone an exclusion that `init` did not create. A setup script must not
remove an exclusion that somebody added by hand, only because a configuration file does not name it.
Thus an empty key does not undo what it did. `Remove-MpPreference` in the guest does.

**`*` disables Defender fully**, and excludes nothing:

```bash
DRAUGR_FORGE_NOSCAN="*"
```

The list is also the switch, because one key with a special value is easier to keep correct than two
keys that can disagree. `*` cannot be a real path. Other entries beside it have nothing left to
exclude, and `init` says so.

**Think about this one.** The guest downloads installers and assets from vendor stores, so the
protection has a job. An exclusion of the build trees moves the busy path out of its way, but keeps
the protection. That is why it is the default shape. When `*` is defensible, this is why. The guest
has **no network adapter**, so each byte that it fetches already passed the allowlist of the
gateway. Also, the security claim of the forge is [already weaker than that of a
mound](SECURITY.md). Why it is a real decision: an agent that controls that guest can run all that
the allowlist reaches.

Two practical notes. **Tamper Protection blocks it.** It is on by default on Windows 11, and the
cmdlet can return with no error. Thus `init` tests the effect, and tells you when the change did not
apply. Also, Windows can turn real-time protection on again after an update, so this is not
permanent. A new run of `init` turns it off again.

---

### `DRAUGR_FORGE_LAYERS`
Default empty, which means `C:\ForgeLayers`. Where
[`dr-layer`](FORGE.md#the-layer-mechanism-as-a-command-dr-layer) keeps the disk layers of the forge.

```bash
DRAUGR_FORGE_LAYERS="D:\ForgeLayers"
```

**It must be your fastest disk, not your biggest.** Reads walk the chain. If the top layer does not
hold a block, the read goes to its parent, and so on down. Thus the frozen parents are the busy read
path. They hold Windows, Visual Studio and the engine. On a spinning disk, to save space on an SSD,
they slow each read of the project. Archives are the opposite case, and go on the big slow disk,
because nothing reads them until a restore.

It must also be **outside the own tree of AppSandbox**, but not for the clear reason. A deletion of
a VM removes *the folder of its disk*, with all its contents. Thus the risk follows the VM
**registration**, not the path. A base under `C:\ForgeLayers` with a VM that still points at it is
as deletable as one under `ProgramData`. `dr-layer freeze --unregister` ends that risk. A place
outside the tree of AppSandbox gives a different benefit. Nothing that AppSandbox does to its own
directory can reach a layer that was never in it: an uninstall, a reset, a later clean-up.

**Layer stores on more than one drive are normal.** The engine layers are the big ones. Thus they
are often on the big disk, while `layer-0` stays on the fast one. This key is the default, and
`dr-layer --root <path>` overrides it for one command. The guards that look for the children of a
layer search the `ForgeLayers` of each fixed drive, whatever the value of this key. A chain across
drives is the real shape of this machine. A test showed this: a scan of one root found no children
for a layer that had four on a different drive.

## Hooks

Not keys, but the same job. Executable scripts at
`.draugr/hooks/{pre-up,post-up,post-create,pre-attach,post-attach,post-sync,pre-rm}`.

They run on the **host**, in WSL, with the merged configuration in the environment. The commands of
a kit cannot do that, because a kit runs inside the mound, and cannot see your machine. If a hook
exits non-zero, the command stops. Thus a hook can say no.

`post-create` runs only when Draugr really builds a sandbox. `post-up` runs on each `dr-up`, also
when it only starts a stopped mound.
