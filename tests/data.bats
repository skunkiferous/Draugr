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
