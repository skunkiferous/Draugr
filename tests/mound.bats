#!/usr/bin/env bats
# The mound lifecycle: dr-up, dr-go, dr-shell, dr-stop, dr-rm, dr-ls, dr-status.
#
# Nothing here starts a hypervisor. tests/mocks/sbx records the command line it
# was handed and replays canned `ls --json`, so what these tests actually assert
# is that Draugr builds the right sbx invocation from a given config - which is
# the part with all the path translation in it, and therefore all the bugs.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1

    # dr_sandbox_name derives this from the folder, and the mock has to agree or
    # dr_sandbox_state will report "absent" no matter what DR_MOCK_STATE says.
    SANDBOX="draugr-$(basename "$REPO")"
    export DR_MOCK_NAME="$SANDBOX"
}

teardown() { dr_test_teardown; }

# The recorded argv for one subcommand, e.g. calls create -> the create line.
# tests/mocks/ssh logs under "ssh", so `calls ssh` picks the attaches out of the
# same file.
calls() { grep "^$1 " "$DR_MOCK_LOG" || true; }

# True if anything attached, by either transport. Used where the point is that
# nothing did - a check refused before the agent could start - which would
# otherwise quietly stop meaning anything the day the default transport changes.
attached() { [ -n "$(calls run)$(calls ssh)" ]; }

# --- dr-up: the state machine -----------------------------------------------

@test "dr-up: absent creates, with --clone by default" {
    DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    [[ "$(calls create)" == *"--name $SANDBOX"* ]]
    [[ "$(calls create)" == *"--clone"* ]]
    [[ "$(calls create)" == *"claude"* ]]
}

@test "dr-up: stopped starts via 'exec true' and does not create" {
    DR_MOCK_STATE=stopped run dr-up
    [ "$status" -eq 0 ]
    [[ "$(calls exec)" == *"$SANDBOX true"* ]]
    [ -z "$(calls create)" ]
}

@test "dr-up: running is a no-op" {
    DR_MOCK_STATE=running run dr-up
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running"* ]]
    [ -z "$(calls create)" ]
    # "no-op" means it neither builds nor starts anything. It is not "runs no
    # commands at all": DRAUGR_MEM_SYNC=auto looks inside the mound on every
    # dr-up, which is an exec. The start is the specific one that must be absent.
    [[ "$(calls exec)" != *"$SANDBOX true"* ]]
}

@test "dr-up: twice in a row creates only one sandbox" {
    DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    # The mock has no memory, so the second run is told the sandbox now exists -
    # which is exactly what the real sbx would report.
    DR_MOCK_STATE=running run dr-up
    [ "$status" -eq 0 ]
    [ "$(calls create | wc -l)" -eq 1 ]
}

# --- dr-up: turning config into a command line -------------------------------

@test "dr-up: DRAUGR_CLONE=false drops --clone" {
    DRAUGR_CLONE=false DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    [[ "$(calls create)" != *"--clone"* ]]
}

@test "dr-up: memory, cpus and template are passed only when set" {
    DR_MOCK_STATE=absent run dr-up --print
    [ "$status" -eq 0 ]
    [[ "$output" != *"-m "* ]]
    [[ "$output" != *"--cpus"* ]]

    DRAUGR_MEMORY=8g DRAUGR_CPUS=4 DRAUGR_TEMPLATE=my/img \
        DR_MOCK_STATE=absent run dr-up --print
    [[ "$output" == *"-m 8g"* ]]
    [[ "$output" == *"--cpus 4"* ]]
    [[ "$output" == *"my/img"* ]]
}

@test "dr-up: each port becomes its own -p" {
    DRAUGR_PORTS="5173:5173 8080:8080" DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    [[ "$(calls create)" == *"-p 5173:5173"* ]]
    [[ "$(calls create)" == *"-p 8080:8080"* ]]
}

@test "dr-up: the repo is passed as a Windows path" {
    DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    # Whatever drive the test landed on, it must have been translated: a colon
    # and backslashes, and no trace of the /mnt form.
    [[ "$(calls create)" == *':\'* ]]
    [[ "$(calls create)" != *"/mnt/"* ]]
}

@test "dr-up: an extra mount is translated and keeps its :ro" {
    DRAUGR_MOUNTS="/mnt/c/Docs:ro" DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    [[ "$(calls create)" == *'C:\Docs:ro'* ]]
}

@test "dr-up: refuses an extra mount that is not on a Windows drive" {
    DRAUGR_MOUNTS="/home/someone/data" DR_MOCK_STATE=absent run dr-up
    [ "$status" -ne 0 ]
    [[ "$output" == *"not on a Windows drive"* ]]
    [ -z "$(calls create)" ]
}

@test "dr-up: a kit directory that exists is passed as a Windows path" {
    mkdir -p "$REPO/.draugr/kit"
    DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    [[ "$(calls create)" == *"--kit "*':\'* ]]
}

@test "dr-up: a missing default kit is silent, a missing configured one warns" {
    DR_MOCK_STATE=absent run dr-up
    [[ "$output" != *"no kit found"* ]]

    # Reported by the name you wrote, not by a resolved path: a bare entry is
    # searched for in two places, so "no kit at /repo/nope" would hide half of
    # where Draugr actually looked.
    DRAUGR_KIT=.draugr/nope DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    [[ "$output" == *"no kit found for '.draugr/nope'"* ]]
}

@test "dr-up: --print runs nothing" {
    DR_MOCK_STATE=absent run dr-up --print
    [ "$status" -eq 0 ]
    [ -z "$(calls create)" ]
}

# --- dr-go -------------------------------------------------------------------

@test "dr-go: a dirty tree blocks, and explains why" {
    printf 'wip\n' > "$REPO/scratch.txt"
    DR_MOCK_STATE=running run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *"clone only contains commits"* ]]
    ! attached
}

@test "dr-go: --dirty overrides the clean-tree check" {
    printf 'wip\n' > "$REPO/scratch.txt"
    DR_MOCK_STATE=running run dr-go --dirty
    # Still fails, but on the terminal check rather than the clean one - which is
    # what proves --dirty got past it.
    [[ "$output" != *"clone only contains commits"* ]]
    [[ "$output" == *"needs a terminal"* ]]
}

@test "dr-go: DRAUGR_REQUIRE_CLEAN=false has the same effect" {
    printf 'wip\n' > "$REPO/scratch.txt"
    DRAUGR_REQUIRE_CLEAN=false DR_MOCK_STATE=running run dr-go
    [[ "$output" != *"clone only contains commits"* ]]
}

@test "dr-go: a dirty DRAUGR_DATA file does not block" {
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=running run dr-go
    # Data churn is exempt, so it gets past the clean check to the terminal one.
    [[ "$output" != *"clone only contains commits"* ]]
    [[ "$output" == *"needs a terminal"* ]]
}

@test "dr-go: a dirty source file still blocks even with DRAUGR_DATA set" {
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    printf 'wip\n' > "$REPO/source.py"
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=running run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *"clone only contains commits"* ]]
}

@test "dr-go: the refusal names only what blocked, and counts what did not" {
    # Listing the exempt files too - which `git status --short` does - reads as
    # "DRAUGR_DATA is being ignored" when it is doing exactly its job. Reported
    # against a repo with fifteen churning .tsv files and one stray script.
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    printf 'wip\n' > "$REPO/source.py"
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=running run dr-go
    [[ "$output" == *"source.py"* ]]
    [[ "$output" != *"big.bin"* ]]
    [[ "$output" == *"1 more match DRAUGR_DATA"* ]]
}

@test "dr-go: with no DRAUGR_DATA there is nothing to count" {
    printf 'wip\n' > "$REPO/source.py"
    DR_MOCK_STATE=running run dr-go
    [[ "$output" == *"source.py"* ]]
    [[ "$output" != *"exempt"* ]]
}

@test "dr-go: refuses to attach without a terminal" {
    DR_MOCK_STATE=running run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs a terminal"* ]]
    ! attached
}

@test "dr-go: creates the mound before discovering it cannot attach" {
    DR_MOCK_STATE=absent run dr-go
    [ "$status" -ne 0 ]
    [ -n "$(calls create)" ]
}

@test "dr-go: DRAUGR_CLONE=false prompts and will not assume yes" {
    DRAUGR_CLONE=false DR_MOCK_STATE=running run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *"read-write"* ]]
    ! attached
}

# --- dr-go: DRAUGR_AGENT_ARGS ------------------------------------------------
#
# dr-go refuses to attach without a terminal, and it refuses *before* it would
# print anything about the agent - so these cannot assert on its output. `script`
# allocates a pty so the attach really happens, and the assertion is then on what
# the mock recorded, which is the truth rather than a log line.
#
# Over ssh the agent's command line is inside the rcfile, which travels
# base64-encoded, so these decode it back. That is not indirection for its own
# sake: it is the string the mound's bash will run, and asserting on anything
# earlier would be asserting on our own intentions.
# head -1 because the attach is the first connection of a session: an auto-sync
# afterwards fetches over ssh:// as well, and git would put its own line here.
go_rc() {
    DR_MOCK_STATE=running script -qec "dr-go $*" /dev/null >/dev/null 2>&1 || true
    calls ssh | head -1 | sed 's/.*printf %s //; s/ | base64.*//' | base64 -d
}

@test "dr-go: no agent args by default" {
    [[ "$(go_rc)" == *"; claude; "* ]]
}

@test "dr-go: DRAUGR_AGENT_ARGS is passed without being asked" {
    export DRAUGR_AGENT_ARGS="--continue"
    [[ "$(go_rc)" == *"; claude --continue; "* ]]
}

@test "dr-go: several configured args all survive" {
    export DRAUGR_AGENT_ARGS="--continue --model opus"
    [[ "$(go_rc)" == *"; claude --continue --model opus; "* ]]
}

@test "dr-go: --bare drops the configured args" {
    export DRAUGR_AGENT_ARGS="--continue"
    [[ "$(go_rc --bare)" != *"--continue"* ]]
}

@test "dr-go: an explicit -- replaces the configured args, it does not add" {
    export DRAUGR_AGENT_ARGS="--continue"
    out=$(go_rc -- --model opus)
    [[ "$out" == *"; claude --model opus; "* ]]
    [[ "$out" != *"--continue"* ]]
}

@test "dr-go: a bare -- with nothing after it means no args" {
    export DRAUGR_AGENT_ARGS="--continue"
    [[ "$(go_rc --)" != *"--continue"* ]]
}

@test "dr-go: the same args reach sbx run under DRAUGR_ATTACH=sbx" {
    # The old transport is still there, and still assembles "-- <args>". Kept as
    # one test rather than a second copy of the whole set: what is being checked
    # is that the fallback exists and is wired to the same arguments.
    export DRAUGR_ATTACH=sbx DRAUGR_AGENT_ARGS="--continue"
    # Auto-sync off: it fetches over ssh:// and would put a line in the same log.
    export DRAUGR_AUTO_SYNC=false DRAUGR_MEM_SYNC=off
    DR_MOCK_STATE=running script -qec "dr-go" /dev/null >/dev/null 2>&1 || true
    [[ "$(calls run)" == *"-- --continue"* ]]
    [ -z "$(calls ssh)" ]
}

@test "dr-config: DRAUGR_AGENT_ARGS is a known setting with provenance" {
    printf 'DRAUGR_AGENT_ARGS="--continue"\n' > "$REPO/.draugr.conf"
    run dr-trust --yes "$REPO/.draugr.conf"
    [ "$status" -eq 0 ]
    run dr-config DRAUGR_AGENT_ARGS
    [ "$status" -eq 0 ]
    [ "$output" = "--continue" ]
}

# --- dr-shell ----------------------------------------------------------------
#
# The default transport is ssh, and tests/attach.bats covers it. These two are
# the sbx spelling, which is still there behind DRAUGR_ATTACH and would
# otherwise rot unnoticed.

@test "dr-shell: a command after -- runs without a terminal" {
    DRAUGR_ATTACH=sbx DR_MOCK_STATE=running run dr-shell -- ls -la
    [ "$status" -eq 0 ]
    [[ "$(calls exec)" == *"$SANDBOX ls -la"* ]]
}

@test "dr-shell: --root adds -u root" {
    DRAUGR_ATTACH=sbx DR_MOCK_STATE=running run dr-shell --root -- whoami
    [ "$status" -eq 0 ]
    [[ "$(calls exec)" == *"-u root"* ]]
}

@test "dr-shell: an absent sandbox says so rather than letting sbx fail" {
    DR_MOCK_STATE=absent run dr-shell -- ls
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
    [[ "$output" == *"dr-up"* ]]
}

# --- dr-stop and dr-rm -------------------------------------------------------

@test "dr-stop: stops a running mound" {
    DR_MOCK_STATE=running run dr-stop
    [ "$status" -eq 0 ]
    [[ "$(calls stop)" == *"$SANDBOX"* ]]
}

@test "dr-stop: already stopped is success, not an error" {
    DR_MOCK_STATE=stopped run dr-stop
    [ "$status" -eq 0 ]
    [[ "$output" == *"already stopped"* ]]
    [ -z "$(calls stop)" ]
}

@test "dr-stop: absent is an error naming dr-ls" {
    DR_MOCK_STATE=absent run dr-stop
    [ "$status" -ne 0 ]
    [[ "$output" == *"dr-ls"* ]]
}

@test "dr-rm: will not destroy anything without a terminal or --yes" {
    DR_MOCK_STATE=running run dr-rm
    [ "$status" -ne 0 ]
    [ -z "$(calls rm)" ]
}

@test "dr-rm: --yes removes, forcing past sbx's own prompt" {
    DR_MOCK_STATE=running run dr-rm --yes
    [ "$status" -eq 0 ]
    [[ "$(calls rm)" == *"--force"* ]]
    [[ "$(calls rm)" == *"$SANDBOX"* ]]
}

# --- dr-ls and dr-status -----------------------------------------------------

@test "dr-ls: --names prints bare names" {
    DR_MOCK_STATE=running run dr-ls --names
    [ "$status" -eq 0 ]
    [ "$output" = "$SANDBOX" ]
}

@test "dr-ls: marks the sandbox belonging to the current repo" {
    DR_MOCK_STATE=running run dr-ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"-> $SANDBOX"* ]]
}

@test "dr-ls: does not mark someone else's sandbox" {
    DR_MOCK_NAME=unrelated DR_MOCK_STATE=running run dr-ls
    [ "$status" -eq 0 ]
    [[ "$output" != *"->"* ]]
}

@test "dr-ls: a Windows path survives jq intact" {
    # Regression: jq's @tsv escapes backslashes, so C:\Code came out as C:\\Code.
    DR_MOCK_STATE=running run dr-ls
    [[ "$output" == *'C:\Code\testrepo'* ]]
    [[ "$output" != *'C:\\Code'* ]]
}

@test "dr-ls: says so when there are none" {
    DR_MOCK_STATE=absent run dr-ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"no sandboxes"* ]]
}

@test "dr-ls: works outside a git repository" {
    cd "$DR_TMP" || return 1
    DR_MOCK_STATE=running run dr-ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"$SANDBOX"* ]]
}

@test "dr-status: reports state, branch and a clean tree" {
    DR_MOCK_STATE=running run dr-status
    [ "$status" -eq 0 ]
    [[ "$output" == *"running"* ]]
    [[ "$output" == *"main"* ]]
    [[ "$output" == *"clean"* ]]
}

@test "dr-status: an uncommitted change is reported with its consequence" {
    printf 'wip\n' > "$REPO/scratch.txt"
    DR_MOCK_STATE=running run dr-status
    [ "$status" -eq 0 ]
    [[ "$output" == *"the clone will not have them"* ]]
}

@test "dr-status: headings stay with their rows when stdout is captured" {
    # Regression: headings went to stderr and rows to stdout, so the two streams
    # were buffered apart and "repo" printed above the "repository" heading.
    DR_MOCK_STATE=running run dr-status
    [ "$status" -eq 0 ]

    # On stdout alone, every heading must still precede its own first row.
    DR_MOCK_STATE=running dr-status > "$DR_TMP/out" 2>/dev/null
    grep -q '^repository$' "$DR_TMP/out"
    [ "$(grep -n '^repository$' "$DR_TMP/out" | cut -d: -f1)" \
      -lt "$(grep -n '  repo ' "$DR_TMP/out" | cut -d: -f1)" ]
    [ "$(grep -n '^mound$' "$DR_TMP/out" | cut -d: -f1)" \
      -lt "$(grep -n '  name ' "$DR_TMP/out" | cut -d: -f1)" ]
}

@test "dr-status: an absent mound names the command that makes one" {
    DR_MOCK_STATE=absent run dr-status
    [ "$status" -eq 0 ]
    [[ "$output" == *"dr-up creates it"* ]]
}

# --- dr-stop --all ------------------------------------------------------------
#
# A machine-level sweep. Deliberately NOT limited to sandboxes Draugr named: a
# running mound holds a Hyper-V microVM open whoever created it, and the reason
# to want this - reclaiming memory, or tidying up before shutting the machine
# down - does not care which tool made them. So it lists what it found and asks.

@test "dr-stop --all: stops every running sandbox in one call" {
    DR_MOCK_NAMES="draugr-one draugr-two other-tool" DR_MOCK_STATE=running \
        run dr-stop --all --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 running sandbox(es)"* ]]
    # One sbx call carrying all three, rather than a partial sweep that stops
    # halfway and leaves you guessing which.
    line=$(grep "^stop " "$DR_MOCK_LOG")
    [[ "$line" == *"draugr-one"* ]]
    [[ "$line" == *"draugr-two"* ]]
    [[ "$line" == *"other-tool"* ]]
}

@test "dr-stop --all: reaches past Draugr's own sandboxes, and says so first" {
    # The listing is the consent: you cannot approve a sweep you cannot see.
    DR_MOCK_NAMES="other-tool" DR_MOCK_STATE=running run dr-stop --all --yes
    [[ "$output" == *"other-tool"* ]]
}

@test "dr-stop --all: nothing running is success, not an error" {
    DR_MOCK_STATE=stopped run dr-stop --all --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing is running"* ]]
    [ -z "$(grep "^stop " "$DR_MOCK_LOG" || true)" ]
}

@test "dr-stop --all: an absent list is not an error either" {
    DR_MOCK_STATE=absent run dr-stop --all --yes
    [ "$status" -eq 0 ]
}

@test "dr-stop --all: refuses to assume consent without a terminal" {
    DR_MOCK_NAMES="draugr-one draugr-two" DR_MOCK_STATE=running run dr-stop --all
    [ "$status" -ne 0 ]
    [ -z "$(grep "^stop " "$DR_MOCK_LOG" || true)" ]
}

@test "dr-stop --all: says stopping is not syncing" {
    # The trap this command invites: stopping feels like putting work somewhere
    # safe, and it does nothing of the sort. dr-sync is what fetches commits.
    DR_MOCK_NAMES="draugr-one" DR_MOCK_STATE=running run dr-stop --all --yes
    [[ "$output" == *"dr-sync"* ]]
}

@test "dr-stop --all: rejects a sandbox name alongside it" {
    run dr-stop --all draugr-one
    [ "$status" -ne 0 ]
}

@test "dr-stop --all: works outside any repository" {
    # The usual moment to want this is on the way out of a terminal that is not
    # in a project, so it must not go through dr_context.
    cd "$DR_TMP" || return 1
    DR_MOCK_NAMES="draugr-one" DR_MOCK_STATE=running run dr-stop --all --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"stopped 1"* ]]
}

# --- DRAUGR_STOP_ON_EXIT ------------------------------------------------------
#
# Off by default. Stopping is hygiene, not durability - the dr-sync that has just
# run is what protects the agent's work - and it silently kills anything the kit
# serves through publishedPorts or startup commands. Measured: an idle mound
# holds ~1.4 GB, and a cold start costs 4.2s against 0.36s to attach to a live
# one, so this is a real trade rather than a free win either way.

# dr-go needs a terminal before it will attach, so these go through a pty the
# same way go_argv does - but keeping the OUTPUT rather than the recorded argv.
go_output() {
    DR_MOCK_STATE=running script -qec "dr-go $*" /dev/null 2>&1 || true
}

@test "dr-go: leaves the mound running by default, and says so" {
    run go_output
    [[ "$output" == *"still running"* ]]
    [ -z "$(calls stop)" ]
}

@test "dr-go: DRAUGR_STOP_ON_EXIT=true stops it" {
    export DRAUGR_STOP_ON_EXIT=true
    run go_output
    [[ "$(calls stop)" == *"$SANDBOX"* ]]
    [[ "$output" == *"stopped $SANDBOX"* ]]
}

@test "dr-go: the stop is the LAST thing it does" {
    # Everything on the way out - the sync, the memory export, the data pull -
    # talks to the mound. Stopping first would turn each into a cold start or an
    # outright failure, so the ordering is load-bearing rather than cosmetic.
    export DRAUGR_STOP_ON_EXIT=true
    run go_output
    [[ "$(tail -1 "$DR_MOCK_LOG")" == stop* ]]
}

@test "dr-go: a mound that will not stop warns rather than failing" {
    # The session is over and the work is already fetched, so this is untidy
    # rather than dangerous - and dying here would mask the agent's exit code.
    export DRAUGR_STOP_ON_EXIT=true DR_MOCK_FAIL=stop
    run go_output
    [[ "$output" == *"could not stop"* ]]
    [[ "$output" == *"still running"* ]]
}

@test "dr-go: an off-by-default key stays off when set to anything but true" {
    # dr_is_true is the gate, so "yes" and "1" and typos all mean "leave it".
    export DRAUGR_STOP_ON_EXIT=maybe
    run go_output
    [ -z "$(calls stop)" ]
}
