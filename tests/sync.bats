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

# --- branches the agent invented ----------------------------------------------
#
# The remote refspec is +refs/heads/*, so dr-sync always fetched EVERY branch.
# Only the report was narrow - it looked at draugr/$DRAUGR_BRANCH and nothing
# else. An agent that works on a branch of its own is ordinary behaviour, and it
# made a whole session's work appear to vanish: the commits were on the host's
# disk while dr-sync, dr-log and dr-status all said there was nothing there.
#
# Worse, --check-only asked about that one branch too, and dr-rm believes it
# before destroying a mound.

# The agent inventing a branch name, which is what agents habitually do.
mound_branch_commit() {
    git -C "$MOUND" checkout -q -b "$1" 2>/dev/null || git -C "$MOUND" checkout -q "$1"
    dr_mound_commit "$MOUND" "${2:-work on $1}"
}

@test "dr-sync: does not double-report the branch it already tracks" {
    # The tracked branch is reported as "ahead". Listing it a second time under
    # "not tracking" would make the ordinary case look like the alarming one.
    dr_mound_commit "$MOUND" "on the tracked branch"
    run dr-sync
    [[ "$output" == *"1 new commit(s)"* ]]
    [[ "$output" != *"not tracking"* ]]
    [[ "$output" != *"NOT tracking"* ]]
}

@test "dr-sync: silent about other branches when the agent stayed on one" {
    # A report that fires on every session is one people stop reading, and this
    # one has to be believed on the day it matters.
    dr_mound_commit "$MOUND" "ordinary work"
    run dr-sync
    [[ "$output" != *"tracking"* ]]
}

@test "dr-sync: names a branch you are not tracking" {
    mound_branch_commit sbx-kit-lua-deps
    run dr-sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"sbx-kit-lua-deps"* ]]
    [[ "$output" == *"NOT tracking"* ]]
}

@test "dr-sync: tells you how to review it, and the hint works" {
    mound_branch_commit feature-x
    run dr-sync
    [[ "$output" == *"DRAUGR_BRANCH=feature-x dr-diff"* ]]

    # The suggestion has to be paste-able: DRAUGR_BRANCH is an ordinary config
    # key, so the environment overrides it for one command and no new flag is
    # needed. If this breaks, the report is pointing at nothing.
    DRAUGR_BRANCH=feature-x run dr-log
    [ "$status" -eq 0 ]
    [[ "$output" == *"work on feature-x"* ]]
}

@test "dr-sync: says the commits are already on your disk" {
    # The sentence that would have saved a day: they are fetched, not stranded.
    mound_branch_commit feature-x
    run dr-sync
    [[ "$output" == *"already fetched"* ]]
}

@test "dr-sync: an invented branch is a warning when the tracked one is empty" {
    # "nothing new in the mound" immediately followed by a quiet note would read
    # as reassurance. When the tracked branch has nothing, this IS the news.
    mound_branch_commit feature-x
    run dr-sync
    [[ "$output" == *"nothing new in the mound"* ]]
    [[ "$output" == *"NOT tracking"* ]]
}

# --- the hole dr-rm trusted ---------------------------------------------------

@test "dr-sync --check-only: 1 when work exists only on another branch" {
    # The guard had a hole exactly where agents actually behave: it asked the
    # mound about refs/heads/$DRAUGR_BRANCH and nothing else, so this answered
    # "nothing to lose" while two commits sat on a branch of the agent's own.
    mound_branch_commit feature-x
    run dr-sync --check-only
    [ "$status" -eq 1 ]
}

@test "dr-sync --check-only: 0 again once that branch is fetched" {
    mound_branch_commit feature-x
    dr-sync >/dev/null 2>&1
    run dr-sync --check-only
    [ "$status" -eq 0 ]
}

@test "dr-rm: refuses while an invented branch holds unfetched commits" {
    mound_branch_commit feature-x
    run dr-rm
    [ "$status" -ne 0 ]
}

@test "dr-rm: proceeds once that branch has been fetched" {
    mound_branch_commit feature-x
    dr-sync >/dev/null 2>&1
    run dr-rm --yes
    [ "$status" -eq 0 ]
}

# --- reporting without a mound ------------------------------------------------

@test "dr-sync --no-fetch: works after the mound is gone" {
    # The moment you most want this report - after dr-rm, asking "what did I
    # keep?" - was the one moment it refused to answer.
    mound_branch_commit feature-x
    dr-sync >/dev/null 2>&1
    DR_MOCK_STATE=absent run dr-sync --no-fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature-x"* ]]
}

@test "dr-sync: still refuses to FETCH from a mound that is gone" {
    # Only the reporting was loosened; fetching genuinely needs a sandbox.
    DR_MOCK_STATE=absent run dr-sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"--no-fetch"* ]]
}

@test "dr-status: shows a branch you are not tracking" {
    mound_branch_commit feature-x
    dr-sync >/dev/null 2>&1
    run dr-status
    [[ "$output" == *"untracked"* ]]
    [[ "$output" == *"feature-x"* ]]
}

@test "dr-status: the command it suggests has no stray count in it" {
    # "DRAUGR_BRANCH=feature-x 2 dr-diff" is not a command. The line is
    # "<ref> <count>", so both halves have to be split off before use.
    mound_branch_commit feature-x
    dr-sync >/dev/null 2>&1
    run dr-status
    [[ "$output" == *"DRAUGR_BRANCH=feature-x dr-diff"* ]]
}

# --- delivered, but not merged -----------------------------------------------
#
# dr-send leaves your commits at refs/remotes/host/<branch> INSIDE the mound and
# deliberately does not move the agent's branch. draugr/<branch> therefore stays
# behind afterwards, which used to make dr-sync answer "send them with dr-send"
# for ever: you sent, it still said send, re-sending was a no-op, and there was
# no way out of the loop from the messages alone.
#
# The mound's own host/* refs are mirrored into refs/draugr/sent/* so the host can
# tell the two states apart. These assert on what the commands SAY, because that
# is the thing that was wrong - the internals are reached through them.

# What dr-send does, minus the sbx: put the host branch on the mound's
# refs/remotes/host/. The mound's own main is deliberately left where it was.
deliver() { git -C "$MOUND" fetch -q "$REPO" "main:refs/remotes/host/main"; }

host_commit() {
    printf '%s\n' "${1:-host work}" >> "$REPO/README.md"
    git -C "$REPO" commit -aqm "${1:-host commit}"
}

@test "dr-sync: says send when the mound has never seen them" {
    host_commit
    run dr-sync
    [[ "$output" == *"send them with"* ]]
    [[ "$output" != *"not merged"* ]]
}

@test "dr-sync: says merge, not send, once they are delivered" {
    host_commit
    deliver
    run dr-sync
    [[ "$output" == *"not merged"* ]]
    [[ "$output" == *"dr-send --merge"* ]]
    [[ "$output" != *"send them with"* ]]
}

@test "dr-sync: mirrors the mound's host ref so the host can see it" {
    host_commit
    deliver
    run dr-sync
    [ "$(git -C "$REPO" rev-parse refs/draugr/sent/main)" = "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "dr-sync: a commit made AFTER the send is unsent again" {
    # Ancestry, not equality. Delivering once must not make everything committed
    # afterwards look delivered too.
    host_commit first
    deliver
    host_commit second
    run dr-sync
    [[ "$output" == *"send them with"* ]]
    [[ "$output" != *"not merged"* ]]
}

@test "dr-status: names --merge rather than repeating dr-send" {
    host_commit
    deliver
    dr-sync >/dev/null 2>&1
    run dr-status
    [[ "$output" == *"delivered, not merged"* ]]
    [[ "$output" == *"dr-send --merge"* ]]
}

@test "dr-status: still says dr-send when nothing has been delivered" {
    host_commit
    dr-sync >/dev/null 2>&1
    run dr-status
    [[ "$output" == *"not in draugr/main - dr-send"* ]]
    [[ "$output" != *"delivered"* ]]
}

@test "the mirrored ref is not mistaken for a branch to review" {
    # refs/draugr/sent/* is deliberately outside refs/remotes/: everything there
    # means "a branch in the mound", and this is the mound's copy of OUR branch.
    # Under refs/remotes it would be reported as unreviewed agent work.
    host_commit
    deliver
    dr-sync >/dev/null 2>&1
    run dr-status
    [[ "$output" != *"sent/main"* ]]

    run dr-sync
    [[ "$output" != *"sent/main"* ]]
}

@test "the extra refspec is added once, not once per sync" {
    dr-sync >/dev/null 2>&1
    dr-sync >/dev/null 2>&1
    dr-sync >/dev/null 2>&1
    [ "$(git -C "$REPO" config --get-all remote.draugr.fetch | grep -c 'draugr/sent')" -eq 1 ]
}
