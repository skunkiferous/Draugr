#!/usr/bin/env bats
# What the agent can reach, and what can reach the host back.
#
# A user asked two questions, and tests can answer both. Are git stashes visible
# in the mound? Can the agent weaken the own configuration of Draugr? Both are
# pinned here, so that a future change cannot silently reverse them.

load helper

setup() {
    dr_test_setup
    dr_load_common
    export DRAUGR_MEM_SYNC=off
}

teardown() { dr_test_teardown; }

# --- stashes ------------------------------------------------------------------

@test "stash: a clone does not carry refs/stash" {
    local repo; repo=$(dr_make_repo)
    printf 'SECRET=hunter2\n' > "$repo/leak.env"
    git -C "$repo" add -A
    git -C "$repo" stash -q

    git clone -q "$repo" "$DR_TMP/clone"
    run git -C "$DR_TMP/clone" stash list
    # Really absent from the clone. People think that this half is the full
    # story.
    [ -z "$output" ]
}

@test "stash: but the content is recoverable from .git alone" {
    local repo; repo=$(dr_make_repo)
    printf 'SECRET=hunter2\n' > "$repo/leak.env"
    git -C "$repo" add -A
    git -C "$repo" stash -q

    # .git is in the read-only mount, so the agent can do this. If this stops
    # working, read SECURITY.md again. Do not celebrate.
    run git --git-dir="$repo/.git" stash show -p
    [[ "$output" == *"hunter2"* ]]
}

@test "dr-scan: reports stashes, because it cannot see into them" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    printf 'x\n' > file.txt
    git -C "$repo" add -A
    git -C "$repo" stash -q

    run dr-scan
    [[ "$output" == *"stash"* ]]
    [[ "$output" == *"NOT scanned"* ]]
}

@test "dr-scan: a stash is a warning, not a refusal" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    printf 'x\n' > file.txt
    git -C "$repo" add -A
    git -C "$repo" stash -q

    # A stash does not prove a secret. A block on one teaches people to give
    # --force. Only credential hits block.
    run dr-scan
    [ "$status" -eq 0 ]
}

@test "dr-scan: says nothing about stashes when there are none" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    run dr-scan
    [[ "$output" != *"stash"* ]]
}

@test "dr-scan: stashing a secret hides it from the pattern scan" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    printf 'AWS_SECRET=hunter2\n' > secrets.env

    run dr-scan
    [[ "$output" == *"secrets.env"* ]]

    git -C "$repo" add -A
    git -C "$repo" stash -q

    # This documents the gap, and does not act as if it is closed. The file is
    # gone from the working tree, so the scan cannot see it. But it stays
    # readable through the mount. The stash warning above replaces the scan.
    run dr-scan
    [[ "$output" != *"secrets.env"* ]]
    [[ "$output" == *"stash"* ]]
}

# --- can the agent weaken the setup? -------------------------------------------

@test "config: an edited .draugr.conf is not sourced" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    dr-init >/dev/null 2>&1

    # Exactly like a merged change that the agent wrote.
    printf '\nDRAUGR_SCAN=false\nDRAUGR_CLONE=false\n' >> "$repo/.draugr.conf"

    run dr-config
    [[ "$output" == *"not trusted"* ]]
}

@test "config: the weakened settings do not take effect" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    dr-init >/dev/null 2>&1
    printf '\nDRAUGR_SCAN=false\n' >> "$repo/.draugr.conf"

    # A refusal to source is useful only if the old value then wins.
    run dr-config
    [[ "$output" == *"DRAUGR_SCAN"*"true"* ]]
}

@test "hook: an untrusted hook is refused, not run" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    dr-init >/dev/null 2>&1
    mkdir -p "$repo/.draugr/hooks"
    printf '#!/bin/sh\ntouch "%s/HOOK-RAN"\n' "$DR_TMP" > "$repo/.draugr/hooks/pre-up"
    chmod +x "$repo/.draugr/hooks/pre-up"

    DR_MOCK_STATE=running run dr-up
    [ "$status" -ne 0 ]
    [[ "$output" == *"a hook that is not trusted"* ]]
    # The purpose: it did not execute on the host before the refusal.
    [ ! -f "$DR_TMP/HOOK-RAN" ]
}

@test "hook: a trusted hook runs" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    dr-init >/dev/null 2>&1
    mkdir -p "$repo/.draugr/hooks"
    printf '#!/bin/sh\ntouch "%s/HOOK-RAN"\n' "$DR_TMP" > "$repo/.draugr/hooks/pre-up"
    chmod +x "$repo/.draugr/hooks/pre-up"
    dr-trust "$repo/.draugr/hooks/pre-up" --yes >/dev/null 2>&1

    DR_MOCK_STATE=running run dr-up
    [ "$status" -eq 0 ]
    [ -f "$DR_TMP/HOOK-RAN" ]
}

@test "hook: editing a trusted hook revokes it" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    dr-init >/dev/null 2>&1
    mkdir -p "$repo/.draugr/hooks"
    printf '#!/bin/sh\nexit 0\n' > "$repo/.draugr/hooks/pre-up"
    chmod +x "$repo/.draugr/hooks/pre-up"
    dr-trust "$repo/.draugr/hooks/pre-up" --yes >/dev/null 2>&1

    # Trust is for each content, so a later change must be accepted again. Thus
    # this is useful against a merge, not only on a first clone.
    printf '#!/bin/sh\ntouch "%s/HOOK-RAN"\n' "$DR_TMP" > "$repo/.draugr/hooks/pre-up"

    DR_MOCK_STATE=running run dr-up
    [ "$status" -ne 0 ]
    [ ! -f "$DR_TMP/HOOK-RAN" ]
}

@test "hook: a non-executable hook is ignored, not refused" {
    # dr_hook directly, in $DR_TMP, not in a repo on a Windows drive. Files on
    # /mnt/c are mode 777, and chmod -x does nothing there. Thus there, this
    # cannot test its claim. $DR_TMP is a normal Linux filesystem.
    mkdir -p "$DR_TMP/repo/.draugr/hooks"
    printf '#!/bin/sh\ntouch "%s/HOOK-RAN"\n' "$DR_TMP" > "$DR_TMP/repo/.draugr/hooks/pre-up"
    chmod -x "$DR_TMP/repo/.draugr/hooks/pre-up"

    # Hooks are opt-in, so a hook that is not executable is nothing. A trust
    # question for it asks about a file that nothing reads.
    run dr_hook pre-up "$DR_TMP/repo"
    [ "$status" -eq 0 ]
    [ ! -f "$DR_TMP/HOOK-RAN" ]
}

@test "hook: an executable, untrusted hook is refused by dr_hook itself" {
    mkdir -p "$DR_TMP/repo/.draugr/hooks"
    printf '#!/bin/sh\ntouch "%s/HOOK-RAN"\n' "$DR_TMP" > "$DR_TMP/repo/.draugr/hooks/pre-up"
    chmod +x "$DR_TMP/repo/.draugr/hooks/pre-up"

    # The guard is in dr_hook, not in one command, so each caller gets it.
    run dr_hook pre-up "$DR_TMP/repo"
    [ "$status" -ne 0 ]
    [ ! -f "$DR_TMP/HOOK-RAN" ]
}

@test "dr-trust: with no arguments it offers the hooks too" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    dr-init >/dev/null 2>&1
    mkdir -p "$repo/.draugr/hooks"
    printf '#!/bin/sh\nexit 0\n' > "$repo/.draugr/hooks/post-up"
    chmod +x "$repo/.draugr/hooks/post-up"

    run dr-trust --yes
    [[ "$output" == *"post-up"* ]]
}

@test "hook: .draugr.local.conf cannot arrive through a merge" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    dr-init >/dev/null 2>&1

    # It is gitignored. Thus it is the right place for all that a repository
    # must not change.
    run git -C "$repo" check-ignore .draugr.local.conf
    [ "$status" -eq 0 ]
}

# --- what leaves the host on the ssh transport --------------------------------

@test "ssh snippet: no wildcard SendEnv" {
    # "SendEnv *" offers each variable in the WSL environment to the sandbox. A
    # test on sbx 0.37.1 showed that the proxy accepts none of them, so nothing
    # leaked. But that is a property of the current sbx, not of the
    # configuration. This project controls the configuration.
    run grep -E "^[[:space:]]*SendEnv" "$BATS_TEST_DIRNAME/../share/ssh-config.snippet"
    [ "$status" -eq 0 ]
    [[ "$output" != *"SendEnv *"* ]]
}

@test "ssh snippet: SendEnv is an explicit allowlist" {
    # Locale is the only useful thing to forward to a sandbox. An allowlist
    # cannot silently grow into a credential leak, as a wildcard can.
    run grep -E "^[[:space:]]*SendEnv[[:space:]]+LANG[[:space:]]+LC_\*[[:space:]]*$" \
        "$BATS_TEST_DIRNAME/../share/ssh-config.snippet"
    [ "$status" -eq 0 ]
}
