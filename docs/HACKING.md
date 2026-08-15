# Hacking on Draugr

Draugr's premise is that you can read a file before you trust it. That only holds
if the code is actually readable, so this page explains the bash constructs the
project leans on and the house rules every script follows.

If you write shell occasionally, this is the page that makes the rest make sense.
Nothing here is exotic — but several of these are things you can write shell for
years without needing.

---

## The shape of every command

Each `bin/dr-*` script opens the same way:

```bash
#!/usr/bin/env bash
# dr-thing - one line saying what it does.
#
#   dr-thing            usage examples, which --help reprints
set -euo pipefail

DR_PROG=dr-thing
_dr_bin=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "$_dr_bin/../lib/common.sh"
```

Line by line:

| | |
|---|---|
| `#!/usr/bin/env bash` | find bash on `PATH` rather than assuming `/bin/bash` |
| `set -e` | stop at the first failing command instead of blundering on |
| `set -u` | an unset variable is an error, so a typo'd `$nmae` is caught |
| `set -o pipefail` | a pipeline fails if **any** stage failed, not just the last |
| `DR_PROG` | what error messages call themselves; `common.sh` reads it |
| `${BASH_SOURCE[0]}` | this file's path — unlike `$0` it stays right when sourced |
| `$(cd … && pwd)` | collapses a relative or symlinked path to one absolute form |
| `.` | short for `source`: run that file **in this shell**, so its functions and variables stick around |
| `# shellcheck source=…` | tells the linter where the library is; it cannot work that out from a runtime variable |

The comment block after the description is reprinted by `--help` (via
`sed -n '2,9p' "$0"`), so usage lives in exactly one place.

---

## Parameter expansion

Bash's `${…}` syntax does far more than substitute a value. These six carry most
of the weight in this codebase:

| Written | Means |
|---|---|
| `${VAR:-default}` | `$VAR`, or `default` if it is unset **or empty** |
| `${VAR:+value}` | `value` if `$VAR` is non-empty, otherwise nothing |
| `${VAR+set}` | `set` if `$VAR` exists **even when empty** — the distinction matters in `dr_load_config`, where `DRAUGR_PORTS=` is a deliberate "no ports" rather than silence |
| `${path##*/}` | delete the longest prefix matching `*/` → `basename` |
| `${path%/*}` | delete the shortest suffix matching `/*` → `dirname` |
| `${p:5:1}` | substring: one character starting at offset 5 |

Rule of thumb: `#` trims from the front, `%` from the back; doubling it
(`##`, `%%`) makes the match greedy.

---

## Indirect expansion, and `printf -v`

This is the one genuinely unusual technique in the project, and it is confined to
the config loader.

Draugr has 23 settings. Handling them one by one would mean a 23-branch `case` in
every function that touches configuration. Instead `DR_KEYS` lists the names, and
we read and write variables *by name*:

```bash
k=DRAUGR_AGENT

echo "${!k}"              # prints $DRAUGR_AGENT's value  - indirect READ
printf -v "$k" '%s' claude  # sets DRAUGR_AGENT=claude    - indirect WRITE
```

`${!k}` means "the value of the variable **named by** `$k`". `printf -v NAME`
writes its output into the variable `NAME` instead of printing it.

Together they let `_dr_snapshot_into` copy all 23 settings into a parallel set of
`_DR_PREV_*` variables, source a config file, and then let `_dr_attribute`
compare the two sets to work out which keys that file changed. That comparison is
the whole mechanism behind `dr-config`'s "FROM" column.

---

## `declare -g`, and a bug it caused

```bash
declare -gA DR_ORIGIN=()
```

`-A` makes an associative array (string keys). **`-g` makes it global** — and it
is not optional here.

`declare` inside a function creates a *function-local* variable, and "inside a
function" includes being sourced by one. Every bats test calls a helper that
sources `common.sh`, so without `-g` the array vanished when that helper
returned. The later `DR_ORIGIN[DRAUGR_KIT]=…` then hit an ordinary *indexed*
array, whose subscripts are arithmetic, and bash tried to evaluate the string
`.draugr/kit` as a number:

```
line 314: .draugr/kit: syntax error: operand expected
```

The test suite found this; nothing in normal use would have, until the first time
something sourced the library from inside a function.

---

## `[` versus `[[`

This project uses `[` throughout, except where `[[` is genuinely needed (pattern
matching in tests). `[` is a command, so it needs its arguments quoted and
separated by spaces; `[ -z $x ]` with an empty unquoted `$x` becomes `[ -z ]`,
which is not what you meant. **Quote every variable inside `[ ]`.**

Common tests:

| | |
|---|---|
| `-f` `-d` `-e` | is a regular file / a directory / exists at all |
| `-L` | is a symlink (`-e` follows links; `-L` does not) |
| `-s` | exists and is non-empty |
| `-x` | is executable |
| `-z` `-n` | string is empty / non-empty |
| `-gt` `-eq` | numeric comparison; `=` and `!=` are for strings |

---

## `case` uses globs, not regexes

```bash
case "$p" in
    /mnt/[A-Za-z]/*) : ;;    # `:` is the do-nothing command
    *) return 1 ;;
esac
```

`[A-Za-z]` is one character from that set and `*` is any run of characters — the
same language as filename globbing, not regular expressions. `|` separates
alternative patterns. Matching stops at the first branch that fits.

Note the asymmetry: the word after `case` is an ordinary **string**, the words
after `in` are **patterns**. `case "$path" in` is quoted because `$path` is data.

### Quoting is what makes something a wildcard

This is the part that catches people, and `dr_data_matches` depends on it
entirely. Inside a pattern, quoted text is **literal** and unquoted text is a
**pattern** — and one pattern can mix both:

```bash
entry='*.parquet'
case "$p" in  $entry ) …    # unquoted: matches a.parquet, lib/b.parquet, …
case "$p" in "$entry") …    # quoted:   matches ONLY a file called *.parquet
```

So a variable holding a pattern must be left unquoted to work as one — which is
exactly what ShellCheck's SC2254 asks about, and why the two places that want it
carry a targeted `disable` rather than being "fixed".

Mixing the two is how `dr_data_matches` handles a directory entry:

```bash
case "$path" in "${entry%/}"/*) return 0 ;; esac
```

Three fragments: `"${entry%/}"` is quoted so it is literal (with `%` trimming the
trailing slash, `scratch/raw/` → `scratch/raw`), then a literal `/`, then an
unquoted `*`. The mandatory slash is what makes `scratch/raw/r1` match while
`scratch/rawdata/r1` does not, and the quoting means a directory called
`odd[name]` is taken as the characters the user typed.

### `*` crosses `/` here, but not when globbing filenames

Same character, two different engines, and the difference is genuinely
surprising:

```bash
ls tmp/*                          # tmp/deep  tmp/x.bin   — stopped at the slash
case tmp/deep/y.bin in tmp/*)     # MATCHES               — crossed it
```

Pathname expansion walks the filesystem one directory at a time, so `*` cannot
span a separator. `case` is pure string matching with no disk involved, so it
can. One consequence worth stating out loud: in a `case` pattern `**` is
**identical** to `*`. Draugr writes `tmp/**` anyway because the same string is
handed to rsync, where the two really do differ.

The colon-wrapping idiom in `install.sh` is worth knowing:

```bash
case ":$PATH:" in *":$bindir:"*) ;; esac
```

Wrapping both sides in `:` stops `/opt/bin` from matching inside
`/opt/bin-other`, because the search is for `:/opt/bin:`.

---

## `set -e` and `&&` chains

`set -e` has an exemption that surprises people: a failing command **inside** an
`&&` or `||` chain does not exit the script, only a failure of the chain's final
command does. That makes this fragile:

```bash
[ -f "$f" ] && [ -n "$(tail -c1 "$f")" ] && printf '\n'   # don't
```

It works, but for a reason you have to reconstruct each time you read it. Prefer
an explicit `if`. `A && B || C` is likewise not if-then-else — `C` also runs when
`A` succeeds and `B` fails — so this project spells those out.

The two forms that *are* idiomatic and used freely:

```bash
command || return 1          # bail out on failure
[ -f "$f" ] || continue      # skip this loop iteration
```

---

## Quoting

Single quotes are literal — nothing expands inside them. Double quotes expand
`$var` and `$(cmd)`. To get a literal single quote inside a single-quoted string
you have to close, escape, and reopen:

```bash
printf 'echo '\''hello'\''\n'      # outputs: echo 'hello'
```

Prefer `printf` to `echo`: `echo`'s handling of `-n`, backslashes and leading
dashes varies between shells and platforms. Use `printf '%s\n' "$x"`, never
`printf "$x"` — a `%` in the data would be read as a format specifier.

---

## Pattern: the config cascade

Six layers, each able to override the one below it:

```
built-in defaults
  → ~/.config/draugr/config          your machine
    → <repo>/.draugr.conf            the project, committed
      → <repo>/.draugr.local.conf    the project, just you, gitignored
        → DRAUGR_* in the environment
          → command-line flags
```

All of it lives in `dr_load_config`, and the implementation is four labelled
steps. Two are not obvious:

**Environment variables are stashed and re-applied.** They have to outrank config
files, but the files are *sourced into this same shell*, so sourcing one would
overwrite them. Step 1 copies anything already in the environment into
`_DR_ENV_*`; step 4 puts it back. The check is `${!k+set}`, not `${!k:+set}`,
because `DRAUGR_PORTS=` in the environment is a deliberate "no ports" and must
not be mistaken for absence.

**Provenance is a diff, not bookkeeping.** Before sourcing each layer,
`_dr_snapshot_into _DR_PREV_` copies all 23 settings aside; afterwards
`_dr_attribute` compares and credits whatever changed to that file. So a config
that sets three keys gets the blame for exactly three. That is where
`dr-config`'s "FROM" column comes from, and it costs nothing in the config files
themselves — they stay plain `KEY=value`.

**"You asked for none" is not "you did not ask".** The same distinction turns up
again wherever a command-line flag overrides a list-valued setting. `dr-go` keeps
a separate `args_given` marker rather than inferring intent from an empty array:

```bash
--bare) args_given=1; agent_args=() ;;          # explicitly nothing
--)     shift; args_given=1; agent_args=("$@") ;;
...
if [ -z "$args_given" ] && [ -n "$DRAUGR_AGENT_ARGS" ]; then …   # only then fall back
```

Without the marker there is no way to say "ignore what the config wants, just
this once", because the empty array is also what you start with. Note too that
the command line **replaces** the configured value rather than appending to it —
same rule as everywhere else, and the only way to *drop* a configured argument.

Adding a setting means touching two places: `DR_KEYS` (the list of names) and
`_dr_defaults` (the default value). Everything else — merging, provenance,
`dr-config`, the "no such setting" error — follows from the list.

The trust check sits inside this loop. An untrusted project config `continue`s
rather than aborting: it is skipped and the run carries on with the layers below.

---

## Pattern: the dispatcher

`bin/dr` turns `dr go` into `exec dr-go`. It is a convenience, not an
architecture — the `dr-*` scripts are the real commands and work standalone. That
ordering is deliberate, and worth preserving:

- **`exec` replaces the process** rather than spawning a child, so exit status,
  signals and the terminal all behave as if you had typed `dr-go` yourself. That
  matters for a command that hands your terminal to an interactive agent.
- **The verb list is derived by globbing `bin/dr-*`**, never hard-coded. A new
  command appears in `dr`'s help the moment its file exists.
- **You can override any single command** by putting your own `dr-sync` earlier
  on `PATH`, and the dispatcher will find yours. Nothing is registered anywhere.

An unknown verb suggests near matches by substring rather than just refusing.

---

## Pattern: mocking `sbx`

Almost everything Draugr does is *building a command line* for a Windows binary
that needs a hypervisor. `tests/mocks/sbx` stands in for it: it appends its argv
to `$DR_MOCK_LOG` and replays canned `ls --json` output shaped by `$DR_MOCK_STATE`.
Tests then assert on the recorded argv.

So the rule is: **keep the decisions separate from the invocation.** Work out
flags into a variable or array, then call `dr_sbx` once with them. A function
that computes and invokes in the same breath cannot be tested without a microVM.

There is a second requirement that is easy to miss: every mound command refuses
a repo that is not under `/mnt/<drive>/`, so a test needs a repo on such a path.
`dr_make_win_repo` provides one. In WSL that is the real `C:` drive; in CI it is
a plain directory the workflow creates, because the check is pure string matching
and no hypervisor is involved. Where neither is possible the tests `skip`.

**A skip is invisible in a green tick**, so CI checks the run for skips and fails
the job if it finds any. Otherwise a `/mnt/c` that quietly stopped being writable
would turn the mound tests into no-ops and nothing would say so.

### Standing in for the mound's git repository

The commands in `tests/sync.bats` talk to `ssh://<name>.sbx/<path>`, and there is
no sandbox in a test. Rather than adding a test-only override to the production
code, the tests use **git's own URL rewriting**:

```bash
git config "url.$fake.insteadOf" "ssh://$name.sbx$mound"
```

git then transparently redirects that exact URL to a local clone. Everything else
is genuine — a real `git fetch`, real ref names, real commit counting — and
`bin/dr-sync` contains no branch that exists only for tests. `dr_fake_mound` in
`tests/helper.bash` sets this up; `dr_mound_commit` then commits there the way
the agent would.

Two things this caught that a mock would not have: `git remote get-url` applies
the rewriting (so assertions on the configured URL must read
`git config remote.draugr.url` instead), and the exit-status bug in
`--check-only` where an unreachable mound reported success.

### Standing in for the mound's filesystem

`dr-mem` moves *files* rather than commits, so it needed the same treatment one
layer down. Setting `DR_MOCK_MOUND` makes the mock stop pretending: `exec` and
`cp` really run, against a directory stationed on the host.

- `exec` rewrites every **absolute argument** into that tree and runs the rest
  verbatim. The script itself is passed through untouched — it is meant for the
  mound's shell, and rewriting inside it would mean parsing it.
- `cp` implements sbx's own semantics, including that a host path must be a
  *Windows* path. The mock converts `C:\…` back to `/mnt/c/…` **independently**
  of `dr_path_win` rather than by calling it. That is the point: if the
  translation under test is wrong, the mock cannot find the file, instead of two
  matching bugs agreeing with each other.

`dr_mound_memory_dir` sets it up. Like `dr_fake_sbx_root` it *sets* variables
rather than printing them — `$(…)` is a subshell and would throw the `export`
away, which is a mistake worth making only once.

The payoff is that the project-key translation is exercised for real: the file
has to land under `-c-Code-…` for the test to find it, and a wrong key produces a
missing file rather than a passing assertion about a string.

---

## Pattern: the mound commands

`dr-up`, `dr-go`, `dr-shell`, `dr-stop`, `dr-rm` and `dr-status` all begin with
`dr_context`, which resolves the repo, refuses it if it is not on a Windows
drive, and loads the config cascade:

```bash
dr_context      # sets DR_REPO, DR_REPO_WIN; fills in DRAUGR_* and DR_ORIGIN
```

Two things follow from that, and both have bitten already:

- **`dr-up` owns the state machine, and nobody else implements it.** `absent` →
  `sbx create`, `stopped` → `sbx exec <name> true`, `running` → nothing. `dr-go`
  runs `dr-up` as a *separate process* rather than duplicating the logic, which
  is also what keeps `dr-up --print` a truthful preview of what `dr-go` will do.
- **Creation flags are frozen at creation.** `sbx` bakes ports, memory, template
  and kit into the sandbox spec; changing one in your config and re-running
  `dr-up` does nothing until the sandbox is recreated. That is why `--recreate`
  exists, and why the header comment of `dr-up` says so out loud.

Starting a stopped sandbox is `sbx exec <name> true` — there is no `sbx start`,
and `sbx run` would attach, which is a different command's job.

---

## Pattern: the git loop, and which direction is which

Three repositories, and the transport is different in each direction. Getting
this straight explains most of `bin/dr-sync`, `bin/dr-send` and `bin/dr-cp`.

**Out of the mound — `ssh://`, never `git://`.** `sbx` adds its own remote
pointing at a git daemon on `127.0.0.1`, and from WSL that is *the WSL VM's*
loopback, not Windows'. Fetching it gives `Connection refused`. So Draugr adds
its own remote, `$DRAUGR_REMOTE`, at `ssh://<name>.sbx/<mound path>`, which
crosses no NAT, needs no port, and starts a stopped sandbox on connect. That is
the whole reason `DRAUGR_REMOTE` exists; it is not duplication for its own sake.

**Into the mound — not a push at all.** The obvious `git push` fails: the clone
has that branch checked out and git refuses to update it from outside. `dr-send`
therefore runs the transfer from the *inside*, as a fetch from the read-only host
mount:

```bash
sbx exec <name> git -C <clone> fetch /run/sandbox/source main:refs/remotes/host/main
```

No network, no daemon, no ssh — the host repository is already mounted there. It
lands as a remote-tracking ref rather than a branch, so nothing in the agent's
working tree is disturbed.

**Neither, for uncommitted files.** `dr-cp` wraps `sbx cp`, which writes into the
mound as `root:root` while the agent is uid 1000 — so anything copied *in* gets
chowned afterwards, or the agent could read it and never modify it.

One rule falls out of all this: **`dr-status` must not fetch.** Reaching the
mound starts a stopped one, and a status command with side effects is a trap. It
reports from local refs and says "as of your last dr-sync" so the staleness is
stated rather than implied.

---

## Pattern: reports go to stdout, diagnostics to stderr

`dr_info`/`dr_ok`/`dr_warn`/`dr_error`/`dr_heading` all write to **stderr**, so
that a command's real output stays pipeable. The corollary is easy to get wrong:
**if a command's whole purpose is output, all of it belongs on stdout** — including
its headings.

`dr-status` got this wrong first time round. It printed headings with
`dr_heading` (stderr) and rows with `printf` (stdout). On a terminal it looked
fine; the moment it was piped, the two streams buffered independently and
`repo` appeared *above* the `repository` heading it belonged under. `dr-status`
now defines its own local `heading()` that writes to stdout, and there is a
regression test that captures stdout alone and checks the ordering.

So: `dr_heading` is for interactive prompts, like `dr-trust`'s file review.
A report defines its own.

---

## Pattern: one list, two syntaxes

`DRAUGR_DATA` is read by two things that speak different languages — rsync filter
rules (`dr-data`) and shell glob matching (the clean-tree exemption in `dr-go`).
They must agree, or a file transfers correctly and *still* blocks `dr-go`, which
is a genuinely confusing afternoon. So both interpretations live together in
`lib/common.sh`, with the three entry shapes documented once:

| Entry | Means | `case` form | rsync form |
|---|---|---|---|
| `scratch/raw/` | that directory and everything under it | `"${entry%/}"/*` | two rules: the dir and `/**` |
| `tmp/**` | a pattern, anchored at the repo root | `$entry` unquoted | `--include=/tmp/**` |
| `*.parquet` | a bare name, matched at **any** depth | `$entry` vs the basename | unanchored `--include=*.parquet` |

The `case` column is explained under *Quoting is what makes something a
wildcard* above; the short version is that quoted fragments are literal and
unquoted ones are patterns, and `dr_data_matches` mixes both on purpose.

The rsync recipe is `--include='*/'` to descend, then the entries, then
`--exclude='*'`, with `-m` to prune the empty directories the first rule leaves.
Order matters: rsync takes the *first* matching rule.

**Splitting the list will glob it if you let it.** This looks right and is not:

```bash
for entry in $DRAUGR_DATA; do …      # don't
```

Unquoted expansion does word splitting **and pathname expansion**, so `tmp/**`
is replaced by whatever `tmp/` contains in the current directory — a pattern
silently becomes a snapshot of today's filenames, varying with `$PWD` and blind
to anything created later. Use `read -ra`, which splits on `IFS` and does not
glob:

```bash
read -ra entries <<< "$DRAUGR_DATA"  # do
```

This shipped as far as the test suite before being caught, and only because the
filter rules are tested against **real rsync** rather than against a
reimplementation of what rsync is assumed to do. When the language is someone
else's, test against their implementation.

---

## Two traps that cost real time

Neither is Draugr's doing, and both are silent.

**A comment that begins with the word "shellcheck" becomes a directive.** This
is a parse error, not a warning:

```bash
# read -ra splits on whitespace, rather than leaving it to word splitting, which
# shellcheck (rightly) complains about
```

ShellCheck sees `# shellcheck (rightly)...` and tries to parse it as
`# shellcheck disable=...`, then reports SC1073/SC1072 pointing at the comment.
Reword so the line does not *start* with the tool's name.

**`jq`'s `@tsv` escapes backslashes.** Every workspace Draugr handles is a
Windows path, and `@tsv` turns `C:\Code` into `C:\\Code`. `dr-ls` uses
`join("\t")` instead, which is safe here because none of those fields can
contain a tab. Reach for `@tsv` only when the data cannot contain a backslash.

---

## When you add a pattern, document it here

This file is load-bearing, not decoration: the README tells reviewers to read it
before any script. If you introduce something structural — a new layer, a new
lifecycle hook, a new way commands talk to each other — add a short section here
in the same style: what it is, why, and the one non-obvious consequence.

The test for whether it belongs: *would someone reading a single script be
confused because the answer lives in a different file?* If yes, it goes here.

---

## House rules

1. **One script per verb**, even one-liners. You should be able to read a single
   behaviour without reading a framework.
2. **Every fatal error names the fix.** `dr_die` takes a message followed by
   remedy lines. "Not a git repository" is a search; "run `git init`, or cd into
   your project" is not.
3. **Diagnostics go to stderr** (`>&2`) so a command's real output stays
   pipeable. `dr_info`/`dr_warn`/`dr_die` handle this for you.
4. **Destructive actions refuse by default** and need either a clean
   precondition or an explicit `--force`.
5. **`sbx` stays visible.** Draugr does not hide it; error messages name the
   `sbx` command that ran so you can reproduce the problem without Draugr.
6. **Internal helpers are `_dr_`-prefixed.** A project's `.draugr.conf` is
   sourced into our shell, so its variables could otherwise collide with ours.
7. **Nothing is written outside** the repo, `~/.config/draugr`, and
   `$DRAUGR_MEM_STORE`.
8. **A new structural pattern gets a section in this file**, in the same turn
   that introduces it. See *When you add a pattern* above.
9. **No block of more than five lines of code without a comment.** Enforced by
   `tests/lint-comments.sh`, and explained below.

---

## The comment-density rule

> Any block of more than **five** lines of code must contain at least one comment
> line.

A "block" is a run of consecutive non-blank lines. So a doc comment sitting
directly above a function counts as that function's comment — usually where it
belongs. Put a blank line between them and they become two blocks, and the code
half then needs its own comment. In practice the rule means: **every few lines,
say what the next few lines are for.**

This is stricter than most projects would want, and deliberately so. Draugr's
whole argument is that you can read a file before you trust it. "The code is
self-documenting" is a reasonable position in a codebase nobody is being asked to
audit; it is not one here.

Two things are not counted as code, because you cannot comment inside them and
demanding it would be nonsense: **heredoc bodies**, which are data, and blank
lines, which explain nothing and so do not reset the count either.

Only **full-line** comments count. A trailing `# like this` is fine to write and
often the clearest option, but it does not satisfy the checker — the rule stays
mechanical and unarguable that way.

```bash
./tests/lint-comments.sh              # everything CI checks - use this form
MAX=8 ./tests/lint-comments.sh …      # relax it while refactoring
```

Run it with **no arguments**. The file list lives in the script so that a local
run checks exactly what CI checks; it used to be spelled out in the workflow,
and the bare local invocation quietly checked nothing at all, which is a green
tick that means less than no tick.

CI runs it on every push. If it fires on a block where a comment genuinely adds
nothing, that is usually a sign the block wants splitting with a blank line
rather than padding with prose.

---

## Running the checks

```bash
sudo apt install jq shellcheck bats     # jq is a runtime dependency; the others are for development

shellcheck --external-sources --shell=bash lib/common.sh install.sh tests/mocks/sbx bin/*
bats tests/
```

Both must be clean before a commit. CI runs exactly these, with **no**
shellcheck exclusions — the two legitimately-unused-looking variables carry
targeted `# shellcheck disable=SC2034` comments instead, so the check stays live
for real typos.

`tests/mocks/sbx` stands in for the real binary: it records the argv it was
called with and replays canned `ls --json` output, so tests can assert on the
command line Draugr built without a hypervisor anywhere near them.

---

## Testing strategy

Two tiers, because most of this cannot be exercised without a hypervisor and all
of it has to be checkable in CI.

**Unit (bats, runs anywhere, runs in CI).** Everything that is *argument
construction* — and that is most of Draugr — is tested by asserting on the argv
the mock recorded. Path translation, config merge order and provenance,
glob→rsync-filter conversion, project-key encoding and trust hashing are pure
functions with table tests. Where someone else's language is involved, the tests
go against their implementation rather than our belief about it: the
`DRAUGR_DATA` filters run through **real rsync**, and the repo-creation modes
through **real git**. That is the only reason the `.git`-over-the-clone bug and
the pattern-globbing bug were ever found.

**Live (against a real sandbox, never in CI).** Each phase's acceptance check was
performed by hand against a real mound — creating one, measuring `/proc/mounts`,
round-tripping memory, timing an rsync delta — and the results recorded in
[DESIGN.md](DESIGN.md) and [SECURITY.md](SECURITY.md) rather than left in
someone's terminal history. When a claim in the docs says "measured", that is
what it means.

Three rules that came out of getting this wrong:

1. **A test that passes for the wrong reason is worse than no test.** One scan
   test passed because it tripped the clean-tree check first, testing nothing.
   When a guard test goes green, confirm it goes red when you break the thing.
2. **A check that examines nothing reports success.** The comment linter exited 0
   on an empty file list; the exec-bit guard read `git ls-files`, which lists only
   tracked files, and so never saw the untracked script that broke CI. Ask what
   the check would have to see to fail.
3. **A skip is invisible in a green tick.** CI greps the bats output for skips and
   fails the job if it finds any, because the mound tests skip without a writable
   `/mnt/<drive>` and would otherwise turn into a silent no-op.
