#!/usr/bin/env bats
# What the agent can reach, and what can reach the host back.
#
# Two questions a user asked that turned out to have measurable answers: are git
# stashes visible inside the mound, and can the agent weaken Draugr's own
# configuration? Both are pinned here so a future change cannot quietly reverse
# them.

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
    # Genuinely absent from the clone - which is the half people assume is the
    # whole story.
    [ -z "$output" ]
}

@test "stash: but the content is recoverable from .git alone" {
    local repo; repo=$(dr_make_repo)
    printf 'SECRET=hunter2\n' > "$repo/leak.env"
    git -C "$repo" add -A
    git -C "$repo" stash -q

    # .git is inside the read-only mount, so this is what the agent can do. If
    # this ever stops working, SECURITY.md needs revisiting - not celebrating.
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

    # A stash is not evidence of a secret; blocking on one would train people to
    # pass --force. Only credential hits block.
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

    # Documenting the gap rather than pretending it is closed: the file is gone
    # from the working tree, so the scan cannot see it - while it stays readable
    # through the mount. The stash warning above is what stands in for it.
    run dr-scan
    [[ "$output" != *"secrets.env"* ]]
    [[ "$output" == *"stash"* ]]
}

# --- can the agent weaken the setup? -------------------------------------------

@test "config: an edited .draugr.conf is not sourced" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    dr-init >/dev/null 2>&1

    # Exactly what a merged, agent-authored change would look like.
    printf '\nDRAUGR_SCAN=false\nDRAUGR_CLONE=false\n' >> "$repo/.draugr.conf"

    run dr-config
    [[ "$output" == *"untrusted"* ]]
}

@test "config: the weakened settings do not take effect" {
    local repo; repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
    cd "$repo"
    dr-init >/dev/null 2>&1
    printf '\nDRAUGR_SCAN=false\n' >> "$repo/.draugr.conf"

    # Refusing to source is only useful if the refusal means the old value wins.
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
    [[ "$output" == *"untrusted hook"* ]]
    # The point: it did not execute on the host before being refused.
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

    # Trust is per content, so a later change has to be accepted again - which is
    # what makes this useful against a merge rather than only a first clone.
    printf '#!/bin/sh\ntouch "%s/HOOK-RAN"\n' "$DR_TMP" > "$repo/.draugr/hooks/pre-up"

    DR_MOCK_STATE=running run dr-up
    [ "$status" -ne 0 ]
    [ ! -f "$DR_TMP/HOOK-RAN" ]
}

@test "hook: a non-executable hook is ignored, not refused" {
    # dr_hook directly, in $DR_TMP rather than a repo on a Windows drive: files
    # on /mnt/c are mode 777 and chmod -x does nothing there, so this could not
    # test what it claims to. $DR_TMP is an ordinary Linux filesystem.
    mkdir -p "$DR_TMP/repo/.draugr/hooks"
    printf '#!/bin/sh\ntouch "%s/HOOK-RAN"\n' "$DR_TMP" > "$DR_TMP/repo/.draugr/hooks/pre-up"
    chmod -x "$DR_TMP/repo/.draugr/hooks/pre-up"

    # Hooks are opt-in, so an unexecutable one is nothing at all - demanding
    # trust for it would be asking about a file nothing is going to read.
    run dr_hook pre-up "$DR_TMP/repo"
    [ "$status" -eq 0 ]
    [ ! -f "$DR_TMP/HOOK-RAN" ]
}

@test "hook: an executable, untrusted hook is refused by dr_hook itself" {
    mkdir -p "$DR_TMP/repo/.draugr/hooks"
    printf '#!/bin/sh\ntouch "%s/HOOK-RAN"\n' "$DR_TMP" > "$DR_TMP/repo/.draugr/hooks/pre-up"
    chmod +x "$DR_TMP/repo/.draugr/hooks/pre-up"

    # The guard lives in dr_hook, not in any one command, so every caller gets it.
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

    # It is gitignored, which is what makes it the right place for anything you
    # do not want a repository able to influence.
    run git -C "$repo" check-ignore .draugr.local.conf
    [ "$status" -eq 0 ]
}

# --- what leaves the host on the ssh transport --------------------------------

@test "ssh snippet: no wildcard SendEnv" {
    # "SendEnv *" would offer every variable in the WSL environment to the
    # sandbox. Measured against sbx 0.37.1 the proxy accepts none of them, so it
    # leaked nothing - but that is a property of today's sbx, not of the config,
    # and the config is the half this project controls.
    run grep -E "^[[:space:]]*SendEnv" "$BATS_TEST_DIRNAME/../share/ssh-config.snippet"
    [ "$status" -eq 0 ]
    [[ "$output" != *"SendEnv *"* ]]
}

@test "ssh snippet: SendEnv is an explicit allowlist" {
    # Locale is the only thing worth forwarding to a sandbox, and an allowlist
    # cannot quietly grow into a credential leak the way a wildcard can.
    run grep -E "^[[:space:]]*SendEnv[[:space:]]+LANG[[:space:]]+LC_\*[[:space:]]*$" \
        "$BATS_TEST_DIRNAME/../share/ssh-config.snippet"
    [ "$status" -eq 0 ]
}
