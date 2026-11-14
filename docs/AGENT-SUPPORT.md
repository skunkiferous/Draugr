# Agent support

Draugr uses one workflow for Claude Code and Codex. Agent adapters handle native
state, arguments, advice about authentication, and model providers. Plugins have native
backends. Git, data review, mounts, ports, dependencies, and forge transport stay
shared. Other sbx agents can use that shared workflow. Draugr does not claim that it
supports their memory and plugin layouts.

| Capability | Claude Code | Codex |
|---|---|---|
| Create, attach, shell, and suspend/resume through SSH | Shared workflow | Shared workflow |
| Native arguments and per-agent defaults | Supported | Supported, including model and reasoning settings |
| Continue on first use | Drops `--continue` only on known absence | Drops ordinary `resume --last` only on known absence |
| Memory transfer | Project memory directory, and the conversation that `DRAUGR_MEM_TRANSCRIPTS` selects | Quiet snapshot of memories, transcripts, indexes, and selected databases |
| Conversation recovery after recreation | Supported: the newest transcript travels by default | Supported for the measured Codex layout |
| Import from a host installation | Project memory directory | Curated explicit source. Draugr refuses a global home |
| Plugin lifecycle | Existing Claude seed library | Native CLI build and published local marketplaces |
| Plugin enablement and skills report | Claude settings and registry | Codex receipt and invocation overrides |
| Local or custom provider | Anthropic Messages API | Responses API, native provider overrides |
| Separate fast model | Haiku tier mapping | No measured mapping. Draugr uses the main model and prints a warning |
| MCP and hooks | Native configuration and plugins | Native configuration and plugins. You must still review hooks |
| Repository instructions | Optional `CLAUDE.md` | Optional `AGENTS.md` |

## Choose native models and reasoning

Keep the selection of a cloud model in the native arguments. `DRAUGR_MODEL` selects a
different provider and has a different purpose. This example uses a model that your
account offers:

```bash
DRAUGR_AGENT=codex
DRAUGR_AGENT_ARGS_CODEX='resume --last --model gpt-6.1-sol -c model_reasoning_effort="xhigh"'
```

The chosen model must support the reasoning value. A successful sign-in does not
prove that your account can use every model. If Codex reports an unsupported model,
choose another available model. If the login expired, sign in again. If a provider or
the network fails, read the output of `dr-doctor` and the native error before you change
either.
See [native configuration](https://learn.chatgpt.com/docs/config-file/config-reference).

Explicit session IDs, `--all`, fork, prompts, and unfamiliar options keep their native
meaning. A failed probe preserves the request. Draugr does not parse session
databases to guess which sessions belong to the current directory. If that is unknown,
Codex makes the selection. `dr-go --bare` clears the configured agent arguments for one launch.

## Codex context recovery

Use one repository for each Codex mound. The home of Codex can contain state from every working
directory that the mound used. An export is a recovery snapshot of the selected
context of the whole mound. It is not a filter for one project in a database.

The format-2 export selects `memories/`, `memories_v2/`, `sessions/`,
`archived_sessions/`, `session_index.jsonl`, `history.jsonl`, and these databases
with their matching WAL files: `state_*`, `thread_history_*`, `memories_*`,
`goals_*`, and `queue_*`. Database names end in `.sqlite`. The export excludes the indexes
of shared memory, logs, credentials, configuration, plugin caches, and connection secrets.
Draugr refuses selected links and special files before staging or upload.

Leave Codex and its background server before either transfer. An active or unknown
writer fails the transfer. A failed export preserves the last complete store.
Draugr also compares hashes around the copy. These probes cannot lock an external
launcher, so do not attach during an import or an export. An import removes the stale
database WAL files and shared-memory indexes before it restores the supplied pair.

Draugr respects `CODEX_HOME` from the mound and from `DRAUGR_ENV`. Draugr refuses a separate
`CODEX_SQLITE_HOME` or an explicit `sqlite_home` setting. The check refuses every
`sqlite_home` reference that it can find, including quoted keys,
profiles, and configured agent arguments. If Draugr cannot read the configuration, the answer is unknown.
Draugr cannot observe an override of the state location that an independent native command receives.
Back up that state explicitly. Do not rely on `dr-mem` for it.
Codex must migrate its own databases between versions, so use a compatible image.
Draugr can still import an older export that has no version. It warns that the export is
incomplete, because it can lack transcripts. If possible, export again from the old mound before you remove it.

Draugr refuses `--from-host` for Codex. First create a dedicated, reviewed context
directory with only the project data that you intend to transfer. Then run
`dr-mem import --source DIRECTORY`. Do not supply a complete host `.codex` home.
Draugr cannot filter a database after the upload, because the upload already exposes its unrelated contents.

An import preserves the configuration and the memory feature choices of the target. Restoring
a conversation does not enable the generation of new memory. Read the output of
`dr-mem status`. If you want generation, enable it separately with
`dr-shell -- codex features enable memories`. An automatic import only fills
an empty target. A database that native startup created counts as existing state.
If that blocks the recovery of a fresh mound, review the state and use an explicit import.

When you switch agents, the loss check and the export follow the agent that runs in the
old mound. Draugr keeps a separate store for each project and agent. Two named mounds for the
same project need a native agent identity. If sbx cannot report it, the context
operations refuse and do not guess from the replacement configuration. Mounds for the
same project and agent share one recovery store, so run their exports one at a time.

## Codex plugins

Keep the existing `dr-plugin` verbs. Set `DRAUGR_AGENT=codex` to manage the Codex
part of `DRAUGR_PLUGIN_STORE`. The legacy Claude library stays at the root of the store.

```bash
DRAUGR_PLUGIN_STORE=/mnt/c/Code/agent-plugins
dr-plugin add /mnt/c/Code/my-marketplace my-plugin
dr-plugin list
dr-plugin skills
dr-plugin kit my-plugin@my-marketplace
```

A local source must be a dedicated marketplace directory. Draugr passes Git sources
to the native marketplace CLI. A build uses a disposable mound for that agent and
an empty Codex home. The host receives package files and a receipt. It never receives the
authentication, the native settings, or the writable plugin data of the build home.
A failed build leaves the published library intact. Inspect a leftover `.build` before you retry
with `--force`.

Mount the parent Codex directory read-only, then add the generated kits:

```bash
DRAUGR_MOUNTS='/mnt/c/Code/agent-plugins/codex:ro'
DRAUGR_KIT='.draugr/kit plugin-codex-my-marketplace-my-plugin'
```

Validate the generated kit with `dr-kit validate`. Then create or apply it through
the usual kit workflow. Each consumer registers the mounted local marketplace and
installs into its private native cache. The installation needs no upstream download.
The parent mount keeps the swaps of child directories visible. The kits only install
and are safe to repeat. Current sbx kits use the v3 lifecycle capability.

`update` refreshes the selected packages from their original sources. `enable` and
`disable` publish switches that apply on the next `dr-go`, in both attach modes.
These switches do not prove that a plugin authenticated or loaded. `remove` drops
the catalog entry of the plugin and records a disabled override for stale consumer installs.
Also remove its generated kit from `DRAUGR_KIT`. `clean` removes the unreferenced package
versions from the next publication. `rollback` swaps `seed` and `seed.old`.
To refresh the cache of a consumer, apply the install kit again. Running sessions keep their
loaded content until they restart.

`dr-plugin skills` reports the packaged skills. To see the installation and the enablement,
run the native `codex plugin list --json` inside the mound. Authentication of services,
dependencies, and runtime errors stay native concerns. A package can contain
skills, MCP servers, and hooks. Draugr does not translate components that are specific to Claude.
On the measured Codex, a bundled stdio MCP server can use `cwd: "."` and a relative
script argument. `${PLUGIN_ROOT}` in MCP arguments stayed literal. The expansion of paths in hooks
is a separate native behavior.
Review hooks with `/hooks` in Codex. Draugr never accepts trust for a hook on your behalf, and
does not export trust or service credentials between mounds. See
[plugin packaging](https://developers.openai.com/plugins/build/plugins) and
[hook review](https://learn.chatgpt.com/docs/hooks).

## Local providers

Codex receives `-c` values for one invocation only. They select `draugr-local`, the model,
`wire_api="responses"`, and `requires_openai_auth=false`. The base URL ends in
`/v1`. If the suffix is absent, Draugr appends it. If `DRAUGR_MODEL` is empty, the existing sbx cloud configuration
stays available. Both attach transports apply the
same settings. For that launch, the provider selection of Draugr takes precedence over the native model and
provider arguments.

The endpoint must implement Responses streaming and tool calls. A working Messages
or Chat Completions endpoint is not enough. The shared reachability probe does
not prove that the protocol or the model is compatible. Keep the query-only proxy boundary.
This custom provider does not need model discovery or administration.
See [local model setup](CONFIG.md#running-the-agent-on-a-local-model) and
[its network limits](SECURITY.md#running-the-agent-on-a-local-model).

## Native configuration and optional workflows

To add MCP servers, use a reviewed project `.codex/config.toml` or the native commands inside the mound.
For the optional forge, configure its existing bridge URL:

```toml
[mcp_servers.forge]
url = "http://GATEWAY:PORT/mcp"
```

Use the actual endpoint from the forge configuration and its network policy. Never
pass the host control token of AppSandbox to Codex. The forge stays optional, and the
default path does not depend on it. The native MCP configuration is described in the
[Codex MCP reference](https://learn.chatgpt.com/docs/extend/mcp).

Repository instructions are optional shared files. Keep personal instructions in
ignored local files and opt into them explicitly. Draugr does not copy global host
instructions and does not translate `CLAUDE.md` into `AGENTS.md`.

The native commands `codex review`, `fork`, and `exec --json` are useful inside a mound.
`dr-shell -- codex ...` runs the native command directly. It does not build the `dr-go` attach
environment, so supply the model and provider configuration explicitly.
Native review gives advice only. For changes, use the normal `dr-diff` and the sync boundary.

## Compatibility and evidence

The native baseline is sbx **0.53.0** and codex-cli **0.167.2**. We upgraded sbx
from 0.37.1 because 0.53 fixes a fault: local model selection fell back to OpenAI with
`--model`. For Codex local providers, use that release or a later one. See the
[sbx release notes](https://github.com/docker/sbx-releases/releases/tag/v0.53.0).

We measured these items in disposable mounds. Native launches through SSH and sbx attach worked.
A real conversation that used OAuth worked. Context export, and the import and resume of the same
thread in a fresh mound, worked. A native installation of a local-marketplace plugin worked
from a read-only relocated publication. A deterministic Responses
endpoint completed a real shell-tool round trip without an Authorization header.
A missing model failed at that endpoint. We also tested plugin add and update, kit replay, read-only
mounts, failed publication, enable and disable, removal, clean, and rollback. A packaged skill appeared in the native prompt, a bundled stdio MCP
tool returned its marker, and an untrusted hook stayed skipped. The reviewed
synthetic hook ran in the probe with an explicit authorization for one invocation.
Draugr does not persist or bypass that trust. Claude Code 2.1.323 completed a real
request and a round trip of project memory in a separate disposable mound.

This protocol test does not show the quality or the compatibility of any particular Ollama model.

sbx 0.53 returns an array from `ls --json`. Draugr accepts that and the older object
envelope. sbx 0.53 removed `create -q`. Its built-in agents use v3 kits, which cannot
compose with older v2 mixins. New starter kits and plugin kits select the current
format. Existing project kits need a reviewed migration, not an automatic rewrite.
See [Docker's kit compatibility guide](https://docs.docker.com/ai/sandboxes/customize/).
Shared skills are read-only by default on this sbx baseline. The earlier measurements
of writable shared skills apply to 0.37.1.

### The older measurements, checked again on this baseline

Draugr recorded most of what it knows about `sbx` on 0.37.1. We measured each claim below again on
0.53.0, in disposable mounds. Eight claims held. Two changed. One question that we never measured now
has an answer.

| Claim as Draugr recorded it | On 0.53.0 |
|---|---|
| the ssh proxy ignores `AcceptEnv`, so `SendEnv` carries nothing, not even `LANG` | holds |
| the agent is in the sudo group with no password | holds |
| a `localhost:<port>` rule reaches the Windows loopback, and a denied host answers 403 through the proxy | holds, both halves |
| `kit add` replays the install commands of every kit, so each must be idempotent | holds |
| sandboxd stops a mound 30 s after its last session | holds (stopped between +28 s and +33 s) |
| a kit directory on the ext4 of WSL is refused | holds |
| `--kit` is accepted more than one time | holds |
| `sbx cp -L` follows links anywhere in the tree | **changed.** The copy stops at the first link, drops the rest, and exits 0. `-L` changes nothing. See [plugins](CLAUDE_PLUGINS.md) |
| `kit add` refuses a kit that declares startup commands | **changed.** It accepts such a kit now, so such a project can take a kit change in place |
| can a kit fix the host port? (never measured) | **answered: no.** `kit validate` accepts `host-port@1` and `create` refuses it as an unsupported capability |

Two facts that no claim predicted came out of the same session. `sbx kit validate` is **not** a
complete check. It accepted a capability that `sbx create` then refused. This is the third member
of the family that already holds the duplicate kit name and `requires: agent:`. And **one mound is
one process view**: a file that one `sbx exec` session holds open is visible, with the same pid, to a
later and separate session. That is how `dr-mem` can see whether the agent is writing.

To repeat a compatibility check, use a disposable committed project and separate
stores for configuration, memory, plugins, and kits. Create a new named mound. Do not
change a working one. Record `sbx --version`, `codex --version`, the native
plugin help, the selected provider keys, and the state filenames. Send a synthetic marker
conversation and leave the agent. Export and check the context, then import it into a second
fresh mound with the same CLI layout, and resume that thread by ID. Package a local
marker plugin, generate its kit, and install it from a read-only parent mount. Then
check the native behavior of the skill, the MCP server, and the hook. For local providers, use an isolated
Responses fixture. Inspect only the route, the model, whether a credential header is present, and the
tool outcomes. Repeat the test with a missing model and with an unavailable endpoint.

We did not measure the live acceptance of the forge command and image, or a real Ollama model.
We used no configured disposable forge and no model server. Existing working VMs
are not acceptance fixtures. The default path has no dependency on the forge.
