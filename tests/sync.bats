#!/usr/bin/env bats
# The daily loop: dr-sync, dr-log, dr-diff, dr-merge, and dr-rm's safety check.
#
# There is no sandbox here. `dr_fake_mound` uses git's url.<base>.insteadOf to
# point ssh://<name>.sbx/<path> at a local clone, so the fetch, the ref names and
# the commit counting are all genuine - only the transport is substituted.

load helper

setup() {
    dr_test_setup
    REPO=$(dr_make_win_repo) || skip "no writable path under /mnt/<drive> on this machine"
    cd "$REPO" || return 1
    SANDBOX="draugr-$(basename "$REPO")"
    export DR_MOCK_NAME="$SANDBOX" DR_MOCK_STATE=running
    MOUND=$(dr_fake_mound "$REPO" "$SANDBOX")
}

teardown() { dr_test_teardown; }

# --- dr-sync -----------------------------------------------------------------

@test "dr-sync: creates the draugr remote pointing at ssh://" {
    run dr-sync
    [ "$status" -eq 0 ]
    # `git remote get-url` applies insteadOf rewriting and would show the local
    # stand-in; the raw config value is what Draugr actually wrote.
    run git config remote.draugr.url
    [[ "$output" == "ssh://$SANDBOX.sbx/"* ]]
}

@test "dr-sync: nothing new is said plainly" {
    run dr-sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing new in the mound"* ]]
}

@test "dr-sync: fetches the agent's commits and counts them" {
    dr_mound_commit "$MOUND" "first agent commit"
    dr_mound_commit "$MOUND" "second agent commit"
    run dr-sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 new commit(s)"* ]]
    [[ "$output" == *"second agent commit"* ]]
}

@test "dr-sync: leaves your branch exactly where it was" {
    before=$(git rev-parse HEAD)
    dr_mound_commit "$MOUND"
    run dr-sync
    [ "$status" -eq 0 ]
    [ "$(git rev-parse HEAD)" = "$before" ]
}

@test "dr-sync: notices commits the mound does not have" {
    printf 'host work\n' > host.txt
    git add -A && git commit -qm "host commit"
    run dr-sync
    [[ "$output" == *"dr-send"* ]]
}

@test "dr-sync: --no-fetch reports without contacting anything" {
    dr_mound_commit "$MOUND"
    dr-sync >/dev/null 2>&1          # get a tracking ref in place
    dr_mound_commit "$MOUND" "later, unfetched"
    run dr-sync --no-fetch
    [ "$status" -eq 0 ]
    # Still reports the first commit, but cannot know about the second.
    [[ "$output" != *"later, unfetched"* ]]
}

@test "dr-sync: an absent mound says so instead of failing at git" {
    DR_MOCK_STATE=absent run dr-sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
    [[ "$output" == *"dr-up"* ]]
}

@test "dr-sync: --check-only is 0 when the mound has nothing new" {
    run dr-sync --check-only
    [ "$status" -eq 0 ]
}

@test "dr-sync: --check-only is 1 when there are unfetched commits" {
    dr_mound_commit "$MOUND"
    run dr-sync --check-only
    [ "$status" -eq 1 ]
}

@test "dr-sync: --check-only is 0 again once they are fetched" {
    dr_mound_commit "$MOUND"
    dr-sync >/dev/null 2>&1
    run dr-sync --check-only
    [ "$status" -eq 0 ]
}

@test "dr-sync: --check-only is 2 when the mound cannot be reached" {
    # Break the URL rewrite so the fetch has nowhere to go. Unreachable must not
    # be reported as "nothing to lose".
    git config --unset-all "url.$MOUND.insteadOf"
    git config "url.$DR_TMP/does-not-exist.insteadOf" "ssh://$SANDBOX.sbx${REPO#/mnt}"
    run dr-sync --check-only
    [ "$status" -eq 2 ]
}

# --- dr-log and dr-diff ------------------------------------------------------

@test "dr-log: shows only what the agent added" {
    dr_mound_commit "$MOUND" "agent did a thing"
    dr-sync >/dev/null 2>&1
    run dr-log --oneline
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent did a thing"* ]]
    [[ "$output" != *"first"* ]]
}

@test "dr-diff: shows the agent's changes" {
    dr_mound_commit "$MOUND" "agent edit"
    dr-sync >/dev/null 2>&1
    run dr-diff
    [ "$status" -eq 0 ]
    [[ "$output" == *"agent.txt"* ]]
    [[ "$output" == *"+agent edit"* ]]
}

@test "dr-diff: three-dot means your own commits are not shown as reverts" {
    dr_mound_commit "$MOUND" "agent edit"
    printf 'mine\n' > host-only.txt
    git add -A && git commit -qm "host commit"
    dr-sync >/dev/null 2>&1
    run dr-diff
    # The agent's file appears; the host-only file must NOT appear as a deletion.
    [[ "$output" == *"agent.txt"* ]]
    [[ "$output" != *"host-only.txt"* ]]
}

@test "dr-log: says what to do when nothing has been fetched yet" {
    run dr-log
    [ "$status" -ne 0 ]
    [[ "$output" == *"dr-sync"* ]]
}

# --- dr-merge ----------------------------------------------------------------

@test "dr-merge: accepts the agent's work onto your branch" {
    dr_mound_commit "$MOUND" "agent work"
    dr-sync >/dev/null 2>&1
    run dr-merge
    [ "$status" -eq 0 ]
    run git log --oneline -1
    [[ "$output" == *"agent work"* ]]
    [ -f "$REPO/agent.txt" ]
}

@test "dr-merge: refuses on a dirty tree, and says why" {
    dr_mound_commit "$MOUND"
    dr-sync >/dev/null 2>&1
    printf 'wip\n' > wip.txt
    run dr-merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"uncommitted changes"* ]]
}

@test "dr-merge: nothing to merge is success, not an error" {
    dr-sync >/dev/null 2>&1
    run dr-merge
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to merge"* ]]
}

@test "dr-merge: --pick takes one commit" {
    # Distinct words, not "wanted"/"unwanted" - --grep is a substring match and
    # the second would match both.
    dr_mound_commit "$MOUND" "keepthis"
    dr_mound_commit "$MOUND" "discardthis"
    dr-sync >/dev/null 2>&1
    sha=$(git log --format=%H --grep=keepthis draugr/main | head -1)
    run dr-merge --pick "$sha"
    [ "$status" -eq 0 ]
    run git log --oneline -1
    [[ "$output" == *"keepthis"* ]]
    run git log --oneline
    [[ "$output" != *"discardthis"* ]]
}

# --- dr-rm's safety check ----------------------------------------------------

@test "dr-rm: refuses while the mound holds unfetched commits" {
    dr_mound_commit "$MOUND"
    run dr-rm --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"not fetched"* ]]
    [[ "$output" == *"dr-sync"* ]]
}

@test "dr-rm: --force destroys them anyway" {
    dr_mound_commit "$MOUND"
    run dr-rm --force
    [ "$status" -eq 0 ]
}

@test "dr-rm: proceeds once the commits are safely on the host" {
    dr_mound_commit "$MOUND"
    dr-sync >/dev/null 2>&1
    run dr-rm --yes
    [ "$status" -eq 0 ]
}

# --- the whole loop ----------------------------------------------------------

@test "the README's daily loop, end to end" {
    # dr-go is the only step that needs a terminal, so the agent's commit is
    # made directly in the stand-in mound; everything after it is verbatim.
    dr_mound_commit "$MOUND" "the agent's contribution"

    dr-sync  >/dev/null 2>&1
    dr-log   >/dev/null 2>&1
    dr-diff  >/dev/null 2>&1
    run dr-merge
    [ "$status" -eq 0 ]

    # The agent's commit is now on the host branch, by hash, with its authorship.
    run git log -1 --format='%an %s'
    [[ "$output" == "Agent the agent's contribution" ]]
}
