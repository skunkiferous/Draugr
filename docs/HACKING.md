# Hacking on Draugr

Draugr rests on one idea: you can read a file before you trust it. That is true only if the code is
readable. Thus this page explains the bash constructs that the project uses, and the house rules
that each script follows.

If you write shell only sometimes, this page makes the rest clear. Nothing here is exotic. But you
can write shell for years without some of these.

---

## The shape of every command

Each `bin/dr-*` script starts in the same way:

```bash
#!/usr/bin/env bash
# dr-thing: one line that says what it does.
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
| `#!/usr/bin/env bash` | find bash on `PATH`, and do not assume `/bin/bash` |
| `set -e` | stop at the first command that fails, and do not continue blindly |
| `set -u` | an unset variable is an error, so a typo such as `$nmae` is caught |
| `set -o pipefail` | a pipeline fails if **any** stage failed, not only the last |
| `DR_PROG` | the name in error messages. `common.sh` reads it |
| `${BASH_SOURCE[0]}` | the path of this file. Unlike `$0`, it stays correct when sourced |
| `$(cd … && pwd)` | makes a relative or symlinked path into one absolute form |
| `.` | short for `source`: run that file **in this shell**, so that its functions and variables stay |
| `# shellcheck source=…` | tells the linter where the library is. It cannot find that from a runtime variable |

The comment block after the description **is** the help text. `dr_help "$0"` prints from line 2 to
the first line that is not a comment. Thus the usage is in exactly one place, and cannot drift.

Write the header as one block of `#` lines, with a bare `#` for blank lines, not a truly empty
line. An empty line ends the block. A `# shellcheck` directive also ends it. Thus a file-wide
`disable=` can be in the header (where it must be to apply) without appearing in `--help`.

> This was `sed -n '2,Np' "$0"`, with `N` counted by hand, and `N` was wrong in **17 of 27
> commands**. Each of them ended its `--help` with a stray `set -euo pipefail`. `dr-status` had the
> opposite problem, and stopped in the middle of a sentence. A test now fails if the help of a
> command contains a line of code. It is better to delete this kind of upkeep than to do it right.

---

## Parameter expansion

The `${…}` syntax of bash does much more than put in a value. These six do most of the work in
this code base:

| Written | Means |
|---|---|
| `${VAR:-default}` | `$VAR`, or `default` if it is unset **or empty** |
| `${VAR:+value}` | `value` if `$VAR` is not empty, otherwise nothing |
| `${VAR+set}` | `set` if `$VAR` exists, **also when empty**. The difference is important in `dr_load_config`, where `DRAUGR_PORTS=` means "no ports" on purpose, not silence |
| `${path##*/}` | delete the longest prefix that matches `*/` → `basename` |
| `${path%/*}` | delete the shortest suffix that matches `/*` → `dirname` |
| `${p:5:1}` | substring: one character from offset 5 |

A simple rule: `#` cuts from the front, `%` from the back. Two of them (`##`, `%%`) make the match
greedy.

---

## Indirect expansion, and `printf -v`

This is the one really unusual technique in the project, and only the configuration loader uses
it.

Draugr has 23 configuration keys. One by one, each function that touches the configuration needs a
`case` with 23 branches. In place of that, `DR_KEYS` lists the names, and we read and write
variables *by name*:

```bash
k=DRAUGR_AGENT

echo "${!k}"              # prints $DRAUGR_AGENT's value  - indirect READ
printf -v "$k" '%s' claude  # sets DRAUGR_AGENT=claude    - indirect WRITE
```

`${!k}` means "the value of the variable **named by** `$k`". `printf -v NAME` writes its output
into the variable `NAME`, and does not print it.

With both, `_dr_snapshot_into` copies all 23 keys into a parallel set of `_DR_PREV_*` variables,
then sources a configuration file. `_dr_attribute` then compares the two sets, to find which keys
that file changed. That comparison is the full mechanism behind the "FROM" column of `dr-config`.

---

## `declare -g`, and a bug it caused

```bash
declare -gA DR_ORIGIN=()
```

`-A` makes an associative array (string keys). **`-g` makes it global**, and it is necessary here.

`declare` inside a function creates a *local* variable, and "inside a function" also means sourced
by one. Each bats test calls a helper that sources `common.sh`. Thus without `-g`, the array
disappeared when that helper returned. The later `DR_ORIGIN[DRAUGR_KIT]=…` then hit a normal
*indexed* array, whose subscripts are arithmetic. Bash tried to evaluate the string `.draugr/kit`
as a number:

```
line 314: .draugr/kit: syntax error: operand expected
```

The test suite found this. Normal use did not find it, and does not, until the first time
something sourced the library from inside a function.

---

## `[` versus `[[`

This project uses `[` in all places, except where `[[` is really necessary (pattern matching in
tests). `[` is a command, so its arguments need quotes and spaces between them. `[ -z $x ]` with an
empty unquoted `$x` becomes `[ -z ]`, which is not what you meant. **Quote each variable inside
`[ ]`.**

Common tests:

| | |
|---|---|
| `-f` `-d` `-e` | is a regular file / a directory / exists |
| `-L` | is a symlink (`-e` follows links. `-L` does not) |
| `-s` | exists and is not empty |
| `-x` | is executable |
| `-z` `-n` | string is empty / not empty |
| `-gt` `-eq` | numeric comparison. `=` and `!=` are for strings |

---

## `case` uses globs, not regexes

```bash
case "$p" in
    /mnt/[A-Za-z]/*) : ;;    # `:` is the do-nothing command
    *) return 1 ;;
esac
```

`[A-Za-z]` is one character from that set, and `*` is any run of characters. That is the language
of filename globbing, not regular expressions. `|` separates alternative patterns. The match stops
at the first branch that fits.

Note the difference: the word after `case` is a normal **string**, and the words after `in` are
**patterns**. `case "$path" in` has quotes, because `$path` is data.

### Quoting is what makes something a wildcard

This part catches people, and `dr_data_matches` fully depends on it. Inside a pattern, quoted text
is **literal**, and unquoted text is a **pattern**. One pattern can mix both:

```bash
entry='*.parquet'
case "$p" in  $entry ) …    # unquoted: matches a.parquet, lib/b.parquet, …
case "$p" in "$entry") …    # quoted:   matches ONLY a file called *.parquet
```

Thus a variable that holds a pattern must stay unquoted to work as one. ShellCheck asks about
exactly that with SC2254. That is why the two places that want it have a targeted `disable`, and
are not "fixed".

`dr_data_matches` mixes the two to handle a directory entry:

```bash
case "$path" in "${entry%/}"/*) return 0 ;; esac
```

Three fragments. `"${entry%/}"` has quotes, so it is literal (and `%` removes the trailing slash,
`scratch/raw/` → `scratch/raw`). Then a literal `/`, then an unquoted `*`. The necessary slash makes
`scratch/raw/r1` match, but not `scratch/rawdata/r1`. The quotes mean that a directory called
`odd[name]` is read as the characters that the user typed.
### `*` crosses `/` here, but not when globbing filenames

The same character, two different engines, and the difference is a real surprise:

```bash
ls tmp/*                          # tmp/deep  tmp/x.bin   — stopped at the slash
case tmp/deep/y.bin in tmp/*)     # MATCHES               — crossed it
```

Pathname expansion walks the filesystem one directory at a time, so `*` cannot cross a separator.
`case` is pure string matching, with no disk, so it can. One result to say clearly: in a `case`
pattern, `**` is **the same** as `*`. Draugr still writes `tmp/**`, because rsync gets the same
string, and there the two really are different.

Know the colon idiom in `install.sh`:

```bash
case ":$PATH:" in *":$bindir:"*) ;; esac
```

With `:` around both sides, `/opt/bin` does not match inside `/opt/bin-other`, because the search
is for `:/opt/bin:`.

---

## `set -e` and `&&` chains

`set -e` has an exemption that surprises people. A failed command **inside** an `&&` or `||` chain
does not exit the script. Only a failure of the final command of the chain does. Thus this is
fragile:

```bash
[ -f "$f" ] && [ -n "$(tail -c1 "$f")" ] && printf '\n'   # don't
```

It works, but for a reason that you must work out again each time that you read it. Use an
explicit `if`. `A && B || C` is also not if-then-else. `C` also runs when `A` succeeds and `B`
fails. Thus this project writes those out.

The two forms that *are* idiomatic, and used freely:

```bash
command || return 1          # bail out on failure
[ -f "$f" ] || continue      # skip this loop iteration
```

### The same exemption kills bats assertions, silently

`set -e` is **also** ignored for a command after `!`. In a `.bats` test, that makes an inverted
assertion a no-op. Measured:

| the test | what bats reports |
|---|---|
| `@test "x" { ! true; }` | `not ok`: it fails, correctly |
| `@test "x" { ! true; true; }` | **`ok`**: it passes |
| `@test "x" { false; true; }` | `not ok`: it fails, correctly |

Thus a `! cmd` in the middle of a test finds what it finds, and the test continues. It only seems
to work in the **last** position, where the own exit status of the test carries the failure. That
is why the pattern stayed for so long. The first one that people write is usually the last line.

When we found this, the suite had 59 inverted assertions, and **sixteen** were dead. Two of them
were written on that same day, and had already passed a mutation test that put back the exact bug
that they existed to catch. One of the sixteen was also **wrong**. It searched a full configuration
file for `18445`, but the own comment of the file explains when `18445` is published. We found that
the first time that it was able to fail. An assertion that cannot fail is worse than no assertion,
because the suite reports it as tested.

Thus: an inverted assertion carries its own failure.

```bash
! grep -q nope "$f" || return 1              # do this
! grep -q nope "$f"                          # dead unless it is the last line
run grep -q nope "$f"; [ "$status" -ne 0 ]   # also fine - but it overwrites $output
```

`tests/lint-inverted.sh` enforces it, and accepts each `! cmd || return …` or `! cmd || fail …`.
Search the full file only when you mean the full file. A positive assertion beside the negative one
(`grep -q 'DRAUGR_PORTS="…"'`) is what really fixed the behavior in the case above.

---

## Native stderr under `Stop`

> While `$ErrorActionPreference` is `'Stop'`, do not redirect the stderr of a native command, not
> with `2>$null`, and not with `2>&1`, unless you drop the preference for the call.

PowerShell 5.1 wraps each line that a native command writes to a **redirected** stderr as a
`NativeCommandError`, and `Stop` makes that terminating. Stderr with no redirect passes through with
no harm. Thus the redirect is the full defect.

Measured in the guest, with `Stop` in force and the task absent:

| form | result |
|---|---|
| `schtasks /query /tn draugr-shot /fo list 2>$null` | **threw**: `NativeCommandError` |
| `Get-ScheduledTask -TaskName draugr-shot -ErrorAction SilentlyContinue` | `$null`, no error |

The cost: `install-shot.ps1` asked `schtasks` whether its task already existed, to register it
**only when absent**. `schtasks` writes `ERROR: The system cannot find the file specified.` to
stderr for a task that is not there. Thus the guard whose only job was to find an absence threw
each time that the task was absent, which is **each first install**. The phase reported
`FAILED (1)`, with its two files written and no task registered.

Three files each met this separately, and fixed it in place. `mount-vault.ps1`,
`install-netfx3.ps1` and `install-vscode.ps1` all have their own save and restore, and one has a
comment that explains the full mechanism. Then a fourth file wrote the bug again. **A lesson learned
three times in three files is a rule that does not exist.**

The two fixes, the preferred one first:

```powershell
# 1. Do not ask a native command a question a cmdlet answers.
Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue   # not schtasks /query
Get-Service $n -ErrorAction SilentlyContinue                   # not sc query

# 2. When the native command IS the right tool - and when its stderr is WANTED, which is
#    usually why it was redirected - drop the preference around the call.
$eapWas = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $out = & thing.exe -args 2>&1 } finally { $ErrorActionPreference = $eapWas }
```

`lib/forge/provision.ps1` wraps the second form in `Invoke-Native { … }`. The linter knows it, and
accepts it.

---

## Quoting

Single quotes are literal: nothing expands inside them. Double quotes expand `$var` and `$(cmd)`.
For a literal single quote inside a single-quoted string, close it, escape the quote, and open it
again:

```bash
printf 'echo '\''hello'\''\n'      # outputs: echo 'hello'
```

Use `printf`, not `echo`. The way that `echo` handles `-n`, backslashes and leading dashes is
different between shells and platforms. Use `printf '%s\n' "$x"`, never `printf "$x"`. A `%` in
the data reads as a format specifier.

---

## Pattern: the config cascade

Six layers, and each one can override the layer below it:

```
built-in defaults
  → ~/.config/draugr/config          your machine
    → <repo>/.draugr.conf            the project, committed
      → <repo>/.draugr.local.conf    the project, just you, gitignored
        → DRAUGR_* in the environment
          → command-line flags
```

All of it is in `dr_load_config`, and the code has four labeled steps. Two of them are not clear:

**Draugr keeps environment variables aside, and applies them again.** They must win over the
configuration files. But the files are *sourced into this same shell*, so a source of one
overwrites them. Step 1 copies the values from the environment into `_DR_ENV_*`. Step 4 puts them
back. The test is `${!k+set}`, not `${!k:+set}`, because `DRAUGR_PORTS=` in the environment means
"no ports" on purpose, and must not read as absent.

**The origin of a value is a diff, not bookkeeping.** Before the source of each layer,
`_dr_snapshot_into _DR_PREV_` copies all 23 keys aside. After it, `_dr_attribute` compares them, and
credits the file with each change. Thus a configuration that sets three keys gets the blame for
exactly three. That is the source of the "FROM" column of `dr-config`. It costs nothing in the
configuration files, which stay plain `KEY=value`.

**"You asked for none" is not "you did not ask".** The same difference comes back where a
command-line flag overrides a list value. `dr-go` keeps a separate `args_given` marker, and does
not guess the intent from an empty array:

```bash
--bare) args_given=1; agent_args=() ;;          # explicitly nothing
--)     shift; args_given=1; agent_args=("$@") ;;
...
if [ -z "$args_given" ] && [ -n "$DRAUGR_AGENT_ARGS" ]; then …   # only then fall back
```

Without the marker, you cannot say "ignore the configuration, only this once", because the array is
also empty at the start. Also, the command line **replaces** the configured value, and does not add
to it. That is the same rule as in all other places, and the only way to *drop* a configured
argument.

A new key needs changes in two places: `DR_KEYS` (the list of names) and `_dr_defaults` (the
default value). All else follows from the list: the merge, the origin, `dr-config`, the "no such
setting" error.

The trust test is inside this loop. A project configuration that is not trusted makes the loop
`continue`, and does not stop it. Draugr skips the file, and the run continues with the layers below.

---

## Pattern: the dispatcher

`bin/dr` makes `dr go` into `exec dr-go`. It is a convenience, not an architecture. The `dr-*`
scripts are the real commands, and work alone. That order is on purpose. Keep it:

- **`exec` replaces the process**, and does not start a child. Thus the exit status, the signals and
  the terminal all act as if you typed `dr-go` yourself. That is important for a command that gives
  your terminal to an interactive agent.
- **The list of verbs comes from a glob of `bin/dr-*`**, and is never hard-coded. A new command shows
  in the help of `dr` as soon as its file exists.
- **You can override any one command** with your own `dr-sync` earlier on `PATH`, and the
  dispatcher finds yours. Nothing is registered in any place.

An unknown verb gives near matches by substring, and does not only refuse.

---

## Pattern: agent modules

`sbx` runs ten agents. Almost all that Draugr does is the same for each of them: the attach, the
clone, kits, `dr-sync`, `dr-send`, `dr-data`, the path translation. Three things are different:
where an agent keeps its **memory**, which credential service it signs in through, and whether it
reads the skills store where `sbx` mounts it. That is exactly the knowledge that is most likely to
be wrong. The agents do not document it. It comes from measurement, and it changes with no notice.

Thus it is in `lib/agents/<agent>.sh`, one file for each agent, and not in a `case` statement in
each command that needs it:

```bash
dr_agent_load() {
    local agent=${DRAUGR_AGENT:-claude} file
    file="$DRAUGR_ROOT/lib/agents/$agent.sh"
    [ -f "$file" ] || file="$DRAUGR_ROOT/lib/agents/default.sh"
    . "$file"
}
```

Four facts about it are important:

- **`lib/agents/default.sh` is the interface.** It is not a stub. An agent that nobody measured
  gets it, and its answer to "where is the memory" is an honest failure, not a guess.
  `tests/agents.bats` reads the function names from it, and fails if a different module omits one.
- **Each module must define each function.** A source of a second module redefines only the
  functions that it defines. Thus a partial module leaves the answers of the *previous* agent in
  place. The interface test exists to catch that bug. It puts the memory path of Claude into a
  Codex session, with nothing on screen.
- **It loads two times.** Once at the bottom of `lib/common.sh`, so that a command that never reads
  a configuration (`dr-skills`, `dr-setup`) still has the functions. Again at the end of
  `dr_load_config`, and that load decides. A value from the cascade selects the module. Thus an
  earlier load reads the agent from the wrong layer.
- **Modules take paths as arguments, never `$HOME`.** A module that looks inside the mound does it
  through `dr_mound_sh`, whose scripts are single-quoted and run there. A `$HOME` in the script text
  expands on the *host*.

To add an agent: copy `default.sh`, fill in the layout, and add a case to `tests/agents.bats`.
`dr_agent_known` finds it in the directory list, so there is no list to update.

---

## Pattern: mocking `sbx` and `ssh`

Almost all that Draugr does is to *build a command line* for a Windows binary that needs a
hypervisor. `tests/mocks/sbx` stands in for it. It adds its argv to `$DR_MOCK_LOG`, and replays a
fixed `ls --json` output, shaped by `$DR_MOCK_STATE`. Tests then assert on the recorded argv.

`tests/mocks/ssh` does the same for the attach. It logs with an `ssh` prefix, so that the same
`calls` helper finds it in the one log. Know two things when you write tests against it. The
command line of the agent arrives in base64 inside the rcfile. Thus tests decode it, and do not
assert on the wrapper. The decoded string is what the bash of the mound really runs. And `git` also
fetches over `ssh://`. Thus a test that cares *which* connections happened needs
`DRAUGR_AUTO_SYNC=false`, or `head -1`, because the attach is always the first connection of a
session.

Thus the rule is: **keep the decisions separate from the call.** Put the flags into a variable or
array, then call `dr_sbx` once with them. A function that computes and calls in one step cannot be
tested without a microVM.

There is a second requirement that people easily miss. Each mound command refuses a repo that is not
under `/mnt/<drive>/`, so a test needs a repo on such a path. `dr_make_win_repo` gives one. In WSL,
that is the real `C:` drive. In CI, it is a plain directory that the workflow creates, because the
test is pure string matching, with no hypervisor. Where neither is possible, the tests `skip`.

**A green result hides a skip.** Thus CI looks for skips in the run, and fails the job if it finds
any. If not, a `/mnt/c` that silently became read-only makes the mound tests into no-ops, and
nothing says so.

### Standing in for the mound's git repository

The commands in `tests/sync.bats` talk to `ssh://<name>.sbx/<path>`, and a test has no sandbox. The
tests do not add a test-only override to the production code. They use **the own URL rewrite of
git**:

```bash
git config "url.$fake.insteadOf" "ssh://$name.sbx$mound"
```

git then silently sends that exact URL to a local clone. All else is real: a real `git fetch`, real
ref names, a real commit count. `bin/dr-sync` has no branch that exists only for tests.
`dr_fake_mound` in `tests/helper.bash` sets this up. `dr_mound_commit` then commits there, as the
agent does.

This caught two things that a mock did not. `git remote get-url` applies the rewrite. Thus
assertions on the configured URL must read `git config remote.draugr.url`. It also caught the
exit-status bug in `--check-only`, where an unreachable mound reported success.

### Standing in for the mound's filesystem

`dr-mem` moves *files*, not commits. Thus it needed the same treatment one layer down. With
`DR_MOCK_MOUND` set, `exec` and `cp` in the mock really run, against a directory on the host.

- `exec` moves each **absolute argument** into that tree, and runs the rest as written. The script
  itself goes through unchanged. It is for the shell of the mound, and a rewrite inside it needs a
  parse of it.
- `cp` has the own behavior of sbx, also the rule that a host path must be a *Windows* path. The
  mock converts `C:\…` back to `/mnt/c/…` **on its own**, and does not call `dr_path_win`. That is
  the purpose. If the translation under test is wrong, the mock cannot find the file. Two matching
  bugs do not agree with each other.

`dr_mound_memory_dir` sets it up. As `dr_fake_sbx_root` does, it *sets* variables, and does not
print them. `$(…)` is a subshell, and throws the `export` away. That mistake is worth making only
once.

The benefit: the project-key translation really runs. The file must go under `-c-Code-…` for the
test to find it. A wrong key gives a missing file, not a passing assertion about a string.

---

## Pattern: the mound commands

`dr-up`, `dr-go`, `dr-shell`, `dr-stop`, `dr-rm` and `dr-status` all start with `dr_context`. It
resolves the repo, refuses it if it is not on a Windows drive, and loads the configuration cascade:

```bash
dr_context      # sets DR_REPO, DR_REPO_WIN; fills in DRAUGR_* and DR_ORIGIN
```

Two results follow from that, and both already caused bugs:

- **`dr-up` owns the state machine, and no other command has it.** `absent` → `sbx create`,
  `stopped` → `sbx exec <name> true`, `running` → nothing. `dr-go` runs `dr-up` as a *separate
  process*, and does not copy the logic. That also keeps `dr-up --print` a true preview of what
  `dr-go` does.
- **Creation flags become fixed at creation.** `sbx` puts ports, memory, template and kit into the
  sandbox spec. If you change one in your configuration and run `dr-up` again, nothing happens until
  you recreate the sandbox. That is why `--recreate` exists, and why the header comment of `dr-up`
  says so clearly.

To start a stopped sandbox, run `sbx exec <name> true`. There is no `sbx start`, and `sbx run`
attaches, which is the job of a different command.

---

## Pattern: the git loop, and which direction is which

Three repositories, and the transport is different in each direction. This explains most of
`bin/dr-sync`, `bin/dr-send` and `bin/dr-cp`.

**Out of the mound: `ssh://`, never `git://`.** `sbx` adds its own remote, which points at a git
daemon on `127.0.0.1`. From WSL, that is the loopback of *the WSL VM*, not of Windows. A fetch from
it gives `Connection refused`. Thus Draugr adds its own remote, `$DRAUGR_REMOTE`, at
`ssh://<name>.sbx/<mound path>`. That crosses no NAT, needs no port, and starts a stopped sandbox on
connect. That is the full reason for `DRAUGR_REMOTE`. It is not a duplicate.

**Into the mound: not a push at all.** The clear `git push` fails. The clone has that branch checked
out, and git refuses to update it from outside. Thus `dr-send` runs the transfer from the *inside*,
as a fetch from the read-only host mount:

```bash
sbx exec <name> git -C <clone> fetch /run/sandbox/source main:refs/remotes/host/main
```

No network, no daemon, no ssh, because the host repository is already mounted there. It arrives as
a remote-tracking ref, not a branch. Thus nothing in the working tree of the agent changes.

**Neither, for uncommitted files.** `dr-cp` wraps `sbx cp`, which writes into the mound as
`root:root`, while the agent is uid 1000. Thus Draugr changes the owner of each file that it copies
*in*. If not, the agent can read it, but never change it.

One rule follows from all this: **`dr-status` must not fetch.** A connection to the mound starts a
stopped one, and a status command with side effects is a trap. It reports from local refs, and
says "as of your last dr-sync". Thus it states that the data can be old.

---

## Pattern: reports go to stdout, diagnostics to stderr

`dr_info`/`dr_ok`/`dr_warn`/`dr_error`/`dr_heading` all write to **stderr**, so that the real
output of a command stays usable in a pipe. The other side of this is easy to get wrong: **if the
full purpose of a command is output, all of it belongs on stdout**, also its headings.

`dr-status` got this wrong the first time. It printed headings with `dr_heading` (stderr), and rows
with `printf` (stdout). On a terminal, it looked fine. In a pipe, the two streams had separate
buffers, and `repo` showed *above* its `repository` heading. `dr-status` now defines its own local
`heading()`, which writes to stdout. A regression test captures only stdout, and tests the order.

Thus: `dr_heading` is for interactive prompts, such as the file review of `dr-trust`. A report
defines its own.
## Pattern: one list, two syntaxes

Two things read `DRAUGR_DATA`, and they speak different languages: rsync filter rules (`dr-data`)
and shell glob matching (the clean-tree exemption in `dr-go`). They must agree. If not, a file
transfers correctly and *still* blocks `dr-go`, which makes for a very confusing afternoon. Thus
both readings are together in `lib/common.sh`, with the three entry shapes documented once:

| Entry | Means | `case` form | rsync form |
|---|---|---|---|
| `scratch/raw/` | that directory and all under it | `"${entry%/}"/*` | two rules: the dir and `/**` |
| `tmp/**` | a pattern, anchored at the repo root | `$entry` unquoted | `--include=/tmp/**` |
| `*.parquet` | a bare name, matched at **any** depth | `$entry` against the basename | unanchored `--include=*.parquet` |

*Quoting is what makes something a wildcard*, above, explains the `case` column. In short, quoted
fragments are literal, unquoted ones are patterns, and `dr_data_matches` mixes both on purpose.

The rsync recipe is `--include='*/'` to go down, then the entries, then `--exclude='*'`, with `-m`
to remove the empty directories that the first rule leaves. The order is important, because rsync
takes the *first* matching rule.

**A split of the list globs it, if you let it.** This looks right, but is not:

```bash
for entry in $DRAUGR_DATA; do …      # don't
```

Unquoted expansion does word splitting **and pathname expansion**. Thus `tmp/**` becomes the
contents of `tmp/` in the current directory. A pattern silently becomes a snapshot of the filenames
of today. It changes with `$PWD`, and does not see files that are created later. Use `read -ra`,
which splits on `IFS`, and does not glob:

```bash
read -ra entries <<< "$DRAUGR_DATA"  # do
```

This got as far as the test suite before somebody caught it. That happened only because the filter
rules are tested against **real rsync**, not against a copy of what we assume that rsync does. When
the language belongs to somebody else, test against their implementation.

---

## Pattern: a process that outlives the command that started it

`dr-dep up` leaves a **warden** running. That is one process for each running dependency. It holds
the session that stops `sbx` from stopping an idle mound after 30 s. It counts claims, so that the
last user can turn off the lights. It is the first part of Draugr that continues to run after the
command returns. A correct detach of it needs three things, not one.

```bash
setsid "$_dr_bin/dr-dep" warden "$name" --sandbox "$name" --linger "$lingering" \
    </dev/null >>"$(dr_dep_dir "$name")/warden.log" 2>&1 &
```

1. **`setsid`**, so that it is not in the process group of the caller, and does not die with the
   terminal that started it.
2. **A redirect of all three standard streams**: stdin from `/dev/null`, and both outputs to a log
   beside its pid file. A daemon with no place to write blocks on a full pipe.
3. **The child itself closes each descriptor above stdio that it got from its parent.** People
   easily miss this one:

   ```bash
   for _fd in /proc/self/fd/*; do
       case "${_fd##*/}" in 0|1|2|255) continue ;; esac
       eval "exec ${_fd##*/}>&-" 2>/dev/null || true
   done
   ```

   A redirect of 0, 1 and 2 says nothing about fd 3. Under `bats`, the warden got a pipe that the
   test runner read, and a handle on its output file. Thus a suite that printed each result still
   hung until something killed it. The tests passed, but the run did not finish. 255 is the own
   copy of the script of bash, and a close of it kills the shell.

**The pid file is a claim, not a fact.** Draugr tests `warden.pid` with `kill -0` before it starts
another, as it tests a claim against the live state, and does not believe it. An old pid file means
that nothing runs. That is a state to recover from, not an error.

**Decide in which direction it fails, and say so.** If the warden dies, the mound stays up, and the
next `dr-up` starts another warden. Nothing stops something that is in use. Each long-lived helper
that you add later must select the same direction.

---

## Two traps that cost real time

Draugr did not cause either one, and both are silent.

**A comment that starts with the word "shellcheck" becomes a directive.** This is a parse error, not
a warning:

```bash
# read -ra splits on whitespace, rather than leaving it to word splitting, which
# shellcheck (rightly) complains about
```

ShellCheck sees `# shellcheck (rightly)...`, tries to parse it as `# shellcheck disable=...`, and
reports SC1073/SC1072 at the comment. Change the words, so that the line does not *start* with the
name of the tool.

**The `@tsv` of `jq` escapes backslashes.** Each workspace that Draugr handles is a Windows path,
and `@tsv` makes `C:\Code` into `C:\\Code`. `dr-ls` uses `join("\t")`, which is safe here, because
none of those fields can contain a tab. Use `@tsv` only when the data cannot contain a backslash.

---

## When you add a pattern, document it here

This file is necessary, not decoration. The README tells reviewers to read it before any script. If
you add something structural (a new layer, a new lifecycle hook, a new way for commands to talk to
each other), add a short section here, in the same style: what it is, why, and the one result that
is not clear.

The test for whether it belongs here: *is a reader of a single script confused, because the answer
is in a different file?* If yes, it goes here.

---

## House rules

1. **One script for each verb**, also for single lines. A reader must be able to read one behavior
   without a framework.
2. **Each fatal error names the fix.** `dr_die` takes a message, then fix lines. "Not a git
   repository" makes the user search. "run `git init`, or cd into your project" does not.
3. **Diagnostics go to stderr** (`>&2`), so that the real output of a command stays usable in a pipe.
   `dr_info`/`dr_warn`/`dr_die` do this for you.
4. **Destructive actions refuse by default.** They need a clean condition or an explicit `--force`.
5. **`sbx` stays visible.** Draugr does not hide it. Error messages name the `sbx` command that ran,
   so that you can repeat the problem without Draugr.
6. **Internal helpers have the `_dr_` prefix.** Draugr sources the `.draugr.conf` of a project into
   our shell. Without the prefix, its variables can collide with ours.
7. **Nothing is written outside** the repo, `~/.config/draugr`, `$DRAUGR_MEM_STORE`, and
   `${XDG_STATE_HOME:-~/.local/state}/draugr` for run-state. The last one is separate from the
   configuration directory on purpose. Claims and warden pids can be deleted freely, are never worth
   a backup, and mean nothing on a different machine. In `~/.config/draugr`, they make that
   directory unsafe to copy.
8. **A new structural pattern gets a section in this file**, in the same change that adds it. Refer
   to *When you add a pattern* above.
9. **No block of more than five lines of code without a comment.** `tests/lint-comments.sh` enforces
   it, and the section below explains it.
10. **An inverted bats assertion carries its own failure**: `! cmd || return 1`. In any place except
    the last line of a test, a bare `! cmd` cannot fail. `tests/lint-inverted.sh` enforces it, and
    *`set -e` and `&&` chains* explains it.
11. **In a PowerShell script with `$ErrorActionPreference = 'Stop'`, do not redirect the stderr of a
    native command.** Each line that it writes becomes a terminating error.
    `tests/lint-native-stderr.sh` enforces it, and *Native stderr under `Stop`* explains it.
12. **A test that searches a source file removes the comments first, and anchors the pattern.** The
    own comment of a fix names the thing that the fix removed, because that is the job of comments.
    Thus a search with no filter matches the explanation, not the code, and passes on a file whose
    behavior was reverted. A name with no anchor matches a renamed one as a prefix. This happened
    **five** times here. Each time, a revert of the fix and a new run of the test caught it, and a
    read of the test never did. A new test is not finished until somebody saw it fail.

---

## The comment-density rule

> Each block of more than **five** lines of code must contain at least one comment line.

A "block" is a run of consecutive lines that are not blank. Thus a doc comment directly above a
function counts as the comment of that function, which is usually where it belongs. With a blank
line between them, they become two blocks, and the code half then needs its own comment. In
practice, the rule means: **every few lines, say what the next few lines are for.**

This is stricter than most projects want, on purpose. The full argument of Draugr is that you can
read a file before you trust it. "The code is self-documenting" is a reasonable position in a code
base that nobody must audit. It is not reasonable here.

Two things do not count as code, because you cannot comment inside them, and a demand for comments
there makes no sense: **heredoc bodies**, which are data, and blank lines. Blank lines explain
nothing, so they also do not reset the count.

Only **full-line** comments count. A trailing `# like this` is fine to write, and often the
clearest option, but it does not satisfy the checker. That way, the rule stays mechanical, with no
room for argument.

```bash
./tests/lint-comments.sh              # everything CI checks - use this form
MAX=8 ./tests/lint-comments.sh …      # relax it while refactoring
```

Run it with **no arguments**. The file list is in the script, so that a local run tests exactly
what CI tests. Before, the workflow listed the files. Then a bare local run silently tested nothing.
That is a green result that means less than no result.
CI runs it on each push. If it fires on a block where a comment really adds nothing, that usually
means that a blank line must split the block. Do not pad it with prose.

---

## Working on Draugr

Draugr puts the projects of other people in a sandbox, and it can do the same for itself. That is
the recommended way to work on it. `dr-go` in your clone builds a mound, whose agent edits a clone
of your clone. Your checkout is mounted **read-only**, and the kernel enforces that. The only writes
that it ever gets are the merges that you accept through `dr-sync` and `dr-diff`.

`dr-init` writes `.draugr.conf` and `.draugr/kit/spec.yaml` (commit both), and adds three entries
to `.gitignore`: `.draugr/kit.applied`, `.draugr/create.applied` and `.draugr/tmp/`. Those are not
tidiness. With `DRAUGR_REQUIRE_CLEAN=true`, an untracked state file **blocks `dr-go`**. Thus a repo
without them stops working the first time that Draugr builds a mound.

**The full suite runs in there**, because none of it needs a hypervisor. CI proves that, because it
runs all 983 tests on Ubuntu, with no sbx, no Windows and no WSL. The suite needs two things that
the mound does not have by default:

- `bats`, `jq` and `shellcheck`, installed from the `commands.install` of the kit. Remember the
  rule for each kit: install commands run **before** the repository is in the workspace, so they
  cannot read a file from it.
- a writable `/mnt/c`. `dr_win_root` looks for `/mnt/c/Temp`, then `/mnt/c`. With neither, each
  mound test **skips**, and does not fail. `sudo mkdir -p /mnt/c/Temp && sudo chmod 1777
  /mnt/c/Temp` fixes it, and the agent user has sudo with no password. CI does exactly this, for
  exactly this reason.

### What cannot happen in a mound

A mound has no `sbx`, no `powershell.exe` and no WSL interop. Thus three things need a host:

- **The ten `forge-api.bats` tests**, which need a real `powershell.exe`, but **not** a real
  AppSandbox. The daemon that they talk to is `tests/appsandbox_mock.py`. Thus any Windows machine
  works, with no VM.
- **Live runs of `dr-forge` and `dr-layer`**, which need AppSandbox on a Windows 11 host with
  `VirtualMachinePlatform` enabled. This one cannot be avoided. The code controls a hypervisor, and
  nobody can test it without one.
- **The live tier** in [Testing strategy](#testing-strategy), which needs a real mound, and thus a
  real sbx.

All else runs in any place: the code, the 983 tests, the lints, shellcheck.

### Keep a live run off your own configuration

The live tier runs Draugr code *with no review* on a host, as you. That is part of the design, not a
fault. Draugr exists to act on the host, so a test of it must run there. Two habits make it cheap:

- **`DRAUGR_CONFIG_HOME=$(mktemp -d)`** moves the user configuration, the trust store and the kit
  library to a disposable place. Thus a live run cannot damage the configuration that you work with.
  Run state is separate, and follows `XDG_STATE_HOME`. Thus redirect both if a test claims
  dependencies. Neither is in `DR_KEYS`. They are development tools, not part of the configuration
  surface. That is why `dr-config` does not list them, and `CONFIG.md` does not document them.
- **Point live verbs at a test repository** under `/mnt/<drive>/Temp`, never at a real project. The
  own fixtures of the suite do exactly that, and `dr_win_root` finds a place for one.

---

## Running the checks

```bash
sudo apt install jq shellcheck bats     # jq is a runtime dependency; the others are for development

shellcheck --external-sources --shell=bash lib/common.sh lib/agents/*.sh lib/forge/*.sh \
    install.sh tests/mocks/* bin/* .githooks/* tests/executable-paths.sh \
    share/ollama-proxy/ollama-proxy
./tests/lint-comments.sh                # the comment-density rule, below
./tests/lint-inverted.sh                # `! cmd` assertions that cannot fail
./tests/lint-native-stderr.sh           # native stderr that `Stop` would make fatal
bats -j 8 tests/                        # -j 8 takes the suite from ~280s to ~70s
```

All five must be clean before a commit, and CI runs exactly these.

The shellcheck list is written out here, because `.github/workflows/ci.yml` writes it out, and the
two already drifted once. The workflow got `lib/agents/`, `.githooks/` and `share/ollama-proxy/`,
while this line still named four paths. Thus the clear local command silently tested less than CI
did. It drifted a second time when the forge arrived: `lib/forge/*.sh` and two of the three lint
scripts were in the workflow, but not here. The same failure, the same result. Thus when you change
either one, compare this block with the other. Between changes, the globs keep it honest. A new
command, mock or hook is covered, and nobody needs to remember it. `./tests/lint-comments.sh` takes
no arguments, for the reason in its own header.

There are **no** shellcheck exclusions on the command line. What looks like unused variables (the
`DRAUGR_*` configuration surface, `DR_ORIGIN`, and the values that a `dr-*` command reads back from
`common.sh`) has a targeted `# shellcheck disable=SC2034` at the place of use. Thus the test stays
live for real typos in all other places.

`tests/mocks/sbx` and `tests/mocks/ssh` stand in for the real binaries. They record their argv, and
the sbx mock replays a fixed `ls --json` output. Thus tests can assert on the command line that
Draugr built, with no hypervisor near them.

### Enable the commit hook, once per clone

```bash
git config core.hooksPath .githooks
```

Without it, each new script that you add is committed as mode `100644`, and arrives on Linux as a
file that nothing can run. That is not carelessness. Here, it cannot be avoided. The project is
developed on `/mnt/c`, where git sets `core.fileMode=false`, and fully ignores the executable bit of
the filesystem. Thus `chmod +x` changes nothing that git records, and `git add` cannot carry the bit
either. The mode is **only** in the index, and only `git update-index --chmod=+x` writes it there.

`.githooks/pre-commit` does that for you, for each path in `tests/executable-paths.sh`, and says
which files it touched. It fixes, and does not refuse, because there is nothing to judge. A file is
on that list exactly because something runs it.

`tests/repo.bats` still fails the build when a mode is wrong. The hook is the convenience, and the
test is the guarantee. A new clone that never ran `git config` is still caught. But the test runs
after the commit, and CI even later. Both are too late to be a reminder. This cost one red release,
and ten commits of `tests/mocks/ssh` at `100644`. During that time, the attach tests silently found a
**real** `ssh` on the runner, because the PATH look-up skips a file that is not executable, and
continues to search. It does not fail.

### The runner is not this machine

Three bugs that passed here and failed there came from the same place. The tests run on Ubuntu, with
a recent toolchain. We write them under WSL on `/mnt/c`, with the toolchain of that distribution.

- **File modes.** `core.fileMode=false` on `/mnt/c` fully hides a wrong mode until CI. The commit
  hook above exists for that.
- **The version of git.** Since git 2.49, `git fetch` creates `refs/remotes/<remote>/HEAD` by
  default. On git 2.43, that ref never shows. Thus the wrong skip of it in `dr_other_branches` was
  invisible here, and failed three tests on each push. Know the `git --version` of the runner before
  you spend an afternoon on a test that passes locally.

- **The own path of the checkout.** A repository on `/mnt/c` has a Windows spelling. In any other
  place, it needs the UNC form, and that needs `WSL_DISTRO_NAME`, which WSL exports, and which is
  unset on a runner. `dr-forge gateway` probed the Windows side before the dispatch, failed to spell
  `lib/forge/probe.ps1`, and failed 24 of the 25 tests of `forge-gateway.bats` on each CI run for
  four days, while all 983 passed here. Both conditions are true on a development machine, and
  neither is true on the runner. Thus no local run was able to see it.

When CI does not agree with a local run, **copy the runner, and do not guess**. A `git clone` into
the own filesystem of WSL, with `WSL_DISTRO_NAME` unset and Windows interop off `PATH`, is different
from a working checkout in all three ways above, and takes a minute. For the bug above, three guesses
came before that try.

The lesson for tests, not for code: when the thing under test is a state that some *other* version
makes, build that state in the test, and do not provoke it. The regression tests for that ref call
`git symbolic-ref` directly. Thus they fail on the buggy code with both git versions. A test that
fails only where the bug is already visible tells you nothing new.

---

## Testing strategy

Two tiers, because most of this cannot run without a hypervisor, and CI must be able to test all of
it.

**Unit (bats, runs in any place, runs in CI).** The tests assert on the argv that the mock recorded
for all *argument construction*, and that is most of Draugr. Path translation, the merge order and
origin of the configuration, the glob→rsync-filter conversion, the project-key encoding and trust
hashing are pure functions, with table tests. Where the language belongs to somebody else, the tests
run against their implementation, not against what we believe about it. The `DRAUGR_DATA` filters
run through **real rsync**, and the repo-creation modes through **real git**. That is the only reason
why we found the `.git`-over-the-clone bug and the pattern-globbing bug.

**Live (against a real sandbox, never in CI).** We did the acceptance test of each phase by hand,
against a real mound: we created one, measured `/proc/mounts`, sent memory both ways, and timed an
rsync delta. The results are in [DESIGN.md](DESIGN.md) and [SECURITY.md](SECURITY.md), not only in
the terminal history of a person. When a claim in the docs says "measured", that is what it means.

Three rules that came from mistakes:

1. **A test that passes for the wrong reason is worse than no test.** One scan test passed because
   it hit the clean-tree test first, and thus tested nothing. When a guard test passes, make sure
   that it fails when you break the thing.
2. **A test that examines nothing reports success.** The comment linter exited 0 on an empty file
   list. The exec-bit guard read `git ls-files`, which lists only tracked files. Thus it never saw
   the untracked script that broke CI. Ask what the test must see to fail.
3. **A green result hides a skip.** CI searches the bats output for skips, and fails the job on each
   reason that it does not know. The mound tests skip without a writable `/mnt/<drive>`, and are
   otherwise a silent no-op. Two reasons are allowed. Both say that the runner is not Windows,
   because `forge-api.bats` cannot run real PowerShell there. The allowlist holds *reasons*, not
   files. Thus a new kind of skip in that same file still fails the build.
