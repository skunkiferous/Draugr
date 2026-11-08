#!/usr/bin/env bats
# DRAUGR_ON_MISSING_REPO: what happens when you point Draugr at a plain
# directory.
#
# Real git in all places. The full question is the shape of the new repository,
# and only git can answer that. The two create modes have different shapes, on
# purpose. Thus most of these tests tell them apart.

load helper

setup() {
    dr_test_setup
    dr_load_common
    export DRAUGR_MEM_SYNC=off      # keeps dr-up off the memory path entirely
}

teardown() { dr_test_teardown; }

# A directory on a Windows drive, with files, but no repository. Sets DIR.
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
    # Half a repository is worse than none.
    [ ! -d "$DIR/.git" ]
}

# --- create-data-only ---------------------------------------------------------

@test "data-only: tracks Draugr's own setup, and none of your files" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-data-only run dr-init
    [ "$status" -eq 0 ]
    [ -d "$DIR/.git" ]

    # The own files of Draugr are committed, so that the tree is clean. The
    # files of the user are not. That is the full purpose. They travel by
    # DRAUGR_DATA.
    run git -C "$DIR" ls-files
    [[ "$output" == *".gitignore"* ]]
    [[ "$output" != *"report.md"* ]]
    [[ "$output" != *"notes/data.csv"* ]]
}

@test "data-only: the .gitignore is a single '*', not a list" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-data-only dr-init >/dev/null 2>&1

    # The usual three entries of dr-init are not necessary under "*", and a
    # reader then asks what they are for.
    grep -qx '\*' "$DIR/.gitignore"
    ! grep -q 'draugr.local.conf' "$DIR/.gitignore"
}

@test "data-only: the tree is clean, and stays clean when you edit" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-data-only dr-init >/dev/null 2>&1

    # The full purpose: DRAUGR_REQUIRE_CLEAN can never fire. Thus you do not
    # need to remember a commit before each session.
    [ -z "$(git -C "$DIR" status --porcelain)" ]
    printf 'edited\n' > "$DIR/report.md"
    printf 'brand new\n' > "$DIR/notes/fresh.md"
    [ -z "$(git -C "$DIR" status --porcelain)" ]
}

@test "data-only: dr-scan can still see a credential" {
    make_plain_dir || skip "no writable Windows drive path"
    printf 'AWS_SECRET=hunter2\n' > "$DIR/secrets.env"
    DRAUGR_ON_MISSING_REPO=create-data-only dr-init >/dev/null 2>&1

    # Bare `git ls-files --others` also lists ignored files. That is why the
    # scan works with a .gitignore of "*". If that changes, this fails.
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

# AND IT SETS IT ONLY IF IT WROTE THE FILE. An existing configuration that says
# nothing about data named no data, and that is a complete answer.
#
# A TEST on the first dr-up of a gateway from `dr-forge gateway` showed this.
# The default always applied. Thus dr-up held DRAUGR_DATA='*' for a
# configuration that never mentions it. It passed its own `-n "$DRAUGR_DATA"`
# guard, and called dr-data. That is a SEPARATE PROCESS. It read the file again,
# found nothing, and died. The first message of a new gateway was "auto data
# push failed", about a push that nothing needed.
#
# The rule of the fix: a default that controls a child process must be written
# where the child reads it, or not set.
#
# TESTED IN-PROCESS. That is the full purpose of its shape. The first version of
# this test called dr-init, then dr-config. It PASSED WITH THE BUG PUT BACK.
# dr-config is also a separate process that reads the file again. Thus, as
# dr-data, it cannot see the old value in memory. An assertion that cannot see
# the defect cannot fail on it. The value must be read in the SAME SHELL as
# dr_repo_create.
@test "data-only: the seeded default never outlives the file it was written to" {
    make_plain_dir || skip "no writable Windows drive path"
    dr_load_common

    # (a) No configuration: Draugr writes one, so the value in memory and the
    # file agree.
    DRAUGR_DATA=
    DRAUGR_ON_MISSING_REPO=create-data-only
    dr_repo_create "$DIR" >/dev/null 2>&1
    grep -q 'DRAUGR_DATA="\*"' "$DIR/.draugr.conf"
    [ "$DRAUGR_DATA" = '*' ]

    # (b) An existing configuration that says nothing about data: each generated
    #     gateway. Nothing can be made up here. A child that reads the file again
    #     disagrees, and a difference from your own children is the bug.
    local two="$DIR/two"
    mkdir -p "$two"
    printf '%s\n' 'DRAUGR_ON_MISSING_REPO=create-data-only' 'DRAUGR_AGENT=shell' \
        > "$two/.draugr.conf"
    DRAUGR_DATA=
    dr_repo_create "$two" >/dev/null 2>&1
    [ -z "$DRAUGR_DATA" ] || {
        printf 'dr_repo_create invented DRAUGR_DATA=%s for a config that names none\n' \
            "$DRAUGR_DATA" >&2
        return 1
    }
    # And it also did not secretly rewrite the file of the author.
    ! grep -q 'DRAUGR_DATA' "$two/.draugr.conf" || return 1
}

@test "data-only: every file is carried by the data channel" {
    make_plain_dir || skip "no writable Windows drive path"
    DRAUGR_ON_MISSING_REPO=create-data-only dr-init >/dev/null 2>&1

    DRAUGR_DATA="*"
    run dr_data_matches "report.md"
    [ "$status" -eq 0 ]
    run dr_data_matches "notes/data.csv"
    [ "$status" -eq 0 ]
    # But never the internal files, whatever the width of the pattern.
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

    # A commit of these puts them in the clone of the agent AND in history. It
    # also silences dr-scan forever, because the scan only reports untracked
    # files.
    run git -C "$DIR" ls-files
    [[ "$output" != *"secrets.env"* ]]
    [[ "$output" != *"id_rsa"* ]]
    [[ "$output" == *"report.md"* ]]

    # Still untracked, so the scan still sees them.
    run dr-scan
    [ "$status" -ne 0 ]
    [[ "$output" == *"secrets.env"* ]]
}

@test "add-all: data patterns are gitignored, not committed" {
    make_plain_dir || skip "no writable Windows drive path"
    printf 'binary\n' > "$DIR/big.parquet"
    DRAUGR_DATA="*.parquet" DRAUGR_ON_MISSING_REPO=create-add-all \
        dr-init >/dev/null 2>&1

    # They travel by rsync. DRAUGR_DATA exists to avoid a commit of them.
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

    # The difference from data-only, pinned. An edit makes it dirty again. That
    # is normal git behavior, and exactly what this mode chooses.
    printf 'edited\n' > "$DIR/report.md"
    [ -n "$(git -C "$DIR" status --porcelain)" ]
}

# --- which commands can create -----------------------------------------------

@test "only dr-init and dr-up may create; reporting commands refuse" {
    make_plain_dir || skip "no writable Windows drive path"

    # A status command must not create a repository, for the same reason that it
    # must not start a stopped mound.
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
    # And it continued, and built the mound. It did not stop at the repo.
    grep -q "create" "$DR_MOCK_LOG"
}

@test "the refusal from a reporting command names the setting" {
    make_plain_dir || skip "no writable Windows drive path"
    run dr-status
    [ "$status" -ne 0 ]
    [[ "$output" == *"DRAUGR_ON_MISSING_REPO"* ]]
}
