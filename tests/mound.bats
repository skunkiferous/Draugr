#!/usr/bin/env bats
# The mound lifecycle: dr-up, dr-go, dr-shell, dr-stop, dr-rm, dr-ls, dr-status.
#
# Nothing here starts a hypervisor. tests/mocks/sbx records its command line and
# replays a fixed `ls --json`. Thus these tests assert that Draugr builds the
# right sbx call from a given configuration. That part does all the path
# translation, and thus has all the bugs.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1

    # dr_sandbox_name gets this from the folder, and the mock must agree. If
    # not, dr_sandbox_state reports "absent", whatever DR_MOCK_STATE says.
    SANDBOX="draugr-$(basename "$REPO")"
    export DR_MOCK_NAME="$SANDBOX"
}

teardown() { dr_test_teardown; }

# The recorded argv for one subcommand, for example calls create -> the create
# line. tests/mocks/ssh logs under "ssh", so `calls ssh` finds the attaches in
# the same file.
calls() { grep "^$1 " "$DR_MOCK_LOG" || true; }

# True if anything attached, by either transport. For tests where nothing must
# attach, because a test refused before the agent started. Without it, such a
# test silently loses its meaning when the default transport changes.
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
    # "no-op" means that it does not build or start anything. It does not mean
    # "runs no commands". DRAUGR_MEM_SYNC=auto looks inside the mound on each
    # dr-up, and that is an exec. Only the start must be absent.
    [[ "$(calls exec)" != *"$SANDBOX true"* ]]
}

@test "dr-up: twice in a row creates only one sandbox" {
    DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    # The mock has no memory, so the test tells the second run that the sandbox
    # exists. The real sbx reports exactly that.
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
    # On each drive, the path must be translated: a colon and backslashes, and
    # no trace of the /mnt form.
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

    # Reported by the name that you wrote, not by a resolved path. Draugr looks
    # for a bare entry in two places. Thus "no kit at /repo/nope" hides half of
    # the places where Draugr looked.
    DRAUGR_KIT=.draugr/nope DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    [[ "$output" == *"no kit found for '.draugr/nope'"* ]]
}

@test "dr-up: --print runs nothing" {
    DR_MOCK_STATE=absent run dr-up --print
    [ "$status" -eq 0 ]
    [ -z "$(calls create)" ]
}

# --- creation-time settings drift --------------------------------------------
#
# When sbx builds the sandbox, the ports, mounts, memory, image and agent become
# fixed. If you edit one and run dr-up again, nothing happens. On an existing
# mound, dr-up only starts it. These tests are about that silent no-op. You add
# a mount, run dr-go, and the directory is absent.

@test "dr-up: records what it built with" {
    DRAUGR_MOUNTS="/mnt/c/Docs:ro" DR_MOCK_STATE=absent run dr-up
    [ "$status" -eq 0 ]
    grep -q "^DRAUGR_MOUNTS=/mnt/c/Docs:ro$" "$REPO/.draugr/create.applied"
}

@test "dr-up: a changed mount list is reported, not silently ignored" {
    DRAUGR_MOUNTS="/mnt/c/Docs:ro" DR_MOCK_STATE=absent run dr-up
    DRAUGR_MOUNTS="/mnt/c/Docs:ro /mnt/c/More:ro" DR_MOCK_STATE=running run dr-up
    [[ "$output" == *"changed after"* ]]
    [[ "$output" == *"DRAUGR_MOUNTS"* ]]
    [[ "$output" == *"dr-up --recreate"* ]]
}

@test "dr-up: an unchanged config says nothing" {
    DRAUGR_MOUNTS="/mnt/c/Docs:ro" DR_MOCK_STATE=absent run dr-up
    DRAUGR_MOUNTS="/mnt/c/Docs:ro" DR_MOCK_STATE=running run dr-up
    [[ "$output" != *"changed since"* ]]
}

@test "dr-up: ports are named as the one thing that needs no rebuild" {
    DR_MOCK_STATE=absent run dr-up
    DRAUGR_PORTS="8080:8080" DR_MOCK_STATE=running run dr-up
    [[ "$output" == *"DRAUGR_PORTS"* ]]
    [[ "$output" == *"dr-ports"* ]]
}

@test "dr-up: a mount change is not reported as a port change" {
    DR_MOCK_STATE=absent run dr-up
    DRAUGR_MOUNTS="/mnt/c/Docs:ro" DR_MOCK_STATE=running run dr-up
    [[ "$output" == *"DRAUGR_MOUNTS"* ]]
    [[ "$output" != *"dr-ports"* ]]
}

@test "dr-up: a mound built before the stamp existed is not called drift" {
    # Unknown is not drift. A warning on each dr-up for each older mound teaches
    # people to ignore the important warning.
    DR_MOCK_STATE=absent run dr-up
    rm -f "$REPO/.draugr/create.applied"
    DRAUGR_MEMORY=8g DR_MOCK_STATE=running run dr-up
    [[ "$output" != *"changed since"* ]]
}

@test "dr-up: --recreate refreshes the record" {
    DRAUGR_MOUNTS="/mnt/c/Docs:ro" DR_MOCK_STATE=absent run dr-up
    DRAUGR_MOUNTS="/mnt/c/Other:ro" DR_MOCK_STATE=running run dr-up --yes --recreate
    [ "$status" -eq 0 ]
    grep -q "^DRAUGR_MOUNTS=/mnt/c/Other:ro$" "$REPO/.draugr/create.applied"

    # And the warning is gone, because the mound now matches the configuration.
    DRAUGR_MOUNTS="/mnt/c/Other:ro" DR_MOCK_STATE=running run dr-up
    [[ "$output" != *"changed since"* ]]
}

@test "dr_create_drift: a key the stamp never held is not drift either" {
    # An older Draugr wrote a stamp with fewer keys. If an absent line is a
    # change, each upgrade looks like drift.
    DR_MOCK_STATE=absent run dr-up
    grep -v '^DRAUGR_CPUS=' "$REPO/.draugr/create.applied" > "$REPO/.draugr/tmp.applied"
    mv "$REPO/.draugr/tmp.applied" "$REPO/.draugr/create.applied"
    DRAUGR_CPUS=4 DR_MOCK_STATE=running run dr-up
    [[ "$output" != *"DRAUGR_CPUS"* ]]
}

@test "dr-init: the stamp is gitignored, so it cannot block dr-go" {
    # DRAUGR_REQUIRE_CLEAN=true means that an untracked file stops a session. A
    # file that Draugr writes itself must never do that.
    run dr-init
    [ "$status" -eq 0 ]
    grep -qx '\.draugr/create\.applied' "$REPO/.gitignore"
}

# dr-init leaves .draugr.conf and the kit untracked, and .gitignore changed.
# Thus the next dr-go refuses. A message at that time is better than a refusal
# later.
@test "dr-init: says the tree it just dirtied will refuse dr-go" {
    run dr-init
    [ "$status" -eq 0 ]
    [[ "$output" == *"refuses while these are uncommitted"* ]]
}

# --- dr-go -------------------------------------------------------------------

@test "dr-go: a dirty tree blocks, and explains why" {
    printf 'wip\n' > "$REPO/scratch.txt"
    DR_MOCK_STATE=running run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *"clone holds only commits"* ]]
    ! attached
}

# .gitignore IS THE CIRCULAR CASE. You add a pattern to it, so that other files
# do not block. That edit then blocks by itself. It cannot be exempt, because
# the clone ignores what the COMMITTED .gitignore ignores. Thus the refusal must
# say why, and name the alternative for one checkout. docs/HACKING.md, "Working
# on Draugr".
@test "dr-go: a dirty .gitignore says why it cannot be exempted" {
    printf 'scratch/\n' >> "$REPO/.gitignore"
    DR_MOCK_STATE=running run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *".gitignore is one of them"* ]]
    [[ "$output" == *".git/info/exclude"* ]]
    ! attached
}

# THE NEGATIVE HALF, and the reason for the test above. Nobody reads advice that
# prints for each dirty file. Without this, a message test cannot tell a
# specific message from a fixed one.
@test "dr-go: an ordinary dirty file gets no .gitignore advice" {
    printf 'wip\n' > "$REPO/scratch.txt"
    DR_MOCK_STATE=running run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" != *"info/exclude"* ]]
    [[ "$output" != *".gitignore is one of them"* ]]
}

@test "dr-go: --dirty overrides the clean-tree check" {
    printf 'wip\n' > "$REPO/scratch.txt"
    DR_MOCK_STATE=running run dr-go --dirty
    # Still fails, but on the terminal test, not the clean one. That proves that
    # --dirty got past it.
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
    # Data changes are exempt, so it gets past the clean test to the terminal
    # test.
    [[ "$output" != *"clone only contains commits"* ]]
    [[ "$output" == *"needs a terminal"* ]]
}

@test "dr-go: a dirty source file still blocks even with DRAUGR_DATA set" {
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    printf 'wip\n' > "$REPO/source.py"
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=running run dr-go
    [ "$status" -ne 0 ]
    [[ "$output" == *"clone holds only commits"* ]]
}

@test "dr-go: the refusal names only what blocked, and counts what did not" {
    # `git status --short` also lists the exempt files. That reads as "Draugr
    # ignores DRAUGR_DATA", but DRAUGR_DATA does its job. A user reported this,
    # on a repo with fifteen changing .tsv files and one stray script.
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
# dr-go refuses to attach without a terminal. It refuses *before* it prints
# anything about the agent, so these tests cannot assert on its output. `script`
# gives a pty, so that the attach really happens. The test then asserts on what
# the mock recorded. That is the truth, not a log line.
#
# Over ssh, the command line of the agent is inside the rcfile, which travels in
# base64. Thus these tests decode it. It is the string that the bash of the
# mound runs. An assertion on an earlier form only tests our own intentions.
# head -1, because the attach is the first connection of a session. A later
# auto-sync also fetches over ssh://, and git puts its own line here.
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
    # The old transport still exists, and still builds "-- <args>". One test,
    # not a second copy of the full set. It tests that the fallback exists and
    # gets the same arguments.
    export DRAUGR_ATTACH=sbx DRAUGR_AGENT_ARGS="--continue"
    # Auto-sync off. It fetches over ssh://, and puts a line in the same log.
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
# The default transport is ssh, and tests/attach.bats covers it. These two test
# the sbx form. It still exists behind DRAUGR_ATTACH, and without tests it
# breaks with nobody noticing.

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
    # Regression: jq's @tsv escapes backslashes, so C:\Code came out as
    # C:\\Code.
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
    [[ "$output" == *"The clone does not have them"* ]]
}

@test "dr-status: headings stay with their rows when stdout is captured" {
    # Regression: headings went to stderr and rows to stdout. Thus the two
    # streams had separate buffers, and "repo" printed above the "repository"
    # heading.
    DR_MOCK_STATE=running run dr-status
    [ "$status" -eq 0 ]

    # On stdout alone, each heading must still come before its own first row.
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
# A sweep of the full machine. On purpose, it is NOT limited to sandboxes that
# Draugr named. A running mound holds a Hyper-V microVM open, whatever created
# it. The reasons for this command are to get memory back, or to clean up before
# a shutdown. Neither cares which tool made them. Thus it lists them and asks.

@test "dr-stop --all: stops every running sandbox in one call" {
    DR_MOCK_NAMES="draugr-one draugr-two other-tool" DR_MOCK_STATE=running \
        run dr-stop --all --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 running sandbox(es)"* ]]
    # One sbx call with all three. A partial sweep can stop halfway, and then
    # you do not know which ones stopped.
    line=$(grep "^stop " "$DR_MOCK_LOG")
    [[ "$line" == *"draugr-one"* ]]
    [[ "$line" == *"draugr-two"* ]]
    [[ "$line" == *"other-tool"* ]]
}

@test "dr-stop --all: reaches past Draugr's own sandboxes, and says so first" {
    # The list is the consent. You cannot approve a sweep that you cannot see.
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
    # The trap of this command: a stop feels like it puts work in a safe place.
    # It does not. dr-sync fetches the commits.
    DR_MOCK_NAMES="draugr-one" DR_MOCK_STATE=running run dr-stop --all --yes
    [[ "$output" == *"dr-sync"* ]]
}

@test "dr-stop --all: rejects a sandbox name alongside it" {
    run dr-stop --all draugr-one
    [ "$status" -ne 0 ]
}

@test "dr-stop --all: works outside any repository" {
    # Usually you need this when you leave a terminal that is not in a project.
    # Thus it must not go through dr_context.
    cd "$DR_TMP" || return 1
    DR_MOCK_NAMES="draugr-one" DR_MOCK_STATE=running run dr-stop --all --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"stopped 1"* ]]
}

# --- DRAUGR_STOP_ON_EXIT ------------------------------------------------------
#
# Off by default. A stop is clean-up, not protection. The dr-sync that just ran
# protects the work of the agent. A stop also silently kills all that the kit
# serves through publishedPorts or startup commands. Measured: an idle mound
# holds ~1.4 GB. A cold start takes 4.2s, and an attach to a live one 0.36s.
# Thus both choices have a real cost.

# dr-go needs a terminal before it attaches. Thus these go through a pty, as
# go_argv does, but they keep the OUTPUT, not the recorded argv.
go_output() {
    DR_MOCK_STATE=running script -qec "dr-go $*" /dev/null 2>&1 || true
}

@test "dr-go: leaves the mound to stop itself, and says so" {
    # It must not promise that the mound stays up. sandboxd stops it a short
    # time after the last session, so "still runs. To stop it: dr-stop" was
    # true for about half a minute and then sent the reader to dr-stop for
    # something the daemon had already done.
    run go_output
    [[ "$output" == *"stops itself"* ]]
    [[ "$output" == *"dr-stop"* ]]
    [[ "$output" != *"still runs"* ]]
    [ -z "$(calls stop)" ]
}

@test "dr-go: DRAUGR_STOP_ON_EXIT=true stops it" {
    export DRAUGR_STOP_ON_EXIT=true
    run go_output
    [[ "$(calls stop)" == *"$SANDBOX"* ]]
    [[ "$output" == *"stopped $SANDBOX"* ]]
}

@test "dr-go: the stop is the LAST thing it does" {
    # All the exit steps talk to the mound: the sync, the memory export, the
    # data pull. A stop before them makes each one a cold start or a failure.
    # Thus the order is important.
    export DRAUGR_STOP_ON_EXIT=true
    run go_output
    [[ "$(tail -1 "$DR_MOCK_LOG")" == stop* ]]
}

@test "dr-go: a mound that will not stop warns rather than failing" {
    # The session is over and the work is fetched, so this is untidy, not
    # dangerous. An exit here hides the exit code of the agent.
    export DRAUGR_STOP_ON_EXIT=true DR_MOCK_FAIL=stop
    run go_output
    [[ "$output" == *"could not stop"* ]]
    [[ "$output" == *"still runs"* ]]
}

@test "dr-go: an off-by-default key stays off when set to anything but true" {
    # dr_is_true decides, so "yes", "1" and typos all mean "leave it".
    export DRAUGR_STOP_ON_EXIT=maybe
    run go_output
    [ -z "$(calls stop)" ]
}

# --- data is not "uncommitted work" ------------------------------------------
#
# A repo whose CONTENT is data, for example a hundred tracked .tsv files, has a
# dirty tree almost all the time. The clean-tree test is not for that. When both
# were in one report, each command said that sixteen things were wrong, and
# nothing was. "the clone will not have them" was false. Data arrives by rsync
# before the agent starts.

@test "dr-status: data files are counted apart from uncommitted work" {
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=stopped run dr-status
    [ "$status" -eq 0 ]
    [[ "$output" == *"clean"*"except data"* ]]
    [[ "$output" == *"1 changed"* ]]
    [[ "$output" == *"dr-data push"* ]]
}

@test "dr-status: 'the clone will not have them' is only said of files it is true of" {
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    printf 'wip\n' > "$REPO/source.py"
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=stopped run dr-status
    [[ "$output" == *"1 uncommitted change(s)"* ]]
    [[ "$output" == *"The clone does not have them"* ]]
    [[ "$output" == *"1 changed"* ]]
}

@test "dr-status: no data row when nothing data-shaped is dirty" {
    printf 'wip\n' > "$REPO/source.py"
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=stopped run dr-status
    [[ "$output" == *"1 uncommitted change(s)"* ]]
    [[ "$output" != *"dr-data push"* ]]
}

@test "dr-status: a clean tree says so without mentioning data at all" {
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=stopped run dr-status
    [[ "$output" == *"clean"* ]]
    [[ "$output" != *"apart from data"* ]]
}

@test "dr-status: with no DRAUGR_DATA every change is an uncommitted one" {
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    DR_MOCK_STATE=stopped run dr-status
    [[ "$output" == *"1 uncommitted change(s)"* ]]
    [[ "$output" != *"apart from data"* ]]
}

@test "dr-send: data files are not listed as work it failed to send" {
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=running run dr-send
    [[ "$output" != *"only committed work is sent"* ]]
    [[ "$output" == *"go separately"* ]]
    [[ "$output" == *"dr-data push"* ]]
}

@test "dr-send: a genuine uncommitted change is still named" {
    printf 'wip\n' > "$REPO/source.py"
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=running run dr-send
    [[ "$output" == *"Only committed work goes"* ]]
    [[ "$output" == *"source.py"* ]]
    [[ "$output" != *"big.bin"* ]]
}

# --- an exemption that carries nothing ---------------------------------------

@test "dr-go: warns when dirty data is exempted but nothing will push it" {
    # DRAUGR_DATA lets the session start with a dirty data file, because dr-data
    # carries it. With push off, nothing carries it. The agent then uses the old
    # copy in the mound. DRAUGR_REQUIRE_CLEAN exists to prevent exactly that.
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    DRAUGR_DATA="tmp/**" DRAUGR_DATA_PUSH=manual DR_MOCK_STATE=running run dr-go
    [[ "$output" == *"do not go to the mound"* ]]
    [[ "$output" == *"dr-data push"* ]]
}

@test "dr-go: silent when push is auto, which is the default" {
    mkdir -p "$REPO/tmp"
    printf 'churn\n' > "$REPO/tmp/big.bin"
    DRAUGR_DATA="tmp/**" DR_MOCK_STATE=running run dr-go
    [[ "$output" != *"will not reach the mound"* ]]
}

@test "dr-go: silent when push is off but no data file is dirty" {
    printf 'wip\n' > "$REPO/source.py"
    DRAUGR_DATA="tmp/**" DRAUGR_DATA_PUSH=off DR_MOCK_STATE=running run dr-go
    [[ "$output" != *"will not reach the mound"* ]]
}
