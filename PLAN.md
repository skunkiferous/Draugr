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

**This table is the ledger.** If a fact is load-bearing, it belongs in a row here even when it is
also explained in prose elsewhere. That rule exists because it was broken once: the `git://` daemon
being unreachable from WSL was stated in the README's first commit and in the *Prior art* section
above, but never entered as a row — so Phase 2 re-derived it and reported it as a new discovery.
Prose explains; the table is what the implementation is checked against.

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
| **Kit schema v2 is live and v1 is deprecated.** Domains moved to `caps.network.{allow,deny}`; ports moved to a **top-level** `publishedPorts`; `kind: mixin`, `requires.agent`, `environment` and `commands` did not move. v1 spellings still validate but warn on every check | `dr-init` generates `schemaVersion: "2"`. The migration is partial, so "just add caps." is wrong — verified field by field against sbx 0.37.1. |
| A **local directory** is an accepted kit reference: `sbx kit validate .draugr/kit` → `VALID (directory)`, and `--kit <dir>` applies at creation | `.draugr/kit/` works as a plain committed directory. No packing step, no registry, no ZIP fallback. |
| **`sbx` ships a machine-wide `local-policy` of 192 allow rules** applying to *every* sandbox — package managers, OS packages, code hosts, cert validation, AI services, plus read/write-all for the sandbox's own filesystem. A kit's `allow` list **adds to** it | Default-deny is real (`no matching allow rule (default deny)`), but a kit is not the whole allowlist: `github.com` is reachable without any kit mentioning it. `dr-policy --defaults` exists so this is visible rather than surprising. |
| Kit policies are **scoped per sandbox** in `sbx policy ls` (`sandbox:draugr-kit` vs `sandbox:claude-claude`) | Per-project rules are genuinely isolated; `dr-policy --allow` passes `--sandbox` so an ad-hoc hole cannot leak machine-wide. |
| `--branch` / worktree mode is **absent** from v0.37.1 `create` and `run` | Clone mode is the only supported shape. The three-repo model has no competitor to hedge against. |
| The `git://` daemon is published on **Windows loopback** with a **randomised port**, and WSL2 cannot reach it across its NAT — `127.0.0.1` inside WSL is the WSL VM's own loopback. *Known before this plan was written; it is one of the reasons the project exists.* Measured in Phase 2: fetching sbx's remote from WSL gives `Connection refused`, while `ssh://<name>.sbx/<mound-path>` returns refs correctly. | **This is why `DRAUGR_REMOTE` exists** and why `dr-sync` uses `ssh://`. Draugr is not duplicating sbx's remote out of preference — sbx's is unusable from where Draugr runs. |
| The remote sbx adds is named **`sandbox-<name>` under `--clone`**, but plain **`sandbox`** without it | This was the open question, and the answer is that Draugr's own remote cannot collide with it under either name. Nothing to fight. *(Resolved in Phase 2, was flagged for Phase 3.)* |

### The safety model, measured

Every row in the README's *Safety model* table, tested directly in a `--clone` mound built from a
repo containing a committed file, an uncommitted file, and a gitignored `secrets.env`. These were
asserted in prose from the first commit and are entered here because **the entire justification for
`dr-scan` rests on the fifth row.**

| Fact | Consequence |
|---|---|
| The clone contains **committed history only**: `git log` intact, the uncommitted file absent | `DRAUGR_REQUIRE_CLEAN` is not paranoia — the agent genuinely cannot see uncommitted work. |
| `.gitignore`d files are **absent from the clone** | As designed. This is the half that lulls people. |
| The host tree is readable at **`/run/sandbox/source`**, listing *everything* — including the uncommitted and the gitignored files | The read-only mount is a second, wider window onto your repo than the clone is. |
| **A gitignored `secrets.env` was read in full through that mount** (`AWS_SECRET_KEY=hunter2` printed in the clear) | **This is why `dr-scan` exists and why `DRAUGR_SCAN_FAIL=block` is the default.** `.gitignore` hides files from git, not from the filesystem. |
| Writing to `/run/sandbox/source` fails with `Read-only file system`; `/proc/mounts` shows `virtiofs ro,relatime` | The read-only guarantee is kernel-enforced, not convention. Rule 2 of the mental model holds. |
| The agent runs as **uid 1000 (`agent`)**, in groups `sudo` and `docker`, with **passwordless sudo** | `dr-up` can install rsync at creation *(Phase 5)*. Also why `sbx cp`'s `root:root` output is unusable to the agent. |
| `rsync` is at `/usr/bin/rsync` in the `claude` image | Confirms the row above; the `tar` fallback is for other agent images. |
| **Exactly four host paths are mounted into the mound**, per `/proc/mounts`: `/run/sandbox/source` (ro), `/etc/resolv.conf` (ro), `/etc/hosts` (ro), and **`/home/agent/.claude/skills` (rw)** | Containment otherwise holds: `/mnt/c`, `/c/Users`, `/c/Code/claude` (another repo on this machine) and host SSH keys are all absent. |
| **The skills mount is a writable path onto the host.** A file written to `/home/agent/.claude/skills/` inside the mound appeared immediately at `…\DockerSandboxes\sandboxes\state\agent-skills\` on the host | **Corrects the README**, which said the sandbox can never write to the host. The store is shared across *all* sandboxes and survives `sbx rm` by design, so it is a cross-sandbox persistence channel — and skills are instructions loaded into agent context. `dr-scan` lists it; `dr-skills accept`/`diff` make it reviewable. |
| **`--no-share-skills` is real but hidden.** It is absent from `sbx create --help` and `sbx run --help` until `sbx settings set feature.shareSkills true`; the binary carries `feature.shareSkills`, `DOCKER_SANDBOXES_FEATURE_SHARE_SKILLS` and `json:"share_skills"`. Enabling it makes the flag appear on both commands | The `sbx skills --help` text ("use `--no-share-skills` to opt out") describes something a stock install does not have. `dr-skills list` reports which state the machine is in. *(Phase 6 verification task — answered)* |
| **With the feature off — the default — the rw skills mount is there anyway.** `/proc/mounts` shows `/home/agent/.claude/skills virtiofs rw` | So on a stock install no visible CLI switch closes the mound's one write path. *(Phase 6)* |
| **With the feature on, `--no-share-skills` genuinely works.** A sandbox created with it has zero `skills` lines in `/proc/mounts` and no `~/.claude/skills` directory; a sandbox created without it, on the same machine, still has the mount | The flag is hidden, not inert — an earlier draft of the README implied the latter and was wrong. It applies **at creation time only**, so an existing mound must be recreated to lose the mount. *(Phase 6)* |
| sbx feature flags can have source **`remote`** — `feature.ssh` is `enabled:true` from `remote` on this machine, not from any local setting | A flag's value can change without anyone touching this machine, so "the opt-out is unavailable" is a statement about today. `dr-skills list` reads it live rather than caching it. *(Phase 6)* |
| `sbx settings` is an **undocumented top-level command** (absent from `sbx --help`); `sbx settings list --all` reveals the `feature.*` keys | How the above was established. *(Phase 6)* |

### The rest of the boundary

| Fact | Consequence |
|---|---|
| `sbx setup ssh` writes the **Windows** `~/.ssh/config`. Windows and WSL have two separate files; both need the `*.sbx` block | **This is why `dr-setup` exists at all** — the single step people miss. Verified: two distinct files on this machine, each with its own block. |
| Claude Code derives its memory key from the **absolute path**, lowercasing the drive and replacing `:` and separators with `-`. Confirmed on this machine: `C:\Code\Draugr` → `c--Code-Draugr` | The same repo has a different key on each side of the boundary, so `dr-mem` must translate rather than copy. *(Phase 6)* |
| `~/.claude/.credentials.json` exists on the Windows side (524 bytes) and holds the agent auth token | **Never mount `~/.claude`.** `dr-mem` copies the `memory` subfolder explicitly and never the parent. *(Phase 6)* |
| Files on `/mnt/c` are mode **777** under WSL (`stat` confirms on both a file and a directory) | A naive rsync carries 777 into the mound. Hence `DRAUGR_DATA_CHMOD=D755,F644`. *(Phase 5)* |
| `sbx exec <name> true` starts a **stopped** sandbox and returns 0 (~11 s) without attaching | This is `dr-up`'s "start". `sbx run` would also start it, but it attaches, which is `dr-go`'s job. There is no `sbx start`. |
| `sbx run` has `--detached`/`-d`, accepted by the parser but **absent from its own `--help` flag list** | Undocumented, so not depended on. `dr-up` uses `create` + `exec true` instead, both fully documented. |
| Without a TTY, `sbx run` attaches part-way then dies with `inspect exec: context deadline exceeded` | `dr_require_tty` fails first, with a message that names the alternative. |
| `sbx rm` on a clone-mode sandbox reports that fetched branches are mirrored to **`refs/sandboxes/<name>/*`, which survive removal** | Directly relevant to `dr-sync` and to `dr-rm`'s unsynced-work check. *(Phase 3)* |
| Sandbox names reject underscores (`ERROR: sandbox name cannot contain underscores`) | `dr_sandbox_name`'s charset filter is load-bearing, not cosmetic: `my_project` → `draugr-my-project`. |
| **A `subst` drive does not rescue a repo on ext4.** `subst W: \\wsl.localhost\Ubuntu\home\me` succeeds on Windows 11 and `sbx create claude W:\repo` really works in bind-mount mode — the workspace appears at `/w/repo` and its files are readable | But `--clone` refuses it, and clone mode is the entire premise. See the two rows below for why. *(Tested and rejected — see "Deliberately not in v1")* |
| **`subst` is transparent to git, and git rejects the UNC form for dubious ownership.** `git -C W:\repo rev-parse` fails with `detected dubious ownership in repository at '//wsl.localhost/Ubuntu/home/me/repo'` — ownership across the WSL redirector does not match the Windows user. sbx reports this as `--clone requires a Git repository, but W:\repo is not in a Git repository` | sbx's error names the wrong cause, which is worth knowing if anyone hits it for another reason. |
| **Allowing the ownership does not save it either.** With `safe.directory` set, git accepts the path and sbx gets as far as pulling the image, then fails with `500 Internal Server Error: failed to run sandbox container` | The microVM cannot bind-mount a path behind the Windows network redirector. This is the wall, and it is below the level anything Draugr does. |
| **`sbx cp` host paths must be *Windows* paths.** `sbx cp <name>:/tmp/x /home/me/dest` and `… /mnt/c/Code/dest` both fail with `GetFileAttributesEx \home\me: The system cannot find the path specified` — sbx turns the leading `/` into `\` and looks on the current drive. `C:\…` works | `$DRAUGR_MEM_STORE` may sit anywhere, including WSL's ext4 where sbx cannot reach at all, so every `dr-mem` transfer stages through `.draugr/tmp/` in the repo — which `dr_require_win_path` has already guaranteed is on a Windows drive. *(Phase 6)* |
| `sbx cp` **does** report failure by exit code (1 for both a bad destination and a missing source) | The staged copy is still verified afterwards, because "reported success" and "produced a directory" are different claims. *(Phase 6)* |
| sbx's `Sandbox … started successfully` banner goes to **stderr**, not stdout | Listings piped out of the mound are not corrupted by it. `dr-mem` filters to sha256sum's exact shape anyway: one stray stdout line would invent a memory file, and `dr-rm` would then refuse forever over something that does not exist. *(Phase 6)* |
| **The three project-key forms confirmed side by side on one machine**, for one repo: host `c--Code-claude`, mound `-c-Code-claude` | Not inferred from the encoding rule — both directories were listed. `dr_mem_key` is tested against these literals. *(Phase 6)* |
| The mound's agent home is **`/home/agent`**, uid 1000, `sudo -n` works | `dr-mem import` chowns after `sbx cp`, and the live run confirmed the imported file ends up `agent agent` rather than `root root`. *(Phase 6)* |

**Not yet verified — each has a task in the phase that needs it:**

- **Whether `ssh://` starts a *stopped* sandbox by itself.** The README asserts it, and `dr-sync`'s
  ergonomics depend on it — if it does not, `dr-sync` must call `dr-up` first. The Phase 2 run was
  ambiguous: `git ls-remote ssh://…` succeeded and printed `Connecting to sandbox …`, but the
  sandbox's state at that instant was not pinned down, and it was stopped shortly after. Test it
  cleanly: stop a mound, confirm `stopped`, run `git ls-remote`, re-check the state. *(Phase 3 —
  cheap, and it decides one line of `dr-sync`.)*
- Whether Ctrl+D and a detach-key sequence are distinguishable to the caller of `sbx run`. **Mostly
  moot:** Phase 2 settled the part that mattered. `sbx run` is a foreground process, so control
  returns to `dr-go` either way, and `dr-go` syncs on the way out without needing to know which
  happened. Only worth revisiting if `DRAUGR_DATA_PULL=auto` turns out to need the distinction —
  a pull is destructive in a way a fetch is not. *(Phase 5)*

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

**Status: done** (commit `9e94f69`)

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

**Status: done** (commit `9e94f69`)

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
| `dr_sandbox_state` | `sbx ls --json` + jq → `absent` / `stopped` / `running`. |
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

**Status: done** — acceptance verified against real sbx, see below.

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

**Verification task — done.** `sbx run` is a foreground process: control returns to `dr-go` when the
session ends, however it ended, so `DRAUGR_AUTO_SYNC` can simply run afterwards. The state machine
does not need the exit code at all, because `sbx ls --json` reports the truth afterwards. Three
things were learned along the way and are now in the verified-facts table: `sbx exec <name> true` is
how you start a stopped sandbox without attaching, `sbx run` needs a TTY or dies obscurely, and the
remote sbx adds is `sandbox-<name>` under `--clone` but plain `sandbox` without it — which was the
open question, and settles that Draugr's own remote cannot collide with it.

The `git://`-is-unreachable-from-WSL measurement taken here was **not** a discovery: it was known
before this plan was written. It had simply never been entered in the verified-facts table, which is
why it got re-derived. See the note under that table.

**Acceptance — met.** Verified against real sbx in a scratch repo on `C:`: `dr-up` created the mound
(88 s, mostly image pull), a second `dr-up` produced no second sandbox, `dr-status` reported
`running`, `dr-shell -- …` showed the clone at `/c/Temp/…` with its history intact and the host tree
read-only at `/run/sandbox/source`, `dr-stop` then `dr-up` restarted it in 5 s without re-creating,
a dirty tree blocked `dr-go` with the clone explanation, and `dr-rm` removed it. The interactive
attach and Ctrl+D were not machine-testable — `dr-go` refuses without a TTY, which is that path's
guard. 37 bats tests cover the argument construction against the mock.

---

## Phase 3 — Moving code · **the daily loop closes here**

**Status: done** — the loop was executed verbatim against a real mound, see below.

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

**Verification task — done.** `sbx create --clone` does add `sandbox-<name>`, pointing at the
unreachable `git://` daemon; Draugr's `draugr` remote is a separate name with a working `ssh://` URL
and the two coexist without interfering. Also settled: **`ssh://` does start a stopped sandbox** —
measured `stopped` → `git ls-remote` (4.4 s) → `running`, which closes the last open item from
Phase 2 and is what lets `dr-sync` work without calling `dr-up` first.

**Acceptance — met.** Against a real mound: a commit made *inside* the microVM (`implement solver`)
came out through `dr-sync`, was reviewed with `dr-log` and `dr-diff`, and `dr-merge` put it on the
host branch at the same hash with the agent's authorship intact. `dr-send` moved a host commit the
other way through `/run/sandbox/source`, `dr-send --merge` fast-forwarded the clone onto it, and
`dr-cp` pulled an uncommitted file out. `dr-rm` refused while `draugr/main` held unfetched work and
proceeded once it was fetched. 105 bats tests, none skipped.

**One design change against the plan.** `--check-only` returns **three** values, not two: 0 nothing
to lose, 1 unfetched commits exist, **2 could not tell**. Collapsing "unreachable" into 0 would fail
open on the one command that destroys work, and into 1 would make `dr-rm` unusable on a broken
sandbox — which is a common reason to reach for it. `dr-rm` turns a 2 into a warning so the
confirmation prompt is an informed one.

---

## Phase 4 — The guards

**Status: done** — acceptance verified against a real mound, see below.

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
  Second job, from the Phase 2 measurement: **report skills that appeared in the shared store
  without you putting them there.** That store is the only host path a mound can write to, it is
  shared across every mound, it outlives `sbx rm`, and its contents are loaded into agent context as
  instructions. A scan that covers what the agent can *read* but not what it can *leave behind* is
  only half a scan.
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

**Verification task — done, and it changed two things.**

1. **Local kits load.** `sbx kit validate .draugr/kit` → `VALID: .draugr/kit (directory)`, and a
   sandbox created with `--kit <local path>` picks the rules up. The ZIP fallback is not needed.
2. **The schema has moved, and v1 now warns.** `network.allowedDomains` →
   **`caps.network.allow`**, `network.deniedDomains` → `caps.network.deny`, and
   `network.publishedPorts` → a **top-level `publishedPorts`**. The migration is partial and
   non-obvious: domains moved under `caps`, ports moved to the top level, and `commands`,
   `environment`, `kind: mixin` and `requires.agent` did not move at all. `dr-init` now generates
   `schemaVersion: "2"` — v1 still validates, but emits a deprecation warning on every check, and a
   warning you are trained to ignore is worse than no warning.

**Acceptance — met.** A gitignored `secrets.env` blocks `dr-go`, names the file, and explains the
mechanism; `DRAUGR_SCAN_FAIL=warn` downgrades it. `sbx policy ls` shows the kit's rules scoped to
`sandbox:draugr-kit` and separately to `sandbox:claude-claude`. Editing `.draugr/kit/spec.yaml`
makes both `dr-kit drift` (exit 1) and the next `dr-up` report it. `dr-kit validate` rejects a
malformed spec with sbx's own text (`field bogusField not found in type spec.CapsNetwork`).
132 bats tests, none skipped.

**The finding that corrects the README.** The curl half of the acceptance failed in an instructive
way: with a kit allowing only `example.com`, `github.com` was still reachable. Cause — `sbx` ships a
machine-wide `local-policy` of **192 rules** applying to *every* sandbox:

| Rules | Group |
|---|---|
| 56 | `default-package-managers` |
| 35 | `default-cloud-infrastructure` |
| 33 | `default-code-and-containers` |
| 30 | `default-cert-validation` |
| 22 | `default-ai-services` |
| 16 | `default-os-packages` |
| 2 | `default-fs-read-allow-all`, `default-fs-write-allow-all` |

Default-deny is genuinely in force — an unlisted host gives
`Denied: … no matching allow rule (default deny)` — but a kit's `allow` list **adds to** that
baseline rather than replacing it. "Deny by default" and "only what I listed" are different claims,
and the README previously implied the second. Now corrected, and `dr-policy --defaults` exists so
the rules you did not write are one command away rather than invisible.

---

## Phase 5 — Moving data

**Status: done** — acceptance verified against a real mound, see below.

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

**Acceptance — met**, against a real mound with a gitignored `tmp/` tree:

| Criterion | Result |
|---|---|
| pushes on `dr-up` | `DRAUGR_DATA_PUSH=auto` fired during creation, 4 files, 3 MB |
| owned by `agent`, mode 644 | `-rw-r--r-- 1 agent agent 3000000 big.bin` |
| a small edit transfers kilobytes | appended **21 bytes** to a 3 MB file → **7,884 bytes on the wire** |
| the agent's file comes back | `dr-data pull` returned `tmp/out/result.txt` |
| source files untouched | `app.py` appears in neither direction of `dr-data status` |
| `dr-go` tolerates dirty data, not dirty source | unit-tested both ways |

**The bug this phase nearly shipped.** `for entry in $DRAUGR_DATA` performs word splitting *and
pathname expansion*, so `tmp/**` was silently replaced by whatever `tmp/` happened to contain in the
current directory. Run from Draugr's own root it expanded to six real filenames, turning a pattern
into a snapshot of today's files — dependent on the working directory, and blind to anything created
later. `read -ra` splits without globbing and is now used for both consumers. The test caught it
because the filter rules are checked against **real rsync** rather than against a reimplementation
of what rsync is believed to do.

**Filter rules, verified against rsync itself.** Three entry shapes, one recipe:
`--include='*/'` to descend, then the entries, then `--exclude='*'`, with `-m` to prune the empty
directories that the first rule would otherwise leave behind. A trailing `/` needs *two* includes
(the directory and its contents); an entry containing `/` is anchored with a leading `/`; an entry
without one stays unanchored so `*.parquet` matches at every depth. `dr_data_filters` and
`dr_data_matches` sit next to each other in `lib/common.sh` because they must agree — a file that
transfers but still blocks `dr-go` would be a long afternoon.

**Fixed later: unanchored entries reached into `.git`.** Precisely because a slashless entry matches
at every depth, `DRAUGR_DATA="*.sample"` collected git's own `.git/hooks/*.sample`, and
`DRAUGR_DATA="*"` pushed the host's entire `.git` over the mound clone's — replacing the agent's git
metadata, remote and all. Both confirmed against real rsync. `--exclude=.git` and `--exclude=.draugr`
now lead the rule list, since rsync takes the first match, and `dr_data_matches` refuses the same two
so the pair keeps agreeing. Found while working out whether a repo could be a *dummy* one holding
nothing but a `.gitignore` — a mode that would have made `DRAUGR_DATA="*"` the normal case.

---

## Phase 6 — Context ✅

**Goal:** the agent remembers, across `dr-rm`.

- `dr-mem export|import|diff` — port `tmp/sbx-memory.ps1` to bash. The whole value is the
  project-key translation (`-mnt-c-src-p` ↔ `-c-src-p` ↔ `c--src-p`) plus the `chown` after
  `sbx cp`. Never touches `~/.claude` itself, only the `memory` subtree.
- `DRAUGR_MEM_SYNC=auto` wired into `dr-up` (import) and the detach path (export).
- `dr-mem import` prints a warning about imported memory being instructions, per the README's safety
  section, and requires confirmation for a store it did not write itself.
- `dr-skills` — wrap `sbx skills import`, plus `dr-skills list` and `dr-skills diff`. The store at
  `…\DockerSandboxes\sandboxes\state\agent-skills\` is mounted **read-write into every mound**, is
  shared between them, and survives `sbx rm` — so it is the one place a sandbox can leave something
  behind for a later one to read. Skills are instructions, so treat the store as a reviewable
  artifact: show what is there and what changed, do not just push into it.
- `dr-rm` gains its "memory not exported" refusal.

**Verification task:** locate the real toggle for skill sharing (`--no-share-skills` is documented in
`sbx skills --help` but is not a `sbx create` flag).

**Answered: the flag is hidden, not inert.** `--no-share-skills` is absent from `sbx create --help`
until `sbx settings set feature.shareSkills true` — itself an undocumented command, absent from
`sbx --help`. Once revealed the flag does exactly what it says: a sandbox created with it has no
`skills` line in `/proc/mounts` and no `~/.claude/skills` at all, while one created without it on
the same machine still has the mount. All three states measured rather than reasoned about, after a
first draft of the README implied the flag was cosmetic — which was an untested claim dressed as a
finding. It applies at creation time only, so an existing mound must be recreated to lose the
mount. Five rows in the ledger.

**Acceptance:** memory written by the agent survives `dr-mem export` → `dr-rm` → `dr-go` →
`dr-mem import` and is read by the agent (verified by asking it, not by checking the file exists).
`dr-mem diff` reports a one-file difference when one is introduced.

**Shipped surface**, a little wider than the three verbs above: `dr-mem status|export|import|diff|check`
with `--from-host`, `--source` and `--if-empty`, and `dr-skills list|diff|accept|import`. `check` and
`accept` exist because the other verbs needed them — `dr-rm` has to ask a yes/no question without
parsing a report, and "what changed" is meaningless until something records what you have seen.

**Measured, against the real sandbox.** A memory written inside the mound exported to the store,
was deleted from the mound, and came back at the *translated* key — landing as `agent agent`, not
`root root`, so the `chown` does what the ported PowerShell said it must. `dr-mem check` went 1 → 0
across the export and back to 1 when a file changed. `dr-mem diff` reported exactly one difference
per introduced change, in all three categories (only-in-mound, only-in-store, changed).

**One part of the acceptance is not met and is not mine to meet:** "read by the agent, verified by
asking it". Attaching needs a terminal, so the last step is a human one — the files are in the right
place with the right owner, but nobody has yet asked the agent what it remembers. Worth doing once,
because it is the only check that the *key* is right rather than merely self-consistent.

**Two hazards found while wiring `DRAUGR_MEM_SYNC=auto`, both now closed.** Importing on every
`dr-up` would restore the store over memory the agent had since written — the store is by definition
the older copy — so the automatic import is `--if-empty` and only ever fills a mound that has
nothing. And an export always overwrites, so the copy it replaces is kept as `memory.previous`
rather than deleted: one `mv` back if a nearly-empty mound overwrites a full store.

**`off` was a documented value that did nothing.** The README offered `auto|manual|off` while the
code only tested for `auto`, making the last two identical. They now differ: `manual` stops the
automatic transfers but keeps `dr-rm`'s refusal and the `dr-status` section; `off` means you do not
keep agent memory at all, and neither appears.

**Also fixed here, found in passing:** `dr-init` gitignored only `.draugr.local.conf`, while
`lib/common.sh` claimed it also gitignored `.draugr/kit.applied`. It did not — so that file showed
up untracked, and with `DRAUGR_REQUIRE_CLEAN=true` it would have blocked `dr-go` on the second run
of any project with a kit. The list is now checked entry by entry, so a repo initialised by an
older Draugr picks up what it is missing.

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

### Directories that are not repositories — supported, via `DRAUGR_ON_MISSING_REPO`

Measured first: `sbx create` does **not** require a git repository; only `--clone` does, and it says
so plainly (`--clone requires a Git repository, but … is not in a Git repository`). Without
`--clone` a plain directory is bind-mounted read-write and there is no `/run/sandbox/source` — the
agent's write to `report.md` went straight through to the host file. That mode is `DRAUGR_CLONE=false`,
which the README makes you confirm every time, so "just drop the git requirement" means giving up the
property the whole project is built on.

The way out is to keep clone mode and give it a repository to clone. `DRAUGR_ON_MISSING_REPO`:

- `fail` (default) — refuse, naming the two alternatives.
- `create-add-all` — `git init` plus a commit of everything. For "I forgot to `git init`". Seeds
  `.gitignore` from `DRAUGR_SCAN_PATTERNS` and `DRAUGR_DATA` **first**, which is a safety fix and not
  tidiness: `dr-scan` only reports *untracked* files, so committing a credential would put it in the
  agent's clone and in history while silencing the scan that exists to catch it.
- `create-data-only` — `git init` with a `.gitignore` of `*`. Nothing is tracked, so `git status` is
  empty permanently, `DRAUGR_REQUIRE_CLEAN` can never fire, and every file travels by `DRAUGR_DATA`.

Three properties of the data-only repo, each verified with real git: the clone contains only the
committed setup files and none of the user's; the tree is clean and stays clean through edits; and
`git ls-files --others` still lists a `secrets.env`, so `dr-scan` keeps working under a `.gitignore`
of `*`. That last one is luck earned earlier — bare `--others` was chosen in Phase 4 precisely
because it lists ignored files, and it pays off in a mode it was not written for.

**The two modes are not symmetric, and the docs say so.** `create-data-only` is self-sustaining.
`create-add-all` only fixes the first session: the next edit dirties the tree and the discipline
returns — which is correct for a code project and wrong for a folder of documents.

**Two bugs found while building it.** `dr_repo_branch` ran `git rev-parse --abbrev-ref HEAD`, which
exits 128 outside a repository, and `dr_load_config` calls it to default `DRAUGR_BRANCH` — so under
`set -e` the whole command died silently with 128 before any of the new code ran. And `dr-init`
writes `.draugr.conf` and the kit *after* the repository exists, leaving the repo it had just created
dirty; `dr_repo_commit_setup` now commits them, because "the tree is always clean" is the entire
selling point of data-only and breaking it on the very first command would be a poor introduction.

**Deliberately narrow:** only `dr-init` and `dr-up` may create a repository. Every other command
keeps refusing, for the reason `dr-status` will not start a stopped mound — and `dr_context_create`
is separate from `dr_context` so that is enforced by which function a command calls, not by care.
The ordering there is the fiddly part: the policy lives in the config, the config lives in the
directory, and `dr_load_config` must run **exactly once** — a second call would capture the values
the first computed and treat them as environment overrides, outranking every config file.

### Repos on ext4, via a `subst` drive — tested, rejected

The obvious objection to "your repo must live on a Windows drive" is that a WSL path can be *made*
to look like a Windows one:

```cmd
subst W: \\wsl.localhost\Ubuntu\home\me
```

It is a good idea and it very nearly works. Measured end to end, in order:

1. `subst` accepts the UNC path on Windows 11 — it historically did not, so this is worth knowing.
2. `sbx create claude W:\repo` **succeeds** in bind-mount mode. The workspace appears inside the
   mound at `/w/repo` and its contents are readable.
3. `sbx create --clone …` **refuses**: *"requires a Git repository, but `W:\repo` is not in a Git
   repository"* — though it plainly is one.
4. The real cause is not sbx. `subst` is transparent to git, which resolves the drive back to
   `//wsl.localhost/Ubuntu/home/me/repo` and refuses it for **dubious ownership**: file ownership
   across the WSL redirector does not match the Windows user.
5. Add a `safe.directory` exception and git accepts it — then sbx pulls the image and dies with
   `500 Internal Server Error: failed to run sandbox container`. **The microVM cannot bind-mount a
   path behind the Windows network redirector.** That is the wall, and it sits below anything
   Draugr could work around.

So the mode that survives is exactly `DRAUGR_CLONE=false` — a read-write bind mount of your real
tree, the setting the README makes you confirm every single time because it undoes the point of the
project. The mode Draugr is built on is the one that fails.

**And it would not have simplified the code even if it had worked**, which is the part worth
recording, because the appeal of the idea is that it looks like a simplification:

- **Path translation gets worse.** `/mnt/c/x ↔ C:\x` is a deterministic pure function, which is why
  `tests/paths.bats` runs in CI on machines with no WSL at all. A `subst` mapping is machine-local,
  user-created, discovered at runtime, ambiguous in reverse (two letters may map to overlapping
  trees), and absent by default — a new failure mode with a confusing error.
- **The project-key translation is unchanged in size.** Still three forms, just spelled
  `w--repo` / `-home-me-repo` / `-w-repo`.
- **`sbx cp` still demands a Windows path**, so `dr_stage` and its staging hop stay exactly as they
  are.
- **Files still arrive mode 777** over that path, so `DRAUGR_DATA_CHMOD` is still needed.

What it would have bought is not simplicity but **speed**: a repo on ext4 gets native-speed git from
WSL, which is the one genuine cost of the current design. Worth revisiting only if a future `sbx`
can mount a WSL path directly — at which point the win is performance, and the translation code gets
more complicated rather than less.

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
