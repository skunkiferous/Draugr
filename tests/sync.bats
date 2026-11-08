#!/usr/bin/env bats
# The daily loop: dr-sync, dr-log, dr-diff, dr-merge, and the safety test of
# dr-rm.
#
# There is no sandbox here. `dr_fake_mound` uses url.<base>.insteadOf of git to
# point ssh://<name>.sbx/<path> at a local clone. Thus the fetch, the ref names
# and the commit count are all real. Only the transport is different.

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
    # `git remote get-url` applies the insteadOf rewrite, and shows the local
    # stand-in. The raw configuration value is what Draugr wrote.
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
    # Still reports the first commit, but cannot know the second.
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
    # Break the URL rewrite, so that the fetch has no target. Unreachable must
    # not be reported as "nothing to lose".
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
    # The file of the agent shows. The file only on the host must NOT show as a
    # deletion.
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
    # Different words, not "wanted"/"unwanted". --grep is a substring match, and
    # the second matches both.
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
    [[ "$output" == *"did not fetch"* ]]
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
    # dr-go is the only step that needs a terminal. Thus the test makes the
    # commit of the agent directly in the stand-in mound. All later steps are
    # real.
    dr_mound_commit "$MOUND" "the agent's contribution"

    dr-sync  >/dev/null 2>&1
    dr-log   >/dev/null 2>&1
    dr-diff  >/dev/null 2>&1
    run dr-merge
    [ "$status" -eq 0 ]

    # The commit of the agent is now on the host branch, by hash, with its
    # author.
    run git log -1 --format='%an %s'
    [[ "$output" == "Agent the agent's contribution" ]]
}

# --- branches the agent invented ----------------------------------------------
#
# The remote refspec is +refs/heads/*, so dr-sync always fetched ALL branches.
# Only the report was narrow. It looked at draugr/$DRAUGR_BRANCH and nothing
# else. Agents often work on a branch of their own. Then the work of a full
# session seemed to disappear. The commits were on the disk of the host, but
# dr-sync, dr-log and dr-status all said that nothing was there.
#
# Worse, --check-only also asked only about that branch, and dr-rm believes it
# before it destroys a mound.

# The agent makes up a branch name, as agents usually do.
mound_branch_commit() {
    git -C "$MOUND" checkout -q -b "$1" 2>/dev/null || git -C "$MOUND" checkout -q "$1"
    dr_mound_commit "$MOUND" "${2:-work on $1}"
}

@test "dr-sync: does not double-report the branch it already tracks" {
    # The tracked branch is reported as "ahead". A second listing under "not
    # tracking" makes the normal case look like the alarming one.
    dr_mound_commit "$MOUND" "on the tracked branch"
    run dr-sync
    [[ "$output" == *"1 new commit(s)"* ]]
    [[ "$output" != *"not tracking"* ]]
    [[ "$output" != *"NOT tracking"* ]]
}

@test "dr-sync: silent about other branches when the agent stayed on one" {
    # People stop reading a report that shows on each session. This report must
    # be believed on the day that it is important.
    dr_mound_commit "$MOUND" "ordinary work"
    run dr-sync
    [[ "$output" != *"tracking"* ]]
}

@test "dr-sync: names a branch you are not tracking" {
    mound_branch_commit sbx-kit-lua-deps
    run dr-sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"sbx-kit-lua-deps"* ]]
    [[ "$output" == *"do NOT track"* ]]
}

@test "dr-sync: tells you how to review it, and the hint works" {
    mound_branch_commit feature-x
    run dr-sync
    [[ "$output" == *"DRAUGR_BRANCH=feature-x dr-diff"* ]]

    # You must be able to paste the suggestion. DRAUGR_BRANCH is a normal
    # configuration key, so the environment overrides it for one command, with
    # no new flag. If this breaks, the report points at nothing.
    DRAUGR_BRANCH=feature-x run dr-log
    [ "$status" -eq 0 ]
    [[ "$output" == *"work on feature-x"* ]]
}

@test "dr-sync: says the commits are already on your disk" {
    # This sentence can save a day: they are fetched, not lost.
    mound_branch_commit feature-x
    run dr-sync
    [[ "$output" == *"already fetched"* ]]
}

# --- the remote's own HEAD -----------------------------------------------------
#
# Since git 2.49, `git fetch` creates refs/remotes/<remote>/HEAD by default
# (remote.<name>.followRemoteHEAD=create). That ref shortens to "draugr", not
# "draugr/HEAD". The guard that skips it missed it. Thus each sync on a new git
# reported your current branch as a branch that you do not track. The test makes
# the ref by hand, not by a fetch. Thus the tests give the same result on git
# 2.43 and on 2.49. If not, the test fails only on the machines with the bug.

# git points the ref at the checkout of the mound. That is the branch where the
# agent worked last. Thus the argument is important.
mound_head_ref() {
    git symbolic-ref refs/remotes/draugr/HEAD "refs/remotes/draugr/${1:-main}"
}

@test "dr-sync: the remote's own HEAD is not a branch the agent worked on" {
    dr_mound_commit "$MOUND" "on the tracked branch"
    dr-sync >/dev/null 2>&1
    mound_head_ref
    run dr-sync
    [[ "$output" == *"1 new commit(s)"* ]]
    [[ "$output" != *"tracking"* ]]
}

@test "dr-sync: the remote's HEAD does not take the review hint" {
    # The refs sort by full name. Thus refs/remotes/draugr/HEAD came FIRST, and
    # the hint named it, not the branch with work to review.
    mound_branch_commit feature-x
    dr-sync >/dev/null 2>&1
    mound_head_ref feature-x
    run dr-sync
    [[ "$output" == *"DRAUGR_BRANCH=feature-x dr-diff"* ]]
}

@test "dr-status: the remote's own HEAD is not listed there either" {
    # The same helper, the second caller. dr-status reported the false branch in
    # its own table, with a DRAUGR_BRANCH=draugr hint that goes nowhere.
    dr_mound_commit "$MOUND" "on the tracked branch"
    dr-sync >/dev/null 2>&1
    mound_head_ref
    run dr-status
    [[ "$output" != *"untracked"* ]]
}

@test "dr-sync: an invented branch is a warning when the tracked one is empty" {
    # "nothing new in the mound" with a quiet note after it reads as "all good".
    # When the tracked branch has nothing, this IS the news.
    mound_branch_commit feature-x
    run dr-sync
    [[ "$output" == *"nothing new in the mound"* ]]
    [[ "$output" == *"do NOT track"* ]]
}

# --- the hole dr-rm trusted ---------------------------------------------------

@test "dr-sync --check-only: 1 when work exists only on another branch" {
    # The guard had a hole exactly where agents really work. It asked the mound
    # only about refs/heads/$DRAUGR_BRANCH. Thus it answered "nothing to lose",
    # while two commits were on a branch of the agent.
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
    # You most need this report after dr-rm, when you ask "what did I keep?".
    # At that time, it refused to answer.
    mound_branch_commit feature-x
    dr-sync >/dev/null 2>&1
    DR_MOCK_STATE=absent run dr-sync --no-fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature-x"* ]]
}

@test "dr-sync: still refuses to FETCH from a mound that is gone" {
    # Only the report needs no mound now. A fetch really needs a sandbox.
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
    # "<ref> <count>", so the code must split the two halves before use.
    mound_branch_commit feature-x
    dr-sync >/dev/null 2>&1
    run dr-status
    [[ "$output" == *"DRAUGR_BRANCH=feature-x dr-diff"* ]]
}

# --- delivered, but not merged -----------------------------------------------
#
# dr-send puts your commits at refs/remotes/host/<branch> INSIDE the mound. On
# purpose, it does not move the branch of the agent. Thus draugr/<branch> stays
# behind. Before, dr-sync then always said "send them with dr-send". You sent,
# it still said send, and a second send did nothing. The messages gave no way
# out of the loop.
#
# The host/* refs of the mound are copied into refs/draugr/sent/*, so that the
# host can tell the two states apart. These tests assert on what the commands
# SAY, because that was wrong. The tests reach the internals through them.

# What dr-send does, without the sbx: put the host branch on refs/remotes/host/
# of the mound. On purpose, the own main of the mound does not move.
deliver() { git -C "$MOUND" fetch -q "$REPO" "main:refs/remotes/host/main"; }

host_commit() {
    printf '%s\n' "${1:-host work}" >> "$REPO/README.md"
    git -C "$REPO" commit -aqm "${1:-host commit}"
}

@test "dr-sync: says send when the mound has never seen them" {
    host_commit
    run dr-sync
    [[ "$output" == *"Send them with"* ]]
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
    # Ancestry, not equality. After one delivery, later commits must not also
    # look delivered.
    host_commit first
    deliver
    host_commit second
    run dr-sync
    [[ "$output" == *"Send them with"* ]]
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
    [[ "$output" == *"not in draugr/main. Use dr-send."* ]]
    [[ "$output" != *"delivered"* ]]
}

@test "the mirrored ref is not mistaken for a branch to review" {
    # refs/draugr/sent/* is outside refs/remotes/, on purpose. All refs there
    # mean "a branch in the mound", and this is the copy of OUR branch in the
    # mound. Under refs/remotes, it shows as agent work with no review.
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

# You can remove the mound while commits are ahead of the tracking ref. The ref
# stays, on purpose, because it is the only copy of the commits of the agent.
# But it then describes a mound that is gone. Its advice was `dr-send`, which
# refuses without a mound. The screen was the same before and after. Thus you
# learned that it was useless only after two tries.
@test "dr-status: with no mound, does not tell you to dr-send" {
    host_commit
    dr-sync >/dev/null 2>&1
    host_commit second
    DR_MOCK_STATE=absent run dr-status
    [[ "$output" != *"- dr-send"* ]]
}

@test "dr-status: with no mound, points at the command that does work" {
    host_commit
    dr-sync >/dev/null 2>&1
    host_commit second
    DR_MOCK_STATE=absent run dr-status
    [[ "$output" == *"dr-up clones them into the new mound"* ]]
}

# The absent case must not hide the normal one. With a mound, the advice is
# still dr-send.
@test "dr-status: with a mound, dr-send is still the answer" {
    host_commit
    dr-sync >/dev/null 2>&1
    host_commit second
    run dr-status
    [[ "$output" == *"not in draugr/main. Use dr-send."* ]]
}

# In the output of git, a staged mode change reads as "M  file", exactly as a
# rewrite does. On a /mnt/c checkout with core.fileMode=false, `git add` cannot
# make it. Thus the usual reading, "I edited that", is wrong. When you open the
# named file, it looks unchanged.
@test "dr-merge: a mode-only change is named as one, not as an edit" {
    dr_mound_commit "$MOUND"
    dr-sync >/dev/null 2>&1
    git -C "$REPO" config core.fileMode false
    git -C "$REPO" update-index --chmod=+x README.md
    run dr-merge
    [ "$status" -ne 0 ]
    [[ "$output" == *"mode 100644 => 100755, no content change"* ]]
}

@test "dr-merge: and says how to get past it" {
    dr_mound_commit "$MOUND"
    dr-sync >/dev/null 2>&1
    git -C "$REPO" config core.fileMode false
    git -C "$REPO" update-index --chmod=+x README.md
    run dr-merge
    [[ "$output" == *"git restore --staged"* ]]
}

# The note must not show on a normal edit. If it does, it is worse than no note.
@test "dr-merge: a real edit gets no mode note" {
    dr_mound_commit "$MOUND"
    dr-sync >/dev/null 2>&1
    printf 'wip\n' > wip.txt
    run dr-merge
    [ "$status" -ne 0 ]
    [[ "$output" != *"no content change"* ]]
    [[ "$output" != *"git restore --staged"* ]]
}

@test "dr_mode_note: a changed blob at a changed mode is not mode-only" {
    dr_load_common
    printf 'different\n' >> "$REPO/README.md"
    git -C "$REPO" config core.fileMode false
    git -C "$REPO" add README.md
    git -C "$REPO" update-index --chmod=+x README.md
    run dr_mode_note "$REPO" README.md
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}
