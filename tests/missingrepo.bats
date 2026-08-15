#!/usr/bin/env bats
# DRAUGR_ON_MISSING_REPO: what happens when you point Draugr at a plain directory.
#
# Real git throughout - the whole question is what the resulting repository looks
# like, and only git can answer that. The two create modes are deliberately
# different shapes, so most of these tests are about telling them apart.

load helper

setup() {
    dr_test_setup
    dr_load_common
    export DRAUGR_MEM_SYNC=off      # keeps dr-up off the memory path entirely
}

teardown() { dr_test_teardown; }

# A directory on a Windows drive with files but no repository. Sets DIR.
make_plain_dir() {
    local root
    root=$(dr_win_root) || return 1
    DR_WIN_TMP=$(mktemp -d -p "$root" draugr-test.XXXXXX) || return 1
    export DR_WIN_TMP
    DIR="$DR_WIN_TMP/plain"
    mkdir -p "$DIR/notes"
    printf 'the report\n' > "$DIR/report.md"
    printf 'rows\n'       > "$DIR/notes/data.csv"
    cd "$DIR" || return 1
    return 0
}

# --- fail, the default --------------------------------------------------------

@test "on-missing-repo: refuses by default, and names the alternatives" {
    make_plain_dir || skip "no writable Windows drive path"
    run dr-init
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a git repository"* ]]
    [[ "$output" == *"create-add-all"* ]]
    [[ "$output" == *"create-data-only"* ]]
    [ ! -d "$DIR/.git" ]
}

@test "on-missing-repo: an unknown value is refused before anything is written" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-everything run dr-init
    [ "$status" -ne 0 ]
    [[ "$output" == *"Expected one of"* ]]
    # Half a repository would be worse than none.
    [ ! -d "$DIR/.git" ]
}

# --- create-data-only ---------------------------------------------------------

@test "data-only: tracks Draugr's own setup, and none of your files" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-data-only run dr-init
    [ "$status" -eq 0 ]
    [ -d "$DIR/.git" ]

    # Draugr's own files are committed so the tree comes back clean; the user's
    # are not, which is the whole point - they travel by DRAUGR_DATA instead.
    run git -C "$DIR" ls-files
    [[ "$output" == *".gitignore"* ]]
    [[ "$output" != *"report.md"* ]]
    [[ "$output" != *"notes/data.csv"* ]]
}

@test "data-only: the .gitignore is a single '*', not a list" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-data-only dr-init >/dev/null 2>&1

    # dr-init's usual three entries would be redundant under "*", and a reader
    # would reasonably wonder what they were there to do.
    grep -qx '\*' "$DIR/.gitignore"
    ! grep -q 'draugr.local.conf' "$DIR/.gitignore"
}

@test "data-only: the tree is clean, and stays clean when you edit" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-data-only dr-init >/dev/null 2>&1

    # The whole point: DRAUGR_REQUIRE_CLEAN can never fire, so there is no
    # commit-before-every-session discipline to remember.
    [ -z "$(git -C "$DIR" status --porcelain)" ]
    printf 'edited\n' > "$DIR/report.md"
    printf 'brand new\n' > "$DIR/notes/fresh.md"
    [ -z "$(git -C "$DIR" status --porcelain)" ]
}

@test "data-only: dr-scan can still see a credential" {
    make_plain_dir || skip "no writable Windows drive path"
    printf 'AWS_SECRET=hunter2\n' > "$DIR/secrets.env"
    DRAUGR_ON_MISSING_REPO=create-data-only dr-init >/dev/null 2>&1

    # Bare `git ls-files --others` lists ignored files too, which is why the
    # scan survives a .gitignore of "*". If that ever changes, this fails.
    run dr-scan
    [ "$status" -ne 0 ]
    [[ "$output" == *"secrets.env"* ]]
}

@test "data-only: seeds DRAUGR_DATA, or the mode carries nothing" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-data-only dr-init >/dev/null 2>&1

    grep -q 'DRAUGR_DATA="\*"' "$DIR/.draugr.conf"
    run dr-config
    [[ "$output" == *"DRAUGR_DATA"* ]]
}

@test "data-only: every file is carried by the data channel" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-data-only dr-init >/dev/null 2>&1

    DRAUGR_DATA="*"
    run dr_data_matches "report.md"
    [ "$status" -eq 0 ]
    run dr_data_matches "notes/data.csv"
    [ "$status" -eq 0 ]
    # But never the plumbing, however wide the pattern.
    run dr_data_matches ".git/config"
    [ "$status" -ne 0 ]
}

@test "data-only: an existing .draugr.conf is left alone" {
    make_plain_dir || skip "no writable Windows drive path"
    printf 'DRAUGR_DATA="only/this/"\n' > "$DIR/.draugr.conf"
    DRAUGR_ON_MISSING_REPO=create-data-only dr-init >/dev/null 2>&1

    grep -q 'only/this/' "$DIR/.draugr.conf"
    ! grep -q 'DRAUGR_DATA="\*"' "$DIR/.draugr.conf"
}

# --- create-add-all -----------------------------------------------------------

@test "add-all: commits what was there" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-add-all run dr-init
    [ "$status" -eq 0 ]

    run git -C "$DIR" ls-files
    [[ "$output" == *"report.md"* ]]
    [[ "$output" == *"notes/data.csv"* ]]
    [ -z "$(git -C "$DIR" status --porcelain)" ]
}

@test "add-all: a credential-shaped file is ignored, not committed" {
    make_plain_dir || skip "no writable Windows drive path"
    printf 'AWS_SECRET=hunter2\n' > "$DIR/secrets.env"
    printf 'KEY\n' > "$DIR/id_rsa"
    DRAUGR_ON_MISSING_REPO=create-add-all dr-init >/dev/null 2>&1

    # Committing these would put them in the agent's clone AND in history, and
    # silence dr-scan for good, because the scan only reports untracked files.
    run git -C "$DIR" ls-files
    [[ "$output" != *"secrets.env"* ]]
    [[ "$output" != *"id_rsa"* ]]
    [[ "$output" == *"report.md"* ]]

    # Still untracked, so still scannable.
    run dr-scan
    [ "$status" -ne 0 ]
    [[ "$output" == *"secrets.env"* ]]
}

@test "add-all: data patterns are gitignored, not committed" {
    make_plain_dir || skip "no writable Windows drive path"
    printf 'binary\n' > "$DIR/big.parquet"
    DRAUGR_DATA="*.parquet" DRAUGR_ON_MISSING_REPO=create-add-all \
        dr-init >/dev/null 2>&1

    # They travel by rsync; committing them is what DRAUGR_DATA exists to avoid.
    run git -C "$DIR" ls-files
    [[ "$output" != *"big.parquet"* ]]
    [[ "$output" == *"report.md"* ]]
}

@test "add-all: an existing .gitignore is respected" {
    make_plain_dir || skip "no writable Windows drive path"
    printf 'notes/\n' > "$DIR/.gitignore"
    DRAUGR_ON_MISSING_REPO=create-add-all dr-init >/dev/null 2>&1

    run git -C "$DIR" ls-files
    [[ "$output" != *"notes/data.csv"* ]]
    [[ "$output" == *"report.md"* ]]
}

@test "add-all: hands back an ordinary repo, dirty-tree check included" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-add-all dr-init >/dev/null 2>&1

    # The asymmetry with data-only, pinned: editing makes it dirty again, which
    # is normal git behaviour and exactly what this mode is choosing.
    printf 'edited\n' > "$DIR/report.md"
    [ -n "$(git -C "$DIR" status --porcelain)" ]
}

# --- which commands may create --------------------------------------------------

@test "only dr-init and dr-up may create; reporting commands refuse" {
    make_plain_dir || skip "no writable Windows drive path"

    # A status command must not create a repository, for the same reason it must
    # not start a stopped mound.
    DRAUGR_ON_MISSING_REPO=create-data-only run dr-status
    [ "$status" -ne 0 ]
    [ ! -d "$DIR/.git" ]

    DRAUGR_ON_MISSING_REPO=create-data-only run dr-scan
    [ "$status" -ne 0 ]
    [ ! -d "$DIR/.git" ]
}

@test "dr-up creates the repo, so dr-go works in a fresh directory" {
    make_plain_dir || skip "no writable Windows drive path"
    DR_MOCK_STATE=absent DRAUGR_ON_MISSING_REPO=create-data-only run dr-up
    [ "$status" -eq 0 ]
    [ -d "$DIR/.git" ]
    # And it went on to build the mound, rather than stopping at the repo.
    grep -q "create" "$DR_MOCK_LOG"
}

@test "the refusal from a reporting command names the setting" {
    make_plain_dir || skip "no writable Windows drive path"
    run dr-status
    [ "$status" -ne 0 ]
    [[ "$output" == *"DRAUGR_ON_MISSING_REPO"* ]]
}
