# Draugr — implementation plan

This plan builds the tool described in [README.md](README.md). The README is the specification;
where the two disagree, the README wins and this file gets corrected.

Work proceeds in eight phases. Each phase ends with something you can actually run, and has an
acceptance check written before the code. The order is chosen so that **the daily loop from the
README works end to end at the end of Phase 3** — everything after that makes it safer, not more
functional.

---

## Prior art, and what it means for scope

Surveyed August 2026, before writing any code.

**Wrappers around `sbx` already exist** — [sbxgo](https://github.com/HenrikPoulsen/sbxgo) (Go,
committed `.sbxgo/config.toml`, drift detection, domain scoping),
[sbx-toolkit](https://github.com/maxkrivich/sbx-toolkit) (`.sbx.toml`, layered network policy,
keychain secrets), [streamingfast/sbox](https://github.com/streamingfast/sbox) (`sbox.yaml`,
profiles), [code-sandbox-console](https://github.com/ainova-systems/code-sandbox-console) (VS Code,
`.sandbox/config.yaml`), and several thinner ones catalogued in
[awesome-docker-sbx](https://github.com/ajeetraina/awesome-docker-sbx). All are weeks old and in the
single-to-low-double-digit star range; none is battle-tested by any reasonable meaning of the phrase.

They overlap Draugr on the *config-file* idea and nowhere else. **None of them implements the
sandbox→host git loop, agent memory transfer, or data sync, and none mentions WSL.** That last gap
is the decisive one: `sbx.exe` being absent from WSL's `PATH`, the three-way path translation, and
the git daemon binding Windows loopback where WSL2's NAT cannot reach it are the problems that made
this project worth building, and they are unsolved elsewhere.

**`sbx kit` is a different matter, and it changes this plan.** Kits are a first-party declarative
YAML artifact ([docs](https://docs.docker.com/ai/sandboxes/customize/kits/),
[examples](https://github.com/docker/sbx-kits-contrib)) that a repo can carry as a local directory,
a git ref, or an OCI image. A kit already declares network allow/deny lists, install commands that
run once at creation, startup commands that run every boot, published ports, seeded files,
environment variables, appended agent instructions, and credentials brokered through a host-side
proxy so the secret never enters the microVM. That is most of what Phase 4 was going to reimplement
by driving `sbx policy allow` from shell variables.

**Decision: kits own the inside of the mound, Draugr owns the boundary.** Draugr does not
reimplement anything a kit declares. What remains Draugr's — and is not expressible in a kit,
because a kit runs inside the sandbox and cannot see your machine — is the WSL bridge, the git loop,
host-side preflight (`dr-scan`, the dirty-tree check), memory round-tripping, and data sync.

**Incidental validation:** `--branch` (worktree mode) is gone from v0.37.1, and Docker's release
notes describe migrating their own generated guidance from `--branch` to `--clone`. The three-repo
model in the README is the direction the upstream tool is heading.

---

## Ground rules

These shape every script, so they are stated once here rather than repeated per phase.

1. **One script per verb, in `bin/`, even one-liners.** No hidden framework. `lib/common.sh` holds
   only what is genuinely shared; a script must remain readable in full by someone deciding whether
   to trust it.
2. **`set -euo pipefail` everywhere**, and `IFS=$'\n\t'` where word-splitting matters.
3. **Fail loud and early, with the fix in the error message.** "Not a git repository" is useless;
   "`/mnt/c/src/foo` is not a git repository — run `git init` or cd into your project" is not.
4. **Every destructive action is refused by default** and requires either a clean precondition or
   an explicit `--force`. `dr-rm` is the archetype.
5. **`sbx` stays visible.** Draugr does not abstract over it. Error output names the underlying
   `sbx` command it ran, so a user can reproduce and debug outside Draugr.
6. **Nothing writes outside `$repo`, `~/.config/draugr`, and `$DRAUGR_MEM_STORE`.**

---

## Verified facts the implementation rests on

Checked on this machine (Windows 11 Pro, WSL2/Ubuntu, `sbx` v0.37.1) — not assumed.

| Fact | Consequence |
|---|---|
| `sbx.exe` is **not on WSL's `PATH`**; it lives at `$LOCALAPPDATA/DockerSandboxes/bin/sbx.exe` | `lib/common.sh` must discover it. Cannot just call `sbx`. |
| `sbx` is a Windows binary and its workspace arguments are **Windows paths** (`C:\Code\claude`) | Every path handed to `sbx` needs `wslpath -w`. Every path used inside the mound needs the `/mnt` strip. |
| A workspace is mounted **at the same path** inside the sandbox | `C:\src\p` → `/c/src/p` in the mound → `/mnt/c/src/p` in WSL. Three-way translation is a core primitive. |
| `sbx ls --json` emits `{sandboxes:[{name,id,agent,status,workspaces}]}` | State lookup is a JSON query, not table scraping. Needs `jq`. |
| The `*.sbx` ssh block is already present in WSL `~/.ssh/config` | `dr-setup` must be idempotent and detect the existing managed block rather than duplicating it. |
| `sbx run --name <existing>` re-attaches; the agent is read from the sandbox spec | `dr-go` is create-if-missing then `sbx run --name`. There is no `sbx attach`. |
| `-p/--publish` is **ignored when re-attaching**; `sbx ports` works on a running sandbox | `dr-up` publishes at creation, `dr-ports` afterwards. Two code paths, both needed. |
| `sbx exec -it <name> bash` opens an extra shell; starts a stopped sandbox first | `dr-shell` is a thin wrapper. So is the plumbing behind `dr-cp` and `dr-data`. |
| `sbx policy allow network --sandbox <name> <host>` scopes rules to one sandbox | Per-project allow-lists are real, not aspirational. |
| `sbx skills import` seeds a shared, `sbx rm`-proof store | `dr-skills` wraps it rather than reimplementing it. |
| rsync exists at `/usr/bin/rsync` in the `claude` image; rsync-over-ssh through the ProxyCommand is **incremental** (21-byte append → 375 bytes on the wire) and lands files as `agent:agent` | `DRAUGR_DATA` is viable, and rsync-over-ssh beats `sbx cp` (which lands `root:root`). |
| `sbx kit {validate,pack,add,inspect,push,pull}` exist in v0.37.1; a kit reference may be a **local directory**, ZIP, git ref or OCI image | `.draugr/kit/` can be a plain directory in the repo. No registry, no packaging step. |
| `sbx kit add` **recreates the sandbox container**, preserving kit-owned volumes and (for `--clone`) the workspace volume; refuses on sandboxes created before the feature shipped | Changing the kit mid-session is not free. `dr-up` detects kit drift and tells you rather than silently recreating. |
| Real kits in `sbx-kits-contrib` use `schemaVersion: "1"`, `kind: mixin`, `requires.agent`, `network.{allowedDomains,deniedDomains,publishedPorts}`, `environment.variables`, `commands.{install,startup,initFiles}` | This is the schema `dr-init` generates against. |
| `--branch` / worktree mode is **absent** from v0.37.1 `create` and `run` | Clone mode is the only supported shape. The three-repo model has no competitor to hedge against. |

**Not yet verified — each has a task in the phase that needs it:**

- `sbx create --clone` advertises that commits are reachable via a `sandbox-<name>` remote it adds
  to the host repo. The experiment repo has no such remote, so either it is clone-mode-only or it is
  added elsewhere. Draugr adds its own `ssh://` remote regardless (the auto-remote is presumably the
  unreachable `git://` daemon URL), but we must confirm we are not fighting it. *(Phase 3)*
- `--no-share-skills` is referenced in `sbx skills --help` but is not a flag on `sbx create`.
  Find where skill sharing is actually toggled. *(Phase 6)*
- Whether `sbx run` returns a usable exit status when the agent detaches, and whether Ctrl+D vs
  a detach-key sequence are distinguishable. `DRAUGR_AUTO_SYNC` and `DRAUGR_DATA_PULL=auto` both
  hang off "the moment you detach". *(Phase 2)*
- Whether `kit.allowLocalKits` is enabled by default. Local-directory kits are gated behind it, and
  `.draugr/kit/` is useless if it defaults to off. *(Phase 4 — check first, it is load-bearing.)*
- Which schema version this `sbx` build actually accepts. `sbx-kits-contrib/CONTRIBUTING.md`
  documents a v1→v2 migration (`memory:` → `agentContext:`, `kind: agent` → `kind: sandbox`,
  `agent:` → `sandbox:`) while every shipped example is still `schemaVersion: "1"`. *(Phase 4)*

> **Standing risk: `sbx kit` self-identifies as EXPERIMENTAL — "may change or be removed".** The
> mitigation is that Draugr *generates and validates* a kit but never parses one. `dr-init` writes a
> starter `spec.yaml`, `dr-kit` shells out to `sbx kit validate`, and the file is the user's from
> that point on. If the schema turns over, the blast radius is one template file and one command,
> not the config system.

---

## Decisions to lock before Phase 0

Seven of these. They are cheap now and expensive in Phase 4.

0. **Kits own the inside of the mound.** `DRAUGR_NET_STRICT`, `DRAUGR_NET_ALLOW`, `DRAUGR_NET_DENY`
   and `DRAUGR_BOOTSTRAP` are **removed from the config surface** and replaced by a single
   `DRAUGR_KIT` pointing at a directory — `.draugr/kit/` by default. `dr-init` generates a starter
   `spec.yaml`; `dr-up` passes `--kit`. `dr-policy` survives, demoted to a viewer plus an escape
   hatch for ad-hoc `sbx policy allow` additions on top of the kit's committed baseline, which is
   the split Docker's own documentation describes.

1. **Require `jq`.** It is not currently installed in WSL. The alternative is hand-parsing
   `sbx ls --json` in bash, which is exactly the kind of fragile cleverness this project should not
   contain. `dr-doctor` checks for it and prints `sudo apt install jq`.
2. **Sandbox name defaults to `draugr-<leaf>`,** per the README — not the prototype's
   `claude-<leaf>`. The existing `claude-claude` sandbox is a test artifact, not a migration
   concern. `DRAUGR_SANDBOX` overrides.
3. **Git remote is named `draugr`,** per the README, not the prototype's `sandbox`.
4. **`--clone` is the default and `DRAUGR_CLONE=false` is an interactive confirmation every time,**
   as documented. No config key can silence that prompt; if you want it silent you are outside the
   product's premise.
5. **Config provenance is tracked by sourcing each layer in a subshell** and diffing the resulting
   variable set against the previous layer. Costs four subshells; gives `dr-config` an exact origin
   per key with no bookkeeping in the config files themselves.
6. **Bootstrap-once is the kit's job, not Draugr's.** `commands.install` already runs exactly once,
   at creation, and `sbx` reports each command's outcome during `sbx create`. Draugr's only
   contribution is **kit drift detection**: `dr-up` hashes `.draugr/kit/` and, when it differs from
   the hash recorded at creation, says so and offers `dr-kit apply` — which is `sbx kit add`, and
   therefore a container recreation, so it must be a decision rather than a side effect.

---

## Phase 0 — Skeleton

**Goal:** the repo has the shape the README's *Project layout* section describes, and `dr` runs.

- `bin/dr` — dispatcher: `dr go` → `exec dr-go`, `dr` alone prints the verb table, unknown verb
  suggests the nearest match.
- `lib/common.sh` — output primitives only at this stage: `dr_die`, `dr_warn`, `dr_info`, `dr_ok`,
  `dr_debug` (gated on `DRAUGR_DEBUG`), colour suppressed when not a TTY or `NO_COLOR` is set.
- `install.sh` — symlink or PATH-append, idempotent, prints what it changed.
- `tests/` — bats harness plus a `tests/mocks/` directory holding a fake `sbx` shim, so unit tests
  never touch a real microVM.
- `.github/workflows/ci.yml` — shellcheck over `bin/` and `lib/`, then bats.
- `LICENSE` (MIT), and `.gitignore` gains `tmp` (already there) plus the local config.

**Acceptance:** `./install.sh && dr` prints the verb table; `shellcheck bin/* lib/*.sh` is clean;
`bats tests/` passes with zero tests skipped.

---

## Phase 1 — Config and preflight

**Goal:** every later script can ask "what is my configuration and is this machine sane" in one line.

`lib/common.sh` grows the primitives everything else depends on:

| Function | Responsibility |
|---|---|
| `dr_find_sbx` | `$DRAUGR_SBX` → `command -v sbx.exe` → `$LOCALAPPDATA/DockerSandboxes/bin/sbx.exe` (via `cmd.exe /c echo`) → known WinGet Links path. Cache in `$DRAUGR_SBX`. |
| `dr_sbx` | Invoke it, log the full command line under `DRAUGR_DEBUG`. |
| `dr_repo_root` | `git rev-parse --show-toplevel`, refuse non-repos with a usable message. |
| `dr_path_win` / `dr_path_mound` | `/mnt/c/X` ↔ `C:\X` ↔ `/c/X`. Refuse anything not under `/mnt/<drive>/`, naming the README's rationale. |
| `dr_load_config` | defaults → `~/.config/draugr/config` → `.draugr.conf` → `.draugr.local.conf` → `DRAUGR_*` env → flags, recording provenance per key. |
| `dr_trust_check` | SHA-256 of each project config against `~/.config/draugr/trusted`; refuse to source an unseen one. |
| `dr_sandbox_name` | `$DRAUGR_SANDBOX` or `draugr-<leaf>`, validated against sbx's charset. |
| `dr_sandbox_state` | `sbx ls --json` + jq → `absent|stopped|running`. |
| `dr_hook` | Run `.draugr/hooks/<name>` if executable, with the merged config exported. |

Commands: `dr-config`, `dr-trust`, `dr-doctor`, `dr-setup`, `dr-init`.
Data files: `share/config.example`, `share/project.example`, `share/ssh-config.snippet`,
`share/kit.example/spec.yaml`.

`dr-doctor` checks, in order, each with a specific remedy: WSL2 present · `sbx.exe` found and
version ≥ 0.37 · sandbox daemon reachable · `jq` · `git` ≥ 2.40 · `rsync` on the WSL side · the
`*.sbx` block in **WSL's** `~/.ssh/config` (the trap `dr-setup` exists to fix) · cwd is a git repo
under `/mnt/<drive>/` · project config trusted.

**Acceptance:** `dr-doctor` runs green on this machine and, with `sbx.exe` renamed away, fails with
exactly one error naming the fix. `dr-config` shows every key with its origin file. `dr-init` in a
scratch repo writes a `.draugr.conf` that `dr-config` then reads and attributes correctly.
Path-translation round-trips are bats-tested against a table of cases including spaces and `D:`.

---

## Phase 2 — The mound

**Goal:** create, enter, leave and destroy a sandbox. No policy, no data, no memory yet.

- `dr-up` — create-if-absent (`sbx create --clone --name … --kit … <winpath> <extra mounts>`), start
  if stopped, no attach. Honours `DRAUGR_AGENT`, `DRAUGR_MEMORY`, `DRAUGR_CPUS`, `DRAUGR_TEMPLATE`,
  `DRAUGR_MOUNTS`, `DRAUGR_PORTS` (at creation only), `DRAUGR_CLONE`, `DRAUGR_KIT`. Idempotent —
  running it twice changes nothing and says so. Kit *drift* detection arrives in Phase 4; this phase
  only passes the flag through.
- `dr-go` — `dr-up`, then `sbx run --name`. Enforces `DRAUGR_REQUIRE_CLEAN` beforehand.
- `dr-shell`, `dr-stop`, `dr-ls`, `dr-status` (reduced: state, workspaces, dirty tree — the drift
  columns arrive in Phase 3), `dr-rm` (refuses while unsynced work exists; in this phase that check
  is a stub that always passes, wired up properly in Phase 3).
- The `DRAUGR_CLONE=false` confirmation prompt.

**Verification task:** determine what `sbx run` returns on detach, and whether Ctrl+D is
distinguishable from a detach-key sequence. This decides how `DRAUGR_AUTO_SYNC` fires.

**Acceptance:** in a scratch repo on a Windows drive, `dr-go` creates and enters a mound; Ctrl+D
returns to WSL; `dr-status` reports `running`; `dr-stop` then `dr-go` re-attaches without
re-creating; `dr-rm` removes it. Running `dr-up` twice in a row produces no second sandbox. A dirty
tree blocks `dr-go` with the "the clone only sees commits" explanation.

---

## Phase 3 — Moving code · **the daily loop closes here**

**Goal:** the five-command loop on the front page works.

- `dr-sync` — port `tmp/sbx-sync.sh`: derive the `ssh://<name>.sbx<mound-path>` URL, add-or-set-url
  the `draugr` remote, fetch, report `HEAD..draugr/<branch>`. Runs the `post-sync` hook.
- `dr-log`, `dr-diff` — thin, but real scripts, with sensible defaults (`--stat` for `dr-log`,
  full diff for `dr-diff`) and pass-through of extra git arguments.
- `dr-merge` — merge `draugr/<branch>`, or `--pick <sha>` to cherry-pick. Refuses on a dirty tree.
- `dr-send` — push host commits *into* the mound. Needs care: the sandbox's clone has a checked-out
  branch, so this is a fetch initiated from inside the sandbox, not a push from outside.
- `dr-cp` — pull uncommitted files out, via `sbx cp` with the `root:root` correction, or rsync.
- `dr-status` gains its unfetched-commit and drift columns.
- `DRAUGR_AUTO_SYNC` wired into `dr-go`'s detach path.

**Verification task:** confirm whether `sbx create --clone` adds its own `sandbox-<name>` remote to
the host repo, and that Draugr's `draugr` remote coexists with it.

**Acceptance:** the README's daily loop, executed verbatim against a scratch repo, produces a commit
made inside the mound that ends up merged on the host branch. `dr-sync` on a stopped sandbox starts
it via ssh, as designed. `dr-rm` now genuinely refuses while `HEAD..draugr/main` is non-empty.

---

## Phase 4 — The guards

**Goal:** turn a convenient workflow into a contained one. This is the phase that justifies the name.

Roughly half of what this phase originally contained is now delegated to `sbx kit`. What is left is
the part that must run on *your* machine, where a kit cannot see.

- **First, verify `kit.allowLocalKits`.** Everything below assumes a local `.draugr/kit/` directory
  is loadable. If it defaults to off, the fallback is `dr-kit` packing to a ZIP under
  `~/.local/share/draugr/kits/` — decide before building on it.
- `dr-scan` — walk the repo for `DRAUGR_SCAN_PATTERNS`, reporting **untracked and gitignored** files
  specifically, since those are the ones absent from the clone but readable through
  `/run/sandbox/source`. `DRAUGR_SCAN_FAIL=block` aborts `dr-go`. Purely host-side; nothing in the
  kit format can do this, because the danger is a file that never enters the sandbox's filesystem
  but is visible through the read-only mount.
- `dr-kit` — `validate` (wraps `sbx kit validate`), `show` (the effective network rules), `apply`
  (`sbx kit add`, with the container-recreation consequence stated before it happens), and drift
  detection against the hash recorded at creation.
- `dr-init` gains kit generation: a starter `.draugr/kit/spec.yaml` at `schemaVersion: "1"`,
  `kind: mixin`, `requires.agent: $DRAUGR_AGENT`, with commented `network.allowedDomains` and
  `commands.install` blocks and a pointer to the upstream schema docs.
- `dr-policy` — demoted to a viewer over `sbx policy ls` plus a thin `--allow <host>` for ad-hoc
  additions on a running sandbox. Explicitly documented as *temporary*: the committed kit is the
  durable baseline, and anything you add here should graduate into it.
- `dr-ports` — publish to an already-running sandbox. Kept alongside the kit's
  `network.publishedPorts` because ad-hoc port publishing during a session is a real need and
  editing a kit to open a port would recreate the container.
- The five hooks: `pre-up`, `post-up`, `pre-attach`, `post-sync`, `pre-rm`. These stay — they run on
  the **host**, in WSL, which is precisely what kit commands cannot do.

**Acceptance:** a repo containing an untracked `secrets.env` blocks `dr-go` and names the file. A
kit declaring one allowed domain lets `curl` reach that host inside the mound and fail on another,
with `sbx policy ls` showing the rules scoped to this sandbox and not to `claude-claude`. Editing
`.draugr/kit/spec.yaml` makes the next `dr-up` report drift rather than silently ignoring it.
`dr-kit validate` rejects a deliberately malformed spec with sbx's own error text.

---

## Phase 5 — Moving data

**Goal:** `DRAUGR_DATA` as documented, including the exemption from the clean-tree check.

- `dr-data status|push|pull` — rsync over the `*.sbx` ssh transport, `--chmod=$DRAUGR_DATA_CHMOD`,
  `--delete` only when `DRAUGR_DATA_DELETE=true`, `--dry-run --stats` behind `status` in **both**
  directions.
- Glob expansion: `DRAUGR_DATA` entries are repo-relative and become rsync `--include`/`--exclude`
  rules. This is the fiddly part — `data/**`, `*.parquet` and `fixtures/raw/` are three different
  shapes and rsync's filter rules are not shell globs.
- The `DRAUGR_REQUIRE_CLEAN` exemption: a dirty tree consisting *only* of `DRAUGR_DATA` matches must
  not block `dr-go`.
- `DRAUGR_DATA_PUSH=auto` inside `dr-up`; `DRAUGR_DATA_PULL=auto` on the detach path.
- rsync presence check in the mound at creation, with `apt-get install -y rsync` and a `tar`-over-ssh
  fallback.

**Acceptance:** a repo with a gitignored `data/` tree pushes on `dr-up`; a file the agent writes
comes back on `dr-data pull`; a second push after a small edit transfers kilobytes, not gigabytes
(assert on `--stats`); `dr-go` succeeds with `data/` dirty and still fails with a source file dirty;
files land in the mound owned by `agent` and mode 644.

---

## Phase 6 — Context

**Goal:** the agent remembers, across `dr-rm`.

- `dr-mem export|import|diff` — port `tmp/sbx-memory.ps1` to bash. The whole value is the
  project-key translation (`-mnt-c-src-p` ↔ `-c-src-p` ↔ `c--src-p`) plus the `chown` after
  `sbx cp`. Never touches `~/.claude` itself, only the `memory` subtree.
- `DRAUGR_MEM_SYNC=auto` wired into `dr-up` (import) and the detach path (export).
- `dr-mem import` prints a warning about imported memory being instructions, per the README's safety
  section, and requires confirmation for a store it did not write itself.
- `dr-skills` — wrap `sbx skills import`.
- `dr-rm` gains its "memory not exported" refusal.

**Verification task:** locate the real toggle for skill sharing (`--no-share-skills` is documented in
`sbx skills --help` but is not a `sbx create` flag).

**Acceptance:** memory written by the agent survives `dr-mem export` → `dr-rm` → `dr-go` →
`dr-mem import` and is read by the agent (verified by asking it, not by checking the file exists).
`dr-mem diff` reports a one-file difference when one is introduced.

---

## Phase 7 — Documentation and release

- Split `tmp/SBX-GUIDE.md` into `docs/SETUP.md`, `docs/WORKFLOW.md`, `docs/CONFIG.md`,
  `docs/SECURITY.md`, `docs/TROUBLESHOOTING.md`, with `sbx …` sequences replaced by the `dr-*`
  commands that now exist. `docs/CONFIG.md` is generated-adjacent: every key in
  `share/config.example` must appear in it, checked by a test.
- `dr-code` — VS Code Remote-SSH into the mound.
- Remove every ⏳ from the README, and add a test that fails if a `dr-*` name appears in README.md
  without a matching file in `bin/`.
- Tag v0.1.0.

**Acceptance:** a clean-machine walkthrough — clone, `install.sh`, `dr-setup`, `dr-doctor`,
`dr-init`, `dr-go` — performed against a repo that has never been sandboxed, following only the
docs, with no undocumented step required.

---

## Testing strategy

Two tiers, because most of this cannot be tested without a hypervisor and all of it needs to be
testable in CI.

**Unit (bats, runs anywhere, runs in CI).** `tests/mocks/sbx` is a shim that records its argv to a
file and replays canned `ls --json` output. Everything that is argument construction — and that is
most of Draugr — is tested by asserting on the recorded argv. Path translation, config merge order,
provenance, glob→rsync-filter conversion and trust hashing are all pure functions with table tests.

**Integration (`tests/integration/`, opt-in via `DRAUGR_TEST_LIVE=1`, never in CI).** Creates a real
sandbox against a scratch repo, runs the acceptance check for the phase, and tears down. Guarded so
it refuses to run against a sandbox it did not create.

Every phase's acceptance check above is written as a test before its code.

---

## Deliberately not in v1

Named so nobody has to wonder whether they were forgotten: multi-repo mounds; Linux or macOS hosts
(the whole path story is WSL-specific); running the agent non-interactively for CI; a TUI; anything
that pushes to `origin` on your behalf; and any form of bidirectional data sync, for the reason
given in the README.

---

## Traceability

| README section | Phase |
|---|---|
| Install (`dr-setup`, `dr-doctor`) | 1 |
| Configuration, trust-on-first-use, `dr-config` | 1 |
| The daily loop | 2–3 |
| Lifecycle commands | 2 |
| Moving code | 3 |
| Safety model, `dr-scan`, hooks | 4 |
| Network policy and bootstrap — **delegated to `sbx kit`**, wrapped by `dr-kit` | 4 |
| Working with data files | 5 |
| Context, the project-key trap | 6 |
| Project layout, docs, `dr-code` | 0, 7 |
