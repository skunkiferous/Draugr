#!/usr/bin/env bats
# DRAUGR_DATA: the filter rules, the matcher, and the clean-tree exemption.
#
# The rules are checked against REAL rsync, transferring between two local
# directories. No sandbox is involved and none is needed - the filter language is
# rsync's, so the only way to be sure of it is to let rsync decide.

load helper

setup() {
    dr_test_setup
    dr_load_common
}

teardown() { dr_test_teardown; }

# A tree with one of every awkward shape: a data dir, a nested data file, a
# matching extension at the root AND deep in the source tree, and source files
# that must never be swept up.
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

# What rsync would actually transfer, given the rules DRAUGR_DATA produces.
transferred() {
    local filters
    mapfile -t filters < <(dr_data_filters)
    rsync -a -m --dry-run --out-format='%n' "${filters[@]}" \
        "$DR_TMP/src/" "$DR_TMP/dst/" | grep -v '/$' | sort
}

# --- plumbing that must never travel, whatever DRAUGR_DATA says ---------------

@test "data filters: .git never travels, even for DRAUGR_DATA=*" {
    make_tree
    # A real .git, because the bug is that rsync walks into it like any directory.
    mkdir -p "$DR_TMP/src/.git/hooks" "$DR_TMP/src/.draugr/tmp"
    touch "$DR_TMP/src/.git/config" "$DR_TMP/src/.git/hooks/pre-commit.sample" \
          "$DR_TMP/src/.draugr/tmp/leaked-memory.md"

    DRAUGR_DATA="*"
    run transferred
    # Pushing the host's .git over the mound clone's would replace the agent's
    # git metadata, remote and all.
    [[ "$output" != *".git/"* ]]
    [[ "$output" != *".draugr/"* ]]
    # The actual data still moves - the guard is narrow, not a blanket refusal.
    [[ "$output" == *"a.parquet"* ]]
    [[ "$output" == *"tmp/x.bin"* ]]
}

@test "data filters: an innocent extension pattern cannot reach into .git" {
    make_tree
    mkdir -p "$DR_TMP/src/.git/hooks"
    touch "$DR_TMP/src/.git/hooks/pre-commit.sample" "$DR_TMP/src/keep.sample"

    # Slashless entries are unanchored and match at every depth, so this used to
    # collect git's own hook templates.
    DRAUGR_DATA="*.sample"
    run transferred
    [[ "$output" != *".git"* ]]
    [[ "$output" == *"keep.sample"* ]]
}

@test "dr_data_matches: agrees with the filters about the plumbing" {
    DRAUGR_DATA="*"
    # Matching here but not transferring would exempt a path from the clean-tree
    # check and then never send it - the disagreement the two functions exist to
    # avoid. Checked for both, because "*" matches absolutely everything else.
    run dr_data_matches ".git/config"
    [ "$status" -ne 0 ]
    run dr_data_matches ".draugr/kit.applied"
    [ "$status" -ne 0 ]
    run dr_data_matches ".gitignore"
    [ "$status" -eq 0 ]
}

@test "data filters: .gitignore is not caught by the .git exclusion" {
    make_tree
    touch "$DR_TMP/src/.gitignore"

    # rsync patterns match whole names, not prefixes - worth pinning, because
    # .gitignore is a file you might legitimately want on both sides.
    DRAUGR_DATA="*"
    run transferred
    [[ "$output" == *".gitignore"* ]]
}

# --- the filter rules, against real rsync ------------------------------------

@test "data filters: a directory entry takes its contents and nothing beside it" {
    make_tree
    DRAUGR_DATA="scratch/raw/"
    run transferred
    [ "$output" = "scratch/raw/r1" ]
}

@test "data filters: a ** pattern takes the whole subtree" {
    make_tree
    DRAUGR_DATA="tmp/**"
    run transferred
    [[ "$output" == *"tmp/x.bin"* ]]
    [[ "$output" == *"tmp/deep/y.bin"* ]]
    [[ "$output" != *"README"* ]]
}

@test "data filters: a bare extension matches at every depth" {
    make_tree
    DRAUGR_DATA="*.parquet"
    run transferred
    [[ "$output" == *"a.parquet"* ]]
    [[ "$output" == *"lib/b.parquet"* ]]
    [[ "$output" != *"code.py"* ]]
}

@test "data filters: source files are never swept up" {
    make_tree
    DRAUGR_DATA="tmp/** *.parquet scratch/raw/"
    run transferred
    [[ "$output" != *"README.md"* ]]
    [[ "$output" != *"code.py"* ]]
    [[ "$output" != *"cooked"* ]]
}

@test "data filters: all three shapes together" {
    make_tree
    DRAUGR_DATA="tmp/** *.parquet scratch/raw/"
    run transferred
    [ "$output" = "a.parquet
lib/b.parquet
scratch/raw/r1
tmp/deep/y.bin
tmp/x.bin" ]
}

# --- the matcher, which must agree with the rules above ----------------------

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
    ! dr_data_matches "README.md"
    ! dr_data_matches "lib/code.py"
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

# --- naming what actually blocks ---------------------------------------------
#
# The exemption is all-or-nothing: one dirty source file stops the session even
# when everything else is data. That is deliberate, but the report used to be
# `git status --short` in full, so the one file that mattered arrived at the
# bottom of a list of exempt ones and DRAUGR_DATA looked broken.

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
    # Same rule dr_data_dirty_only uses. Renaming a source file TO a data name
    # makes it data; the reverse makes it a blocker.
    repo=$(dr_make_repo)
    printf 'a\n' > "$repo/data.tsv"
    git -C "$repo" add -A
    git -C "$repo" commit -qm data
    git -C "$repo" mv data.tsv notes.md
    DRAUGR_DATA="*.tsv" run dr_data_dirty_blockers "$repo"
    [[ "$output" == *"notes.md"* ]]
}

# --- reviewing what a pull would land ----------------------------------------
#
# dr-data pull writes agent-authored bytes onto the host with no commit to read
# first, so these three helpers are what stands between "rsync said 12 files" and
# a reviewer who has actually seen what is arriving.

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
    # The one that matters: rsync sanitises this, but Draugr is the thing doing
    # the writing and should not need to know which rsync it got.
    ! dr_data_path_safe "out/../../escape"
}

@test "dr_data_path_safe: a bare .. is refused" {
    ! dr_data_path_safe ".."
}

@test "dr_data_path_safe: an empty name is refused" {
    ! dr_data_path_safe ""
}

@test "dr_data_path_safe: a newline in a name is refused" {
    # Not only a traversal question. Every caller parses the incoming list one
    # name per line, so a newline would silently truncate the review itself.
    ! dr_data_path_safe "$(printf "bad\nname")"
}

@test "dr_data_path_safe: terminal escapes in a name are refused" {
    # A filename that repaints the screen could hide the rest of the report.
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
    # The important half. A warning that fires on every parquet file is one
    # people learn to scroll past, and then it protects nothing.
    ! dr_data_exec_shaped "model.parquet"
    ! dr_data_exec_shaped "report.csv"
    ! dr_data_exec_shaped "notes.txt"
    ! dr_data_exec_shaped "tmp/x.bin"
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
    # So that "the agent emptied this file" shows up as a diff rather than
    # being withheld as unreadable.
    : > "$DR_TMP/t.empty"
    dr_data_is_text "$DR_TMP/t.empty"
}

@test "dr_data_is_text: only the first 8 KB is judged" {
    # A huge CSV with one stray NUL at the end should still be diffable, and
    # reading all of a 4 GB file to decide would defeat the point.
    head -c 20000 /dev/zero | tr "\000" "a" > "$DR_TMP/t.big"
    printf "\000" >> "$DR_TMP/t.big"
    dr_data_is_text "$DR_TMP/t.big"
}
