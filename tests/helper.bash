# shellcheck shell=bash
# Shared setup for the bats suites.

DR_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export DR_ROOT
export PATH="$DR_ROOT/tests/mocks:$DR_ROOT/bin:$PATH"

# Point sbx discovery at the mock, and keep every test out of the real
# ~/.config/draugr so a run can never trust something on the developer's machine.
dr_test_setup() {
    DR_TMP=$(mktemp -d)
    export DR_TMP
    export DRAUGR_SBX="$DR_ROOT/tests/mocks/sbx"
    export DRAUGR_CONFIG_HOME="$DR_TMP/config"
    export DR_MOCK_LOG="$DR_TMP/sbx.log"
    export HOME="$DR_TMP/home"
    mkdir -p "$HOME" "$DRAUGR_CONFIG_HOME"
    : > "$DR_MOCK_LOG"
}

dr_test_teardown() {
    [ -n "${DR_TMP:-}" ] && [ -d "$DR_TMP" ] && rm -rf "$DR_TMP"
    # DR_WIN_TMP lives on a real drive rather than in $TMPDIR, so nothing else is
    # going to clean it up. Only set by dr_make_win_repo.
    [ -n "${DR_WIN_TMP:-}" ] && [ -d "$DR_WIN_TMP" ] && rm -rf "$DR_WIN_TMP"
    return 0
}

# A throwaway git repo. Note this is NOT under a real /mnt/<drive>/ path, so it
# deliberately fails dr_require_win_path - path translation is unit-tested
# against literal strings instead, which keeps those tests runnable on any OS.
dr_make_repo() {
    local name=${1:-testrepo}
    local dir="$DR_TMP/$name"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name Test
    printf 'hello\n' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "first"
    printf '%s' "$dir"
}

# Source common.sh in the current shell, for unit-testing its functions.
dr_load_common() {
    # shellcheck source=../lib/common.sh
    . "$DR_ROOT/lib/common.sh"
}

# --- repos on a Windows drive ------------------------------------------------
#
# Every mound command calls dr_require_win_path, so testing one at all means
# having a repo whose path starts /mnt/<letter>/. The check is pure string
# matching - no hypervisor is involved - so any writable directory under such a
# path will do:
#
#   in WSL   /mnt/c is the real C: drive
#   in CI    a plain directory that the workflow creates with sudo
#   elsewhere  nothing, and the tests that need one skip rather than fail
#
# $DRAUGR_TEST_WINROOT overrides the search for anyone whose drives sit elsewhere.
dr_win_root() {
    local candidate

    # An explicit override replaces the search rather than joining it, so that
    # pointing it at nothing is a supported way to exercise the skip path.
    if [ -n "${DRAUGR_TEST_WINROOT:-}" ]; then
        [ -d "$DRAUGR_TEST_WINROOT" ] && [ -w "$DRAUGR_TEST_WINROOT" ] || return 1
        printf '%s' "$DRAUGR_TEST_WINROOT"
        return 0
    fi

    # /mnt/c/Temp first: on a real machine it is a scratch directory, whereas the
    # drive root is somebody's C:\ and does not want test litter in it.
    for candidate in /mnt/c/Temp /mnt/c; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# --- standing in for the mound's git repository ------------------------------
#
# dr-sync and friends talk to ssh://<name>.sbx/<mound path>. There is no sandbox
# in a test, so we use git's own url.<base>.insteadOf rewriting to point that URL
# at a local clone. git then does a genuine fetch over the filesystem, which
# means the code under test is unmodified - no test-only branch, no backdoor
# variable, and the fetch, the ref names and the commit counting are all real.
#
# Prints the stand-in repo's path. Commits made there appear to Draugr exactly as
# the agent's commits would.
dr_fake_mound() {
    local repo=$1 name=$2 url mound fake

    # The URL Draugr will derive. It has to match exactly, so it is built the
    # same way dr_sandbox_url builds it: /mnt is stripped to give the mound path.
    mound=${repo#/mnt}
    url="ssh://$name.sbx$mound"

    fake="$DR_TMP/mound-$name"
    git clone -q "$repo" "$fake"
    git -C "$fake" config user.email agent@example.com
    git -C "$fake" config user.name Agent

    # Rewrite that exact URL to the local path, for this repo only.
    git -C "$repo" config "url.$fake.insteadOf" "$url"
    printf '%s' "$fake"
}

# Make a commit in the stand-in, the way the agent would.
dr_mound_commit() {
    local fake=$1 msg=${2:-agent work}
    printf '%s\n' "$msg" >> "$fake/agent.txt"
    git -C "$fake" add -A
    git -C "$fake" commit -qm "$msg"
}

# Sets DR_WIN_TMP (removed by dr_test_teardown) and prints the repo path. Call it
# as:  repo=$(dr_make_win_repo) || skip "no writable Windows drive path"
dr_make_win_repo() {
    local root name=${1:-testrepo} dir
    root=$(dr_win_root) || return 1

    # mktemp -d -p puts the directory under $root rather than under $TMPDIR, which
    # is the whole point: the path has to begin /mnt/<letter>/ to be accepted.
    DR_WIN_TMP=$(mktemp -d -p "$root" draugr-test.XXXXXX) || return 1
    export DR_WIN_TMP
    dir="$DR_WIN_TMP/$name"

    # One commit, so the tree is clean and has history - dr-go's clean-tree check
    # and the clone itself both need something to have been committed at least once.
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name Test
    printf 'hello\n' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "first"
    printf '%s' "$dir"
}
