# Agent support

Draugr uses one workflow for Claude Code and Codex. Agent adapters handle native
state, arguments, authentication advice, and model providers. Plugins have native
backends. Git, data review, mounts, ports, dependencies, and forge transport stay
shared. Other sbx agents can use that shared workflow; their memory and plugin
layouts are not claimed as supported.

| Capability | Claude Code | Codex |
|---|---|---|
| Create, attach, shell; suspend/resume through SSH | Shared workflow | Shared workflow |
| Native arguments and per-agent defaults | Supported | Supported, including model and reasoning settings |
| Continue on first use | Drops `--continue` only on known absence | Drops ordinary `resume --last` only on known absence |
| Memory transfer | Project memory directory | Quiet snapshot of memories, transcripts, indexes, and selected databases |
| Conversation recovery after recreation | Transcript backup is outside `dr-mem` | Supported for the measured Codex layout |
| Import from a host installation | Project memory directory | Curated explicit source; global home refused |
| Plugin lifecycle | Existing Claude seed library | Native CLI build and published local marketplaces |
| Plugin enablement and skills report | Claude settings and registry | Codex receipt and invocation overrides |
| Local/custom provider | Anthropic Messages API | Responses API, native provider overrides |
| Separate fast model | Haiku tier mapping | No measured mapping; main model used with a warning |
| MCP and hooks | Native configuration/plugins | Native configuration/plugins; hook review remains required |
| Repository instructions | Optional `CLAUDE.md` | Optional `AGENTS.md` |

## Choose native models and reasoning

Keep cloud model selection in native arguments. `DRAUGR_MODEL` selects a different
provider and has a different purpose. For example, with a model your account offers:

```bash
DRAUGR_AGENT=codex
DRAUGR_AGENT_ARGS_CODEX='resume --last --model gpt-6.1-sol -c model_reasoning_effort="xhigh"'
```

The reasoning value must be supported by the chosen model. A successful sign-in
does not prove that your account can use every model. An unsupported-model error
needs another available model; an expired login needs another sign-in. For provider
or network failures, inspect `dr-doctor` and the native error before changing either.
See [native configuration](https://learn.chatgpt.com/docs/config-file/config-reference).

Explicit session IDs, `--all`, fork, prompts, and unfamiliar options retain native
meaning. A failed probe preserves the request. Draugr does not parse session
databases to guess current-directory eligibility; when that is unknown, Codex makes
the selection. `dr-go --bare` clears configured agent arguments for one launch.

## Codex context recovery

Use one repository per Codex mound. Its home can contain state from every working
directory used there. Export is a recovery snapshot of that whole mound's selected
context, not a cross-project database filter.

The format-2 export selects `memories/`, `memories_v2/`, `sessions/`,
`archived_sessions/`, `session_index.jsonl`, `history.jsonl`, and these databases
with their matching WAL files: `state_*`, `thread_history_*`, `memories_*`,
`goals_*`, and `queue_*`. Database names end in `.sqlite`. It excludes shared-memory
indexes, logs, credentials, configuration, plugin caches, and connection secrets.
Selected links and special files are refused before staging or upload.

Leave Codex and its background server before either transfer. An active or unknown
writer fails the transfer; an export failure preserves the last complete store.
Draugr also compares hashes around the copy. These probes cannot lock an external
launcher: do not attach during import/export. Import removes stale database WAL and
shared-memory indexes before restoring the supplied pair.

`CODEX_HOME` from the mound and `DRAUGR_ENV` is respected. A separate
`CODEX_SQLITE_HOME` or an explicit `sqlite_home` setting is currently refused.
The check conservatively refuses `sqlite_home` references, including quoted keys,
profiles, and configured agent arguments; failed configuration reads are unknown.
State-location overrides passed through independent native commands are outside
Draugr's observations. Back those up explicitly rather than relying on `dr-mem`.
Cross-version database migration is Codex's responsibility; use a compatible image.
Unversioned older exports remain importable with a completeness warning: they may
lack transcripts. Re-export from the old mound before removing it when possible.

`--from-host` is refused for Codex. First create a dedicated, reviewed context
directory with only the project data you intend to transfer, then use
`dr-mem import --source DIRECTORY`. Do not supply a complete host `.codex` home.
Filtering a database after upload would already expose its unrelated contents.

Import preserves the target's configuration and memory feature choices. Restoring
a conversation does not require enabling new memory generation. Inspect
`dr-mem status`; enable generation separately with
`dr-shell -- codex features enable memories` if desired. Automatic import only fills
an empty target. A database created by native startup counts as existing state;
review and use an explicit import if that blocks recovery of a fresh mound.

When switching agents, the loss check and export follow the agent installed in the
old mound. Stores stay separated by project and agent. Two named mounds for the
same project need a native agent identity; if sbx cannot report it, context
operations refuse rather than guessing from the replacement configuration. Mounds for the
same project and agent share that recovery store; serialize exports to it.

## Codex plugins

Keep the existing `dr-plugin` verbs. Select `DRAUGR_AGENT=codex` to manage the Codex
corner of `DRAUGR_PLUGIN_STORE`; the legacy Claude library remains at its root.

```bash
DRAUGR_PLUGIN_STORE=/mnt/c/Code/agent-plugins
dr-plugin add /mnt/c/Code/my-marketplace my-plugin
dr-plugin list
dr-plugin skills
dr-plugin kit my-plugin@my-marketplace
```

A local source must be a dedicated marketplace directory. Git sources are passed
to the native marketplace CLI. Builds use a disposable, agent-specific mound and
an empty Codex home. The host receives package files and a receipt, never the build
home's authentication, native settings, or writable plugin data. A failed build
leaves the published library intact. Inspect a leftover `.build` before retrying
with `--force`.

Mount the **parent** Codex directory read-only, then add generated kits:

```bash
DRAUGR_MOUNTS='/mnt/c/Code/agent-plugins/codex:ro'
DRAUGR_KIT='.draugr/kit plugin-codex-my-marketplace-my-plugin'
```

Validate the generated kit with `dr-kit validate`, then create or apply it through
the usual kit workflow. Each consumer registers the mounted local marketplace and
installs into its private native cache. Installation needs no upstream download.
The parent mount keeps child-directory publication swaps visible. Kits are
install-only and repeatable; current sbx kits use the v3 lifecycle capability.

`update` refreshes selected packages from their original sources. `enable` and
`disable` publish switches that apply on the next `dr-go`, in both attach modes.
These switches do not prove a plugin has authenticated or loaded. `remove` drops
its catalog entry and records a disabled override for stale consumer installs.
Remove its generated kit from `DRAUGR_KIT` too. `clean` removes unreferenced package
versions from the next publication. `rollback` swaps `seed` and `seed.old`; applying
the install kit again refreshes a consumer's cache. Running sessions keep their
already loaded content until restarted.

`dr-plugin skills` reports packaged skills. Use native `codex plugin list --json`
inside the mound to inspect installation and enablement. Service authentication,
dependencies, and runtime errors remain native concerns. Packages can contain
skills, MCP servers, and hooks, but Claude-specific components are not translated.
On the measured Codex, a bundled stdio MCP server can use `cwd: "."` and a relative
script argument. `${PLUGIN_ROOT}` in MCP arguments remained literal; hook path
expansion is a separate native behavior.
Review hooks with `/hooks` in Codex. Draugr never accepts hook trust for you, and
does not export trust or service credentials between mounds. See
[plugin packaging](https://developers.openai.com/plugins/build/plugins) and
[hook review](https://learn.chatgpt.com/docs/hooks).

## Local providers

Codex receives invocation-only `-c` values selecting `draugr-local`, the model,
`wire_api="responses"`, and `requires_openai_auth=false`. The base URL ends in
`/v1`; Draugr appends that suffix if absent. The existing sbx cloud configuration
stays available when `DRAUGR_MODEL` is cleared. Both attach transports apply the
same settings. Draugr's provider selection takes precedence over native model and
provider arguments for that launch.

The endpoint must implement Responses streaming and tool calls. A working Messages
or Chat Completions endpoint is insufficient. The shared reachability probe does
not certify protocol or model compatibility. Keep the query-only proxy boundary;
model discovery and administration are not required by this custom provider.
See [local model setup](CONFIG.md#running-the-agent-on-a-local-model) and
[its network limits](SECURITY.md#running-the-agent-on-a-local-model).

## Native configuration and optional workflows

Use a reviewed project `.codex/config.toml`, or native commands inside the mound,
for extra MCP servers. For the optional forge, configure its existing bridge URL:

```toml
[mcp_servers.forge]
url = "http://GATEWAY:PORT/mcp"
```

Use the actual endpoint from the forge configuration and its network policy. Never
pass AppSandbox's host control token to Codex. The forge remains optional and has
no dependency on the default path. Native MCP configuration is described in the
[Codex MCP reference](https://learn.chatgpt.com/docs/extend/mcp).

Repository instructions are optional shared files. Keep personal instructions in
ignored local files and opt into them explicitly; Draugr does not copy global host
instructions or translate `CLAUDE.md` into `AGENTS.md`.

Native `codex review`, `fork`, and `exec --json` can be useful inside a mound.
`dr-shell -- codex ...` runs the native command directly: supply its model/provider
configuration explicitly, since it does not build the `dr-go` attach environment.
Native review is advisory; use the normal `dr-diff` and sync boundary for changes.

## Compatibility and evidence

The native baseline is sbx **0.53.0** and codex-cli **0.167.2**. sbx was upgraded
from 0.37.1 because 0.53 fixes local model selection falling back to OpenAI with
`--model`. Use that release or later for Codex local providers. See the
[sbx release notes](https://github.com/docker/sbx-releases/releases/tag/v0.53.0).

Measured in disposable mounds: native launches through SSH and sbx attach, a real OAuth-backed conversation, context export,
fresh-mound import and resume of the same thread; native local-marketplace plugin
installation from a read-only relocated publication; and a deterministic Responses
endpoint completing a real shell-tool round trip without an Authorization header.
A missing model failed at that endpoint. Plugin add/update, kit replay, read-only
mounts, failed publication, enable/disable, removal, clean, and rollback were also
exercised. A packaged skill appeared in the native prompt, a bundled stdio MCP
tool returned its marker, and an untrusted hook stayed skipped. The reviewed
synthetic hook ran with an explicit one-invocation authorization in the probe;
Draugr does not persist or bypass that trust. Claude Code 2.1.323 completed a real
request and a project-memory round trip in a separate disposable mound.

This protocol test does not establish
the quality or compatibility of any particular Ollama model.

sbx 0.53 returns an array from `ls --json`; Draugr accepts that and the older object
envelope. It removed `create -q`. Its built-in agents use v3 kits, which cannot
compose with older v2 mixins. New starter kits and plugin kits select the current
format; existing project kits need a reviewed migration, not an automatic rewrite.
See [Docker's kit compatibility guide](https://docs.docker.com/ai/sandboxes/customize/).
Shared skills are read-only by default on this sbx baseline; earlier measurements
of writable shared skills apply to 0.37.1.

To repeat a compatibility check, use a disposable committed project and separate
configuration, memory, plugin, and kit stores. Create a new named mound rather
than changing a working one. Record `sbx --version`, `codex --version`, native
plugin help, selected provider keys, and state filenames. Send a synthetic marker
conversation, leave the agent, export and check context, then import into a second
fresh mound with the same CLI layout and resume that thread by ID. Package a local
marker plugin, generate its kit, install it from a read-only parent mount, and
check the native skill/MCP/hook behavior. For local providers, use an isolated
Responses fixture and inspect only route, model, credential-header presence, and
tool outcomes; repeat with a missing model and an unavailable endpoint.

Live forge command/image acceptance and a real Ollama model are unmeasured here:
no configured disposable forge or model server was used. Existing working VMs
are not acceptance fixtures. The default path has no forge dependency.
