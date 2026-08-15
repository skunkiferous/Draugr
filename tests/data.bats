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
