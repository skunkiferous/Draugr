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

**A skip is invisible in a green tick**, so CI re-runs `tests/mound.bats` and
fails the job if anything skipped. Otherwise a `/mnt/c` that quietly stopped
being writable would turn 37 tests into 37 no-ops and nothing would say so.

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
./tests/lint-comments.sh lib/common.sh install.sh bin/* tests/mocks/sbx
MAX=8 ./tests/lint-comments.sh …      # relax it while refactoring
```

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
