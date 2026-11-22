#!/usr/bin/env bats
# DRAUGR_DATA: the filter rules, the matcher, and the clean-tree exemption.
#
# These tests run the rules with REAL rsync, between two local directories. No
# sandbox is necessary. The filter language belongs to rsync, so only rsync can
# decide it with certainty.

load helper

setup() {
    dr_test_setup
    dr_load_common
}

teardown() { dr_test_teardown; }

# A tree with one of each difficult shape: a data dir, a nested data file, a
# matching extension at the root AND deep in the source tree, and source files
# that must never go with the data.
make_tree() {
    mkdir -p "$DR_TMP/src/tmp/deep" "$DR_TMP/src/scratch/raw" \
             "$DR_TMP/src/scratch/cooked" "$DR_TMP/src/lib" "$DR_TMP/dst"
    touch "$DR_TMP/src/README.md" \
          "$DR_TMP/src/a.parquet" \
          "$DR_TMP/src/lib/b.parquet" \
          "$DR_TMP/src/lib/code.py" \
          "$DR_TMP/src/tmp/x.bin" \
          "$DR_TMP/src/tmp/deep/y.bin" \
          "$DR_TMP/src/scratch/raw/r1" \
          "$DR_TMP/src/scratch/cooked/c1"
}

# DRAUGR_DATA needs rsync at BOTH ends of the transfer, and a mound has none.
# Without a guard, `transferred` prints nothing, every assertion about what must
# NOT travel passes on an empty list, and the few that name a file that must
# travel fail. In a mound that was seven failures and one pass for the wrong
# reason. A skip says what happened.
need_rsync() {
    command -v rsync >/dev/null 2>&1 || skip "no rsync - DRAUGR_DATA needs it at both ends"
}

# What rsync really transfers, with the rules that DRAUGR_DATA makes.
transferred() {
    local filters
    mapfile -t filters < <(dr_data_filters)
    rsync -a -m --dry-run --out-format='%n' "${filters[@]}" \
        "$DR_TMP/src/" "$DR_TMP/dst/" | grep -v '/$' | sort
}

# --- internal files that must never travel, whatever DRAUGR_DATA says --------

@test "data filters: .git never travels, even for DRAUGR_DATA=*" {
    need_rsync
    make_tree
    # A real .git, because the bug is that rsync walks into it as into each
    # directory.
    mkdir -p "$DR_TMP/src/.git/hooks" "$DR_TMP/src/.draugr/tmp"
    touch "$DR_TMP/src/.git/config" "$DR_TMP/src/.git/hooks/pre-commit.sample" \
          "$DR_TMP/src/.draugr/tmp/leaked-memory.md"

    DRAUGR_DATA="*"
    run transferred
    # A push of the .git of the host over the one of the mound clone replaces
    # the git metadata of the agent, also its remote.
    [[ "$output" != *".git/"* ]]
    [[ "$output" != *".draugr/"* ]]
    # The real data still moves. The guard is narrow, not a full refusal.
    [[ "$output" == *"a.parquet"* ]]
    [[ "$output" == *"tmp/x.bin"* ]]
}

@test "data filters: an innocent extension pattern cannot reach into .git" {
    need_rsync
    make_tree
    mkdir -p "$DR_TMP/src/.git/hooks"
    touch "$DR_TMP/src/.git/hooks/pre-commit.sample" "$DR_TMP/src/keep.sample"

    # Entries with no slash have no anchor, and match at all depths. Thus this
    # once took the own hook templates of git.
    DRAUGR_DATA="*.sample"
    run transferred
    [[ "$output" != *".git"* ]]
    [[ "$output" == *"keep.sample"* ]]
}

@test "dr_data_matches: agrees with the filters about the plumbing" {
    DRAUGR_DATA="*"
    # A match here with no transfer removes a path from the clean-tree test, and
    # then never sends it. The two functions exist to prevent that difference.
    # Tested for both, because "*" matches all else.
    run dr_data_matches ".git/config"
    [ "$status" -ne 0 ]
    run dr_data_matches ".draugr/kit.applied"
    [ "$status" -ne 0 ]
    run dr_data_matches ".gitignore"
    [ "$status" -eq 0 ]
}

@test "data filters: .gitignore is not caught by the .git exclusion" {
    need_rsync
    make_tree
    touch "$DR_TMP/src/.gitignore"

    # rsync patterns match whole names, not prefixes. Pin that, because you can
    # legitimately want .gitignore on both sides.
    DRAUGR_DATA="*"
    run transferred
    [[ "$output" == *".gitignore"* ]]
}

# --- the filter rules, against real rsync ------------------------------------

@test "data filters: a directory entry takes its contents and nothing beside it" {
    need_rsync
    make_tree
    DRAUGR_DATA="scratch/raw/"
    run transferred
    [ "$output" = "scratch/raw/r1" ]
}

@test "data filters: a ** pattern takes the whole subtree" {
    need_rsync
    make_tree
    DRAUGR_DATA="tmp/**"
    run transferred
    [[ "$output" == *"tmp/x.bin"* ]]
    [[ "$output" == *"tmp/deep/y.bin"* ]]
    [[ "$output" != *"README"* ]]
}

@test "data filters: a bare extension matches at every depth" {
    need_rsync
    make_tree
    DRAUGR_DATA="*.parquet"
    run transferred
    [[ "$output" == *"a.parquet"* ]]
    [[ "$output" == *"lib/b.parquet"* ]]
    [[ "$output" != *"code.py"* ]]
}

@test "data filters: source files are never swept up" {
    need_rsync
    make_tree
    DRAUGR_DATA="tmp/** *.parquet scratch/raw/"
    run transferred
    [[ "$output" != *"README.md"* ]]
    [[ "$output" != *"code.py"* ]]
    [[ "$output" != *"cooked"* ]]
}

@test "data filters: all three shapes together" {
    need_rsync
    make_tree
    DRAUGR_DATA="tmp/** *.parquet scratch/raw/"
    run transferred
    [ "$output" = "a.parquet
lib/b.parquet
scratch/raw/r1
tmp/deep/y.bin
tmp/x.bin" ]
}

# --- the matcher, which must give the same result as the rules above ---------

@test "dr_data_matches: agrees with the filters, shape by shape" {
    DRAUGR_DATA="tmp/** *.parquet scratch/raw/"
    dr_data_matches "tmp/x.bin"
    dr_data_matches "tmp/deep/y.bin"
    dr_data_matches "a.parquet"
    dr_data_matches "lib/b.parquet"
    dr_data_matches "scratch/raw/r1"
}

@test "dr_data_matches: rejects what the filters exclude" {
    DRAUGR_DATA="tmp/** *.parquet scratch/raw/"
    ! dr_data_matches "README.md" || return 1
    ! dr_data_matches "lib/code.py" || return 1
    ! dr_data_matches "scratch/cooked/c1"
}

@test "dr_data_matches: a directory entry does not match a lookalike prefix" {
    DRAUGR_DATA="scratch/raw/"
    dr_data_matches "scratch/raw/r1"
    ! dr_data_matches "scratch/rawdata/r1"
}

@test "dr_data_matches: an empty DRAUGR_DATA matches nothing" {
    DRAUGR_DATA=
    ! dr_data_matches "anything.parquet"
}

# --- the clean-tree exemption ------------------------------------------------

@test "dr_data_dirty_only: true when only data files are dirty" {
    repo=$(dr_make_repo)
    cd "$repo" || return 1
    DRAUGR_DATA="tmp/**"
    mkdir -p tmp && printf 'x\n' > tmp/churn.bin
    dr_data_dirty_only "$repo"
}

@test "dr_data_dirty_only: false when a source file is dirty too" {
    repo=$(dr_make_repo)
    cd "$repo" || return 1
    DRAUGR_DATA="tmp/**"
    mkdir -p tmp && printf 'x\n' > tmp/churn.bin
    printf 'edit\n' >> README.md
    ! dr_data_dirty_only "$repo"
}

@test "dr_data_dirty_only: false when DRAUGR_DATA is empty" {
    repo=$(dr_make_repo)
    cd "$repo" || return 1
    DRAUGR_DATA=
    printf 'edit\n' >> README.md
    ! dr_data_dirty_only "$repo"
}

# --- the name of what really blocks -----------------------------------------
#
# The exemption is all or nothing. One dirty source file stops the session, also
# when all else is data. That is on purpose. But the report was the full output
# of `git status --short`. Thus the one important file came at the bottom of a
# list of exempt ones, and DRAUGR_DATA looked broken.

@test "dr_data_dirty_blockers: exempt files are left out" {
    repo=$(dr_make_repo)
    printf 'a\n' > "$repo/data.tsv"
    printf 'b\n' > "$repo/script.sh"
    DRAUGR_DATA="*.tsv" run dr_data_dirty_blockers "$repo"
    [[ "$output" == *"script.sh"* ]]
    [[ "$output" != *"data.tsv"* ]]
}

@test "dr_data_dirty_blockers: everything, when nothing is exempt" {
    repo=$(dr_make_repo)
    printf 'a\n' > "$repo/data.tsv"
    printf 'b\n' > "$repo/script.sh"
    DRAUGR_DATA= run dr_data_dirty_blockers "$repo"
    [[ "$output" == *"data.tsv"* ]]
    [[ "$output" == *"script.sh"* ]]
}

@test "dr_data_dirty_blockers: nothing, when the tree is only data" {
    repo=$(dr_make_repo)
    printf 'a\n' > "$repo/data.tsv"
    DRAUGR_DATA="*.tsv" run dr_data_dirty_blockers "$repo"
    [ -z "$output" ]
}

@test "dr_data_dirty_blockers: a rename is judged by its destination" {
    # The same rule as dr_data_dirty_only. A rename of a source file TO a data
    # name makes it data. The reverse makes it a blocker.
    repo=$(dr_make_repo)
    printf 'a\n' > "$repo/data.tsv"
    git -C "$repo" add -A
    git -C "$repo" commit -qm data
    git -C "$repo" mv data.tsv notes.md
    DRAUGR_DATA="*.tsv" run dr_data_dirty_blockers "$repo"
    [[ "$output" == *"notes.md"* ]]
}

# --- a review of what a pull brings -----------------------------------------
#
# dr-data pull writes bytes from the agent onto the host, with no commit to read
# first. These three helpers are the step between "rsync said 12 files" and a
# reviewer who really saw what arrives.

@test "dr_data_path_safe: an ordinary repo-relative path is fine" {
    dr_data_path_safe "tmp/out/report.csv"
}

@test "dr_data_path_safe: an absolute path is refused" {
    ! dr_data_path_safe "/etc/passwd"
}

@test "dr_data_path_safe: a leading .. is refused" {
    ! dr_data_path_safe "../escape"
}

@test "dr_data_path_safe: a .. buried mid-path is refused too" {
    # The important one. rsync sanitizes this, but Draugr does the write, and
    # must not depend on the version of rsync.
    ! dr_data_path_safe "out/../../escape"
}

@test "dr_data_path_safe: a bare .. is refused" {
    ! dr_data_path_safe ".."
}

@test "dr_data_path_safe: an empty name is refused" {
    ! dr_data_path_safe ""
}

@test "dr_data_path_safe: a newline in a name is refused" {
    # Not only a traversal question. Each caller parses the incoming list with
    # one name on each line. Thus a newline silently cuts the review itself.
    ! dr_data_path_safe "$(printf "bad\nname")"
}

@test "dr_data_path_safe: terminal escapes in a name are refused" {
    # A filename that redraws the screen can hide the rest of the report.
    ! dr_data_path_safe "$(printf "esc\033[2Jgone")"
}

@test "dr_data_exec_shaped: flags interpreted scripts" {
    dr_data_exec_shaped "build.sh"
    dr_data_exec_shaped "out/train.py"
    dr_data_exec_shaped "deep/nested/tool.rb"
    dr_data_exec_shaped "setup.ps1"
}

@test "dr_data_exec_shaped: flags native binaries and libraries" {
    dr_data_exec_shaped "agent.exe"
    dr_data_exec_shaped "lib/helper.so"
    dr_data_exec_shaped "lib/helper.so.6"
}

@test "dr_data_exec_shaped: flags things a toolchain runs for you" {
    dr_data_exec_shaped "Makefile"
    dr_data_exec_shaped "Dockerfile"
    dr_data_exec_shaped "Dockerfile.prod"
}

@test "dr_data_exec_shaped: stays quiet on ordinary data" {
    # The important half. People learn to ignore a warning that fires on each
    # parquet file, and then it protects nothing.
    ! dr_data_exec_shaped "model.parquet" || return 1
    ! dr_data_exec_shaped "report.csv" || return 1
    ! dr_data_exec_shaped "notes.txt" || return 1
    ! dr_data_exec_shaped "tmp/x.bin" || return 1
    ! dr_data_exec_shaped "capture.ts"
}

@test "dr_data_exec_shaped: judges the basename, not the directory" {
    dr_data_exec_shaped "a/b/c/run.sh"
    ! dr_data_exec_shaped "scripts.sh/data.csv"
}

@test "dr_data_is_text: plain text is text" {
    printf "hello\nworld\n" > "$DR_TMP/t.txt"
    dr_data_is_text "$DR_TMP/t.txt"
}

@test "dr_data_is_text: a NUL byte means binary" {
    printf "text\000more\n" > "$DR_TMP/t.nul"
    ! dr_data_is_text "$DR_TMP/t.nul"
}

@test "dr_data_is_text: a real binary format is binary" {
    printf "hello world\n" | gzip > "$DR_TMP/t.gz"
    ! dr_data_is_text "$DR_TMP/t.gz"
}

@test "dr_data_is_text: an empty file counts as text" {
    # So that "the agent emptied this file" shows as a diff, and is not hidden
    # as unreadable.
    : > "$DR_TMP/t.empty"
    dr_data_is_text "$DR_TMP/t.empty"
}

@test "dr_data_is_text: only the first 8 KB is judged" {
    # A huge CSV with one stray NUL at the end must still get a diff. A read of
    # a full 4 GB file to decide removes the benefit.
    head -c 20000 /dev/zero | tr "\000" "a" > "$DR_TMP/t.big"
    printf "\000" >> "$DR_TMP/t.big"
    dr_data_is_text "$DR_TMP/t.big"
}

# --- one name on the sender, another file on the host -----------------------
#
# The sender is Linux, where .GIT and .git are two directories. The destination
# is a Windows drive, where they are one. Measured with real rsync 3.2.7 and
# `--exclude=.git` in force: a sender's `.GIT/hooks-marker` arrived as
# `.git/hooks-marker`, and a sender's `GIT~1/config` OVERWROTE `.git/config`
# through the 8.3 short name that this volume still generates.
#
# .git/config decides what git RUNS for you, so this is the file the review was
# built to protect, reached by a spelling the review did not know.

@test "data filters: another case of .git never travels" {
    need_rsync
    make_tree
    mkdir -p "$DR_TMP/src/.GIT/hooks" "$DR_TMP/src/.Draugr"
    touch "$DR_TMP/src/.GIT/config" "$DR_TMP/src/.Draugr/kit.applied"

    DRAUGR_DATA="*"
    run transferred
    [[ "$output" != *".GIT"* ]]
    [[ "$output" != *".Draugr"* ]]
    # The real data still moves. A refusal of everything would pass this test
    # and break the command.
    [[ "$output" == *"a.parquet"* ]]
}

@test "data filters: the 8.3 alias of host metadata never travels" {
    need_rsync
    make_tree
    mkdir -p "$DR_TMP/src/GIT~1" "$DR_TMP/src/DRAUGR~1"
    touch "$DR_TMP/src/GIT~1/config" "$DR_TMP/src/DRAUGR~1/kit.applied"

    DRAUGR_DATA="*"
    run transferred
    [[ "$output" != *"GIT~1"* ]]
    [[ "$output" != *"DRAUGR~1"* ]]
    [[ "$output" == *"a.parquet"* ]]
}

@test "dr_data_matches: another case of the plumbing is still not data" {
    DRAUGR_DATA="*"
    run dr_data_matches ".GIT/config"
    [ "$status" -ne 0 ]
    run dr_data_matches "GIT~1/config"
    [ "$status" -ne 0 ]
    run dr_data_matches "out/.Draugr/tmp/x"
    [ "$status" -ne 0 ]
    # The trailing-dot form, which only this side can be asked about:
    # dr_data_path_safe refuses every trailing dot outright, so the stripping
    # inside dr_name_reserved_meta is load-bearing HERE and nowhere else.
    run dr_data_matches ".git./config"
    [ "$status" -ne 0 ]
    run dr_data_matches ".GIT /hooks/x"
    [ "$status" -ne 0 ]
    # And the exemption still works for real data, at any depth.
    run dr_data_matches "out/report.csv"
    [ "$status" -eq 0 ]
}

@test "dr_data_path_safe: another case of host metadata is refused" {
    ! dr_data_path_safe ".GIT/config" || return 1
    ! dr_data_path_safe ".Git/config" || return 1
    ! dr_data_path_safe ".DRAUGR/tmp" || return 1
    # Not only at the front: a repo can hold a nested checkout.
    ! dr_data_path_safe "out/.GIT/config"
}

@test "dr_data_path_safe: the 8.3 alias of host metadata is refused" {
    # Measured: a write through GIT~1 is a write to .git on this drive.
    ! dr_data_path_safe "GIT~1/config" || return 1
    ! dr_data_path_safe "git~1/config" || return 1
    ! dr_data_path_safe "DRAUGR~2/tmp"
}

@test "dr_data_path_safe: a trailing dot or space is refused" {
    # Win32 strips both before it looks the name up, so each of these is a
    # name for a different file than the one the review printed.
    ! dr_data_path_safe ".git./config" || return 1
    ! dr_data_path_safe ".git /config" || return 1
    ! dr_data_path_safe "out/report." || return 1
    ! dr_data_path_safe "out/report "
}

@test "dr_data_path_safe: a backslash or a colon is refused" {
    # A backslash is a SEPARATOR on the destination, so this is three
    # components there and one here. A colon is a drive prefix or an alternate
    # data stream.
    ! dr_data_path_safe 'out\.git\config' || return 1
    ! dr_data_path_safe "C:/data/x" || return 1
    ! dr_data_path_safe "out/report.csv:hidden"
}

@test "dr_data_path_safe: a name of nothing but dots is refused" {
    ! dr_data_path_safe ".../x" || return 1
    ! dr_data_path_safe "out/...."
}

@test "dr_data_path_safe: the names people really transfer still pass" {
    # The other half of every refusal above. A guard that refuses .gitignore
    # or a directory called my.git is a guard people turn off.
    dr_data_path_safe ".gitignore"
    dr_data_path_safe ".gitattributes"
    dr_data_path_safe "out/my.git/notes.md"
    dr_data_path_safe "scratch/raw/r1"
    dr_data_path_safe "a.b/c-d_e+f/g.parquet"
    dr_data_path_safe "data/~tilde~/x"
}

@test "dr_data_exec_shaped: an uppercase extension is still runnable" {
    # `case` is case sensitive, and Windows resolves an extension without
    # regard to case. So payload.PS1 answered "not runnable" on a destination
    # that runs it.
    dr_data_exec_shaped "payload.PS1"
    dr_data_exec_shaped "SETUP.CMD"
    dr_data_exec_shaped "out/Tool.Exe"
    dr_data_exec_shaped "deep/Dockerfile.PROD"
    dr_data_exec_shaped "MAKEFILE"
    dr_data_exec_shaped "installer.AppImage"
}

# --- staging goes outside the repository ------------------------------------
#
# dr_stage used to build $DR_REPO/.draugr/tmp/$$, delete it, and recreate it.
# A mound with the repository bind-mounted writes that path, and a link there
# redirects both the deletion and everything staged afterwards.

need_win_stage() {
    # sbx cp can only reach a Windows path, so the root must be a real one.
    REPO=$(dr_make_win_repo) || skip "no writable Windows drive path"
    DR_REPO=$REPO
}

@test "dr_stage: the staging directory is not in the repository" {
    need_win_stage
    dr_stage
    [ -d "$DR_STAGE" ]
    [[ "$DR_STAGE" != "$DR_REPO"/* ]]
    # sbx needs the Windows spelling of the same directory.
    [[ "$DR_STAGE_WIN" == [A-Z]:'\'* ]]
    rm -rf "$DR_STAGE"
}

@test "dr_stage: two runs get two directories, and neither is deleted" {
    need_win_stage
    dr_stage
    local first=$DR_STAGE
    printf 'x\n' > "$first/keep"
    dr_stage
    local second=$DR_STAGE
    [ "$first" != "$second" ]
    # The old code deleted a predictable path on the way in. This file is the
    # proof that nothing is deleted to make room any more.
    [ -f "$first/keep" ]
    [ -d "$second" ]
    rm -rf "$first" "$second"
}

@test "dr_stage: a staging root behind a link is refused" {
    need_win_stage
    # NOT $DR_WIN_TMP: dr_make_win_repo runs in a command substitution, so its
    # export dies with that subshell (helper.bash says so at length). The
    # parent of the repo is the same directory, and it is still here.
    local wintmp
    wintmp=$(dirname "$REPO")
    mkdir -p "$wintmp/elsewhere"
    ln -s "$wintmp/elsewhere" "$wintmp/stage-link" 2>/dev/null \
        || skip "this drive does not take a symlink"
    DRAUGR_STAGE_ROOT="$wintmp/stage-link"
    run dr_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"goes through a link"* ]]
    # And nothing was staged through it.
    [ -z "$(ls -A "$wintmp/elsewhere")" ]
}

# --- an empty preview is not "nothing to pull" ------------------------------
#
# The review of an incoming pull was `rsync … 2>/dev/null | grep -v '/$' ||
# true`, which is GREP's status with even that discarded. An unreachable mound
# therefore produced an empty list, every caller read it as "this pull lands
# nothing", and the real transfer ran unreviewed. That is finding F07.
#
# A stand-in rsync, because the mound is the one half of a transfer that no
# test can reach. It cannot live in tests/mocks: the filter tests above need
# the real one, and tests/mocks comes first on PATH for every test.
#
# IT STANDS IN FOR ONE LEG ONLY. A staged pull has two: mound -> staging,
# which is the unreachable one, and staging -> repository, which is an
# ordinary local copy. Faking the second would mean faking the filters,
# --delete and --link-dest, and those are the part of publication worth
# testing. So a path with a colon in it is the mound, and every other call is
# handed to the real rsync.
fake_rsync() {
    mkdir -p "$DR_TMP/fakebin"
    export DR_FAKE_RSYNC_LOG="$DR_TMP/rsync-real.log"
    export DR_FAKE_RSYNC_MODE=$1
    export DR_FAKE_MOUND="$DR_TMP/fakemound"
    # Resolved BEFORE the stand-in goes on PATH, or it would find itself.
    DR_REAL_RSYNC=$(command -v rsync) || return 1
    export DR_REAL_RSYNC
    mkdir -p "$DR_FAKE_MOUND"
    : > "$DR_FAKE_RSYNC_LOG"
    cat > "$DR_TMP/fakebin/rsync" <<'SH'
#!/usr/bin/env bash
# The dry run answers the way a measured rsync answers. A real call from the
# mound hands over whatever $DR_FAKE_MOUND holds, which is how a test decides
# what "arrived" - names, types and all.
#
# Every call it serves is written down, so a test can prove that a refusal
# happened BEFORE anything was published:
#   REAL   a transfer from the mound
#   LOCAL  a leg handed to the real rsync (publication)
# A dry run is not logged, so an empty log still means "nothing moved".
#
# It renders --out-format itself, exactly as rsync does. So a name arrives
# with whatever marker the caller asked for, and a caller that asks for none
# gets none. Without that, a test could not tell the two apart.
set -u
fmt='%n'
pos=()
for a in "$@"; do
    case "$a" in
        --out-format=*) fmt=${a#--out-format=} ;;
        -*) ;;
        *)  pos+=("$a") ;;
    esac
done
# The last two words that are not options are the source and the destination.
src=''; dst=''
if [ "${#pos[@]}" -ge 2 ]; then
    src=${pos[${#pos[@]}-2]}
    dst=${pos[${#pos[@]}-1]}
fi

case "$src$dst" in
    *:*) ;;
    *)  printf 'LOCAL %s\n' "$*" >> "$DR_FAKE_RSYNC_LOG"
        exec "$DR_REAL_RSYNC" "$@" ;;
esac

case " $* " in
    *" --dry-run "*)
        case "$DR_FAKE_RSYNC_MODE" in
            fail)
                printf 'rsync: connection unexpectedly closed\n' >&2
                exit 12 ;;
            chatter)
                # Measured on rsync 3.2.7, and it goes to STDOUT, where the
                # names are.
                printf 'skipping non-regular file "payload"\n'
                exit 0 ;;
            *)
                for n in ${DR_FAKE_FORECAST:-report.csv}; do
                    printf '%s\n' "${fmt//%n/$n}"
                done
                exit 0 ;;
        esac ;;
esac

printf 'REAL %s\n' "$*" >> "$DR_FAKE_RSYNC_LOG"
case "$DR_FAKE_RSYNC_MODE" in
    fail)
        printf 'rsync: connection unexpectedly closed\n' >&2
        exit 12 ;;
esac
# -a, so a symlink in the fixture arrives as a symlink. That is the point of
# one of the tests below.
if [ -n "$(ls -A "$DR_FAKE_MOUND" 2>/dev/null)" ]; then
    cp -a "$DR_FAKE_MOUND/." "$dst" || exit 11
fi
exit 0
SH
    chmod +x "$DR_TMP/fakebin/rsync"
    export PATH="$DR_TMP/fakebin:$PATH"
}

setup_pull() {
    REPO=$(dr_make_win_repo) || return 1
    cd "$REPO" || return 1
    export DR_MOCK_STATE=running
    export DRAUGR_DATA="*"
    # Not the real %LOCALAPPDATA%: a refused pull leaves its staged files for
    # the trap to remove, and some of the names below are ones nobody wants
    # left in their profile if a test dies between the two.
    export DRAUGR_STAGE_ROOT="$(dirname "$REPO")/pull-stage"
    return 0
}

@test "dr-data diff: a failed preview stops the review" {
    setup_pull || skip "no writable Windows drive path"
    fake_rsync fail
    run dr-data diff
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not preview"* ]]
    # The whole finding in one assertion: no bytes moved on an empty review.
    [ ! -s "$DR_FAKE_RSYNC_LOG" ]
}

@test "dr-data diff: a line that is not a file name stops the review" {
    setup_pull || skip "no writable Windows drive path"
    fake_rsync chatter
    run dr-data diff
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot tell what a pull would land"* ]]
    [ ! -s "$DR_FAKE_RSYNC_LOG" ]
}

@test "dr-data pull: a failed transfer publishes nothing" {
    # F07's shape, in the place a staged pull keeps it: the transfer IS the
    # review here, so a failed one cannot become an empty review that passes.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync fail
    run dr-data pull -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"rsync failed"* ]]
    grep -q '^REAL' "$DR_FAKE_RSYNC_LOG"
    ! grep -q '^LOCAL' "$DR_FAKE_RSYNC_LOG" || return 1
}

@test "dr-data pull: the files that arrived are published" {
    # The other half. A review that refuses everything protects nothing,
    # because nobody keeps using it.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    mkdir -p "$DR_FAKE_MOUND/sub"
    printf 'a,b\n1,2\n' > "$DR_FAKE_MOUND/report.csv"
    printf 'notes\n' > "$DR_FAKE_MOUND/sub/notes.txt"
    run dr-data pull -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"pull complete"* ]]
    # The bytes, not just the names: publication is a second leg now, and a
    # leg that creates empty files would pass a name check.
    [ "$(cat "$REPO/report.csv")" = "$(cat "$DR_FAKE_MOUND/report.csv")" ]
    [ -f "$REPO/sub/notes.txt" ]
    # And the staging directory is gone, whatever happened.
    [ -z "$(find "$DRAUGR_STAGE_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]
}

@test "dr-data pull: the review judges what arrived, not what was forecast" {
    # THIS IS U01. The forecast is clean and the tree that arrives is not, and
    # a pull that reviewed the forecast would publish the difference.
    #
    # `.git.` is the name that makes it matter. The four metadata excludes are
    # exact patterns and do not match it, so it crosses; a Windows drive
    # resolves it to `.git`; and `.git/config` decides what git runs. The only
    # thing in Draugr that refuses that name is dr_data_path_safe, which used
    # to be applied to a dry run's output and is now applied to the files.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    printf 'a,b\n' > "$DR_FAKE_MOUND/report.csv"
    printf '[core]\n' > "$DR_FAKE_MOUND/.git." || skip "no trailing-dot names here"
    run dr-data pull -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to pull"* ]]
    [[ "$output" == *"NOTHING WAS PUBLISHED"* ]]
    [[ "$output" == *".git."* ]]
    # One refused name stops the whole pull, so the file beside it is not
    # published either.
    [ ! -e "$REPO/report.csv" ]
    [ ! -e "$REPO/.git." ]
    ! grep -q '^LOCAL' "$DR_FAKE_RSYNC_LOG" || return 1
}

@test "dr-data pull: a runnable file that arrived is named, although the forecast was clean" {
    # The softer half of the same finding: this one asks rather than refuses,
    # and the question has to be about the file that came.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    printf 'a,b\n' > "$DR_FAKE_MOUND/report.csv"
    printf 'Write-Host hi\n' > "$DR_FAKE_MOUND/payload.PS1"
    run dr-data pull -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"look RUNNABLE"* ]]
    [[ "$output" == *"payload.PS1"* ]]
    # --yes answers the question, so it is published - with the warning on the
    # record, which is the point of printing it even then.
    [ -f "$REPO/payload.PS1" ]
}

@test "dr-data pull: a non-regular file that arrived is refused by type" {
    # --no-links should mean there is never one of these to find. This test
    # asks the entry on disk instead of trusting that, and instead of reading
    # the sentence rsync prints on stdout with a zero exit status.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    printf 'a,b\n' > "$DR_FAKE_MOUND/report.csv"
    ln -s /etc/hostname "$DR_FAKE_MOUND/link.txt" || skip "no symlinks here"
    run dr-data pull -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT regular files"* ]]
    [[ "$output" == *"link.txt"* ]]
    [ ! -e "$REPO/report.csv" ]
    ! grep -q '^LOCAL' "$DR_FAKE_RSYNC_LOG" || return 1
}

@test "dr-data pull: deletions are taken from the staged tree, and only for data" {
    # --delete moved to the publication leg, where the filters come with it.
    # Without them it would mean "remove everything that is not data", and
    # everything that is not data is the source tree.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    export DRAUGR_DATA="*.csv"
    printf 'new\n' > "$DR_FAKE_MOUND/report.csv"
    printf 'old\n' > "$REPO/gone.csv"
    printf 'int main(void){return 0;}\n' > "$REPO/main.c"
    run dr-data pull -y --delete
    [ "$status" -eq 0 ]
    [ -f "$REPO/report.csv" ]
    [ ! -e "$REPO/gone.csv" ]
    [ -f "$REPO/main.c" ]
    [ -f "$REPO/README.md" ]
}

@test "dr-data pull: an empty staged tree still propagates confirmed deletions" {
    # "Nothing arrived" is not always "nothing to do". A mound that deleted
    # its data sends an empty tree, and a run that was told to propagate
    # deletions has been given an instruction by that emptiness.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    export DRAUGR_DATA="*.csv"
    printf 'old\n' > "$REPO/gone.csv"
    run dr-data pull -y --delete
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/gone.csv" ]
    [ -f "$REPO/README.md" ]
    grep -q '^LOCAL' "$DR_FAKE_RSYNC_LOG"
}

@test "dr-data pull: an empty staged tree with no --delete does nothing at all" {
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    run dr-data pull -y
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to pull"* ]]
    ! grep -q '^LOCAL' "$DR_FAKE_RSYNC_LOG" || return 1
}

@test "dr-data pull: both legs link instead of copying" {
    # What makes a staged pull cost the same as a direct one. Measured on this
    # host, ext4 sender to a /mnt/c repository: 128 MB unchanged takes 65 ms
    # with these flags and 5.9 s without them, because --link-dest links only
    # a file that matches in full, permissions included - and /mnt/c reports
    # every file as 0777 whatever --chmod asked for.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    printf 'a,b\n' > "$DR_FAKE_MOUND/report.csv"
    run dr-data pull -y
    [ "$status" -eq 0 ]
    grep -q "^REAL .*--no-perms" "$DR_FAKE_RSYNC_LOG"
    grep -q "^REAL .*--link-dest=$REPO/" "$DR_FAKE_RSYNC_LOG"
    grep -q "^LOCAL .*--no-perms" "$DR_FAKE_RSYNC_LOG"
    grep -q "^LOCAL .*--link-dest=" "$DR_FAKE_RSYNC_LOG"
    # And --chmod is NOT on either of them: it is what defeats the link, and
    # on a Windows drive it changes nothing anyway.
    ! grep -q "^REAL .*--chmod" "$DR_FAKE_RSYNC_LOG" || return 1
    ! grep -q "^LOCAL .*--chmod" "$DR_FAKE_RSYNC_LOG" || return 1
}

@test "dr-data push: --chmod still goes to the mound" {
    # The other side of the same split. The mound is ext4, where a mode is a
    # mode, and without --chmod the 0777 that all of /mnt/c reports goes in
    # with the file.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    printf 'a,b\n' > "$REPO/report.csv"
    run dr-data push -y
    [ "$status" -eq 0 ]
    grep -q "^REAL .*--chmod=" "$DR_FAKE_RSYNC_LOG"
    ! grep -q "^REAL .*--no-perms" "$DR_FAKE_RSYNC_LOG" || return 1
}

@test "dr-data status: the list it prints is labelled a forecast" {
    # It comes from a dry run, and the mound keeps working afterwards. Saying
    # so is the difference between a forecast and a promise.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    run dr-data status
    [ "$status" -eq 0 ]
    [[ "$output" == *"A forecast"* ]]
    [[ "$output" == *"dr-data pull decides on the files it"* ]]
}

@test "rsync reports a control character as an escape, and Draugr refuses that text" {
    # Why `pull` reads the staged tree and not rsync's report of it. Measured
    # with rsync 3.2.7 here, so a later rsync that changes its mind fails this
    # test instead of quietly changing what a review means.
    dr_load_common
    local d="$DR_TMP/esc" out
    mkdir -p "$d/src" "$d/dst"
    printf 'x\n' > "$d/src/$(printf 'nl\nline.txt')" || skip "no newline names here"
    printf 'y\n' > "$d/src/$(printf 'tab\tgap.txt')" || skip "no tab names here"
    printf 'z\n' > "$d/src/plain.txt"

    # The real rsync: this test never calls fake_rsync, and tests/mocks has no
    # rsync in it, because the filter tests above need the real one too.
    out=$(rsync -a --dry-run --out-format='>>%n' "$d/src/" "$d/dst/")

    # Three names, three lines - although one of the names contains the very
    # byte that separates them.
    [ "$(printf '%s\n' "$out" | grep -c '^>>')" -eq 3 ]
    # The newline became four printable characters.
    [[ "$out" == *'nl\#012line.txt'* ]]
    # The tab did NOT: it is passed through as itself.
    [[ "$out" == *"$(printf 'tab\tgap.txt')"* ]]

    # So the text that a review of that output would judge is refused - by the
    # backslash rule, because there is no control character left in it to
    # catch. Both rules are load-bearing, and for different names.
    ! dr_data_path_safe 'nl\#012line.txt' || return 1
    ! dr_data_path_safe "$(printf 'tab\tgap.txt')" || return 1
    dr_data_path_safe 'nl line.txt'
}

@test "dr-data: a symlink cannot cross in either direction" {
    # The flags, on the real transfer, in both directions. -a is -rlptgoD, so
    # without these three a symlink, a device and a socket are recreated on
    # the other side - and a symlink is a name that points anywhere.
    setup_pull || skip "no writable Windows drive path"
    fake_rsync names
    run dr-data pull -y
    [ "$status" -eq 0 ]
    grep -q '^REAL .*--no-links' "$DR_FAKE_RSYNC_LOG"
    grep -q '^REAL .*--no-devices' "$DR_FAKE_RSYNC_LOG"
    grep -q '^REAL .*--no-specials' "$DR_FAKE_RSYNC_LOG"

    : > "$DR_FAKE_RSYNC_LOG"
    run dr-data push -y
    [ "$status" -eq 0 ]
    grep -q '^REAL .*--no-links' "$DR_FAKE_RSYNC_LOG"
}

@test "dr_stage: a staging root with a space in it still works" {
    # The default root is %LOCALAPPDATA%\Draugr\stage, and a Windows account
    # folder normally has a space in it. The fixtures here do not, so this is
    # the only place that exercises the spelling that ships.
    need_win_stage
    local wintmp
    wintmp=$(dirname "$REPO")
    DRAUGR_STAGE_ROOT="$wintmp/stage root"
    dr_stage
    [ -d "$DR_STAGE" ]
    [[ "$DR_STAGE" == *"stage root/stage."* ]]
    # sbx cp gets this spelling, space and all.
    [[ "$DR_STAGE_WIN" == *'stage root\stage.'* ]]
    printf 'x\n' > "$DR_STAGE/a file.md"
    [ -f "$DR_STAGE/a file.md" ]
    rm -rf "$DR_STAGE"
}

@test "dr_stage: no host-owned root is a refusal, not a repo-local fallback" {
    need_win_stage
    # No override, no LOCALAPPDATA, and no cmd.exe to ask Windows. The answer
    # must be a refusal that names the override - never a return to
    # .draugr/tmp, which is the directory this change exists to leave.
    DRAUGR_STAGE_ROOT= LOCALAPPDATA= PATH=/usr/bin:/bin run dr_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"DRAUGR_STAGE_ROOT"* ]]
    [ ! -d "$DR_REPO/.draugr/tmp" ]
}
